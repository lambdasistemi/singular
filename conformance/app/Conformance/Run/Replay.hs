{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PatternSynonyms #-}

{- |
Module      : Conformance.Run.Replay
Description : Capture a live refusal and replay its failing script with traces
License     : Apache-2.0

At each validator rejection, before the run's next submission, the runner
captures what the node judged — the rejected transaction, every output it
spends or references as the node resolves them, the protocol parameters,
system start and era history — and replays each failing script on the
arguments the ledger builds from that capture: the deployed bytes under the
transaction's declared units, then the traced bytes of the same source, with
the deployed parameters, under the protocol maximum. "Conformance.Replay"
decides what the two runs admit.

The evidence is written beside the run's receipts, under @replay/@: one
directory of capsule files and an @outcome.json@ per rejection, and an
@index.json@ naming every rejection in the order the run met it. Nothing here
changes a receipt or a comparison, and nothing here throws past a class: a
replay that cannot finish is recorded with its cause.
-}
module Conformance.Run.Replay
    ( -- * Session
      ReplayEnv (..)
    , newReplayEnv
    , capturingSubmitter

      -- * Capture
    , checkResolved

      -- * Parameters
    , DeployedApplication (..)
    , AppliedTraced (..)
    , applyDeployedParameters

      -- * Evaluation
    , classify
    ) where

import Codec.Serialise (serialise)
import Control.Exception
    ( SomeException
    , evaluate
    , try
    )
import Control.Monad (forM, guard)
import Control.Monad.Trans.Except (runExcept)
import Data.Aeson
    ( Value (..)
    , object
    , (.=)
    )
import Data.Aeson qualified as Aeson
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short (ShortByteString)
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.IORef
    ( IORef
    , modifyIORef'
    , newIORef
    , readIORef
    )
import Data.List (nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing, mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((^.))
import System.Directory
    ( createDirectoryIfMissing
    , doesDirectoryExist
    , doesFileExist
    )
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory, (</>))
import System.Timeout (timeout)

import Cardano.Crypto.Hash.Class (hashFromTextAsHex, hashToBytes)
import Cardano.Ledger.Alonzo.Plutus.Evaluate
    ( TransactionScriptFailure (..)
    , evalTxExUnits
    )
import Cardano.Ledger.Alonzo.Scripts
    ( AlonzoEraScript (..)
    , AsIx
    , toAsIx
    )
import Cardano.Ledger.Alonzo.UTxO (AlonzoScriptsNeeded (..))
import Cardano.Ledger.Api.Tx (bodyTxL, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , inputsTxBodyL
    , outputsTxBodyL
    , referenceInputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (TxOut, valueTxOutL)
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL)
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams, eraProtVerHigh)
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Plutus
    ( ExUnits (..)
    , Plutus (..)
    , PlutusBinary (..)
    , PlutusWithContext (..)
    , evaluatePlutusWithContext
    , exBudgetToExUnits
    )
import Cardano.Ledger.State (EraUTxO (..), UTxO (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.EpochInfo (hoistEpochInfo)
import Cardano.Tx.Ledger (ConwayTx)
import Ouroboros.Consensus.HardFork.Combinator.Ledger.Query
    ( QueryHardFork (GetInterpreter)
    , pattern QueryHardFork
    )
import Ouroboros.Consensus.HardFork.History.EpochInfo
    ( interpreterToEpochInfo
    )
import Ouroboros.Consensus.Ledger.Query
    ( Query (BlockQuery, GetSystemStart)
    )
import PlutusCore.Evaluation.Error qualified as PLC
import PlutusCore.Evaluation.ErrorWithCause (ErrorWithCause (..))
import PlutusLedgerApi.Common qualified as P
import PlutusTx.Builtins.Internal (BuiltinByteString (..))
import UntypedPlutusCore.Evaluation.Machine.Cek (CekUserError (..))

import Cardano.Node.Client.N2C.LocalStateQuery (queryLSQ)
import Cardano.Node.Client.N2C.Types (LSQChannel)
import Cardano.Node.Client.Provider qualified as N2C
import Cardano.Node.Client.Submitter
    ( SubmitResult (..)
    , Submitter (..)
    )
import Singular.Registry.Blueprint
    ( Blueprint (..)
    , Validator (..)
    , applyRequestParams
    , extractCompiledCode
    , loadBlueprint
    )
import Singular.Registry.TxBuilder.Internal
    ( computeScriptHash
    , extractCageDatum
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRequest (..)
    , OnChainTokenId (..)
    )

import Conformance.Mirror (txIdHex)
import Conformance.NodeRejection (boundedNodeReason)
import Conformance.Refusal (refusalScriptHashes)
import Conformance.Replay

-- ---------------------------------------------------------
-- Session
-- ---------------------------------------------------------

{- | What a session needs to capture and replay: the node it submits to, where
its receipts go, the row it is running, and what it loaded of the traced
build at start — or the cause it could not.
-}
data ReplayEnv = ReplayEnv
    { reNode :: N2C.Provider IO
    , reLsq :: LSQChannel
    , reDir :: FilePath
    -- ^ the run's receipts directory; evidence goes under @replay/@
    , reNodeId :: Text
    , reRow :: IORef Text
    , reSetup :: Either UnobservedCause ReplaySetup
    , reIndex :: IORef [Value]
    }

-- | The two builds a replay reads, checked against each other at start.
data ReplaySetup = ReplaySetup
    { rsProvenance :: TracedProvenance
    , rsCodes :: Map Text (ShortByteString, ShortByteString)
    -- ^ per validator: the deployed code, the traced code
    , rsStatePolicy :: ByteString
    -- ^ the deployed state script's hash, the request's first parameter
    }

{- | Load the traced blueprint from @REGISTRY_TRACED_BLUEPRINT@ and its
provenance beside it, and hold them to the session's deployed blueprint: any
missing, unreadable or mismatched piece is 'ToolchainMismatch' for every
replay of the session, never a crash.
-}
newReplayEnv
    :: N2C.Provider IO
    -> LSQChannel
    -> FilePath
    -- ^ the deployed blueprint the session runs
    -> FilePath
    -- ^ receipts directory
    -> Text
    -- ^ node identity
    -> IO ReplayEnv
newReplayEnv node lsq deployedPath dir nodeId = do
    setup <- loadSetup deployedPath
    row <- newIORef ""
    index <- newIORef []
    pure
        ReplayEnv
            { reNode = node
            , reLsq = lsq
            , reDir = dir
            , reNodeId = nodeId
            , reRow = row
            , reSetup = setup
            , reIndex = index
            }

loadSetup :: FilePath -> IO (Either UnobservedCause ReplaySetup)
loadSetup deployedPath = do
    tracedPath <- lookupEnv "REGISTRY_TRACED_BLUEPRINT"
    result <- try $ case tracedPath of
        Nothing -> pure Nothing
        Just path -> do
            let provenancePath = takeDirectory path </> "provenance.json"
            present <-
                (&&) <$> doesFileExist path <*> doesFileExist provenancePath
            if not present
                then pure Nothing
                else do
                    provenance <- Aeson.eitherDecodeFileStrict provenancePath
                    deployed <- loadBlueprint deployedPath
                    traced <- loadBlueprint path
                    pure $ do
                        p <- either (const Nothing) Just provenance
                        d <- either (const Nothing) Just deployed
                        t <- either (const Nothing) Just traced
                        let hashes = Map.fromList [(vTitle v, vHash v) | v <- validators d]
                        guard (isNothing (toolchainCause p hashes))
                        codes <-
                            Map.fromList
                                <$> traverse
                                    ( \title ->
                                        (,) title
                                            <$> ( (,)
                                                    <$> extractCompiledCode title d
                                                    <*> extractCompiledCode title t
                                                )
                                    )
                                    replayedValidators
                        state <- Map.lookup "state.state.spend" hashes
                        Right policy <- Just (Base16.decode (TE.encodeUtf8 state))
                        pure (ReplaySetup p codes policy)
    pure $ case result of
        Right (Just setup) -> Right setup
        Right Nothing -> Left ToolchainMismatch
        Left (_ :: SomeException) -> Left ToolchainMismatch

-- | The registry validators a refusal is replayed for, by blueprint title.
replayedValidators :: [Text]
replayedValidators = ["state.state", "request.request"]

{- | The session's submitter, capturing and replaying every rejection before
it returns — so before the run can submit again.
-}
capturingSubmitter :: ReplayEnv -> Submitter IO -> Submitter IO
capturingSubmitter env inner =
    Submitter
        { submitTx = \tx -> do
            result <- submitTx inner tx
            case result of
                Rejected reason ->
                    recordRejection env tx (TE.decodeUtf8Lenient reason)
                Submitted _ -> pure ()
            pure result
        }

-- ---------------------------------------------------------
-- One rejection
-- ---------------------------------------------------------

{- | Capture, replay and record one rejection. Whatever happens is recorded:
a replay past its time is 'Timeout', an exception 'ClientException'.
-}
recordRejection :: ReplayEnv -> ConwayTx -> Text -> IO ()
recordRejection env tx nodeText = do
    row <- readIORef (reRow env)
    let txid = txIdText tx
        failing = map T.pack (refusalScriptHashes (T.unpack nodeText))
    dir <- freshDirectory (reDir env </> "replay") (T.unpack txid)
    attempt <-
        try (timeout replayMicros (replayRefusal env tx failing dir))
    (captureId, purposes, classes) <- case attempt of
        Right (Just done) -> pure done
        Right Nothing -> pure (Nothing, [], [Unobserved Timeout])
        Left (_ :: SomeException) -> pure (Nothing, [], [Unobserved ClientException])
    let roles = nub [role | (role, _) <- purposes]
        outcome =
            object
                [ "rejectedTxId" .= txid
                , "captureId" .= captureId
                , "node" .= reNodeId env
                , "row" .= row
                , "failingHashes" .= failing
                , "nodeRejection" .= boundedNodeReason 600 nodeText
                , "provenance" .= case reSetup env of
                    Right setup ->
                        let p = rsProvenance setup
                        in  object
                                [ "source" .= tpSource p
                                , "compiler" .= tpCompiler p
                                , "flags" .= tpFlags p
                                ]
                    Left cause -> object ["unobserved" .= causeName cause]
                , "purposes" .= map snd purposes
                , "classes" .= classes
                ]
        entry =
            object
                [ "kind" .= ("refusal" :: Text)
                , "rejectedTxId" .= txid
                , "evidence" .= dirName dir
                , "captureId" .= captureId
                , "row" .= row
                , "step" .= Null
                , "role"
                    .= T.intercalate "+" (if null roles then ["unattributed"] else roles)
                , "failingHashes" .= failing
                , "classes" .= classes
                , "extentClass" .= ("unclassified" :: Text)
                , "modelReason" .= Null
                , "comparison" .= Null
                ]
    BSL.writeFile (dir </> "outcome.json") (Aeson.encode outcome)
    modifyIORef' (reIndex env) (<> [entry])
    index <- readIORef (reIndex env)
    BSL.writeFile
        (reDir env </> "replay" </> "index.json")
        (Aeson.encode index)
  where
    dirName = T.pack . reverse . takeWhile (/= '/') . reverse

-- | A replay must not hold the run: two minutes, then 'Timeout'.
replayMicros :: Int
replayMicros = 120_000_000

-- | A directory no earlier rejection wrote: a resubmitted id gets a suffix.
freshDirectory :: FilePath -> String -> IO FilePath
freshDirectory parent name = go (0 :: Int)
  where
    go n = do
        let dir = parent </> (if n == 0 then name else name <> "-" <> show n)
        taken <- doesDirectoryExist dir
        if taken
            then go (n + 1)
            else createDirectoryIfMissing True dir >> pure dir

{- | Capture the rejection and replay each failing purpose. A rejection with no
failing script was refused before any script ran: its capsule is kept, and
its class is 'Phase1'.
-}
replayRefusal
    :: ReplayEnv
    -> ConwayTx
    -> [Text]
    -> FilePath
    -> IO (Maybe Text, [(Text, PurposeReplay)], [ReplayClass])
replayRefusal env tx failing dir = do
    let named = namedInputs tx
    resolved <- N2C.queryUTxOByTxIn (reNode env) named
    pp <- N2C.queryProtocolParams (reNode env)
    systemStart <- queryLSQ (reLsq env) GetSystemStart
    interpreter <-
        queryLSQ (reLsq env) (BlockQuery (QueryHardFork GetInterpreter))
    let files =
            [
                ( "transaction.cbor"
                , BSL.toStrict (serialize (eraProtVerHigh @ConwayEra) tx)
                )
            ,
                ( "resolved.cbor"
                , BSL.toStrict (serialize (eraProtVerHigh @ConwayEra) (UTxO resolved))
                )
            , ("protocol-parameters.json", BSL.toStrict (Aeson.encode pp))
            ,
                ( "era.json"
                , BSL.toStrict
                    ( Aeson.encode
                        ( object
                            [ "systemStart" .= show systemStart
                            , "eraHistory" .= hexText (BSL.toStrict (serialise interpreter))
                            ]
                        )
                    )
                )
            ]
        captureId = captureIdOf files
    mapM_ (\(name, content) -> BS.writeFile (dir </> name) content) files
    if null failing
        then pure (Just captureId, [], [Unobserved Phase1])
        else case (checkResolved tx resolved, reSetup env) of
            (Left cause, _) -> unreplayed captureId cause
            (_, Left cause) -> unreplayed captureId cause
            (Right utxo, Right setup) -> do
                let epochInfo =
                        hoistEpochInfo (first (T.pack . show) . runExcept) $
                            interpreterToEpochInfo interpreter
                    evaluated = evalTxExUnits pp tx (UTxO utxo) epochInfo systemStart
                    purposes =
                        [ (hashText hash, purpose)
                        | (purpose, hash) <- neededPurposes utxo tx
                        ]
                    applications = deployedApplications setup tx utxo
                replays <-
                    fmap concat $
                        forM failing $ \hash -> do
                            let own = [p | (h, p) <- purposes, h == hash]
                            applied <-
                                try
                                    ( evaluate
                                        ( maybe
                                            (Left ParametersMismatch)
                                            (applyDeployedParameters (rsCodes setup) applications)
                                            (scriptHashOfText hash)
                                        )
                                    )
                            let traced = case applied of
                                    Right r -> r
                                    Left (_ :: SomeException) -> Left ParametersMismatch
                                role = either (const hash) atTitle traced
                            if null own
                                then
                                    pure
                                        [
                                            ( role
                                            , PurposeReplay
                                                "none"
                                                hash
                                                (tracedHashOf traced)
                                                Nothing
                                                Nothing
                                                (Unobserved ContextUnavailable)
                                            )
                                        ]
                                else forM own $ \purpose ->
                                    (,) role
                                        <$> replayPurpose pp tx hash traced purpose (Map.lookup purpose evaluated)
                pure (Just captureId, replays, map (prClass . snd) replays)
  where
    unreplayed captureId cause =
        pure
            ( Just captureId
            , [ ( hash
                , PurposeReplay "none" hash Nothing Nothing Nothing (Unobserved cause)
                )
              | hash <- failing
              ]
            , [Unobserved cause | _ <- failing]
            )
    tracedHashOf = either (const Nothing) (Just . hashText . atHash)

-- | Every input, reference input and collateral input the transaction names.
namedInputs :: ConwayTx -> Set.Set TxIn
namedInputs tx =
    Set.unions
        [ tx ^. bodyTxL . inputsTxBodyL
        , tx ^. bodyTxL . referenceInputsTxBodyL
        , tx ^. bodyTxL . collateralInputsTxBodyL
        ]

{- | The outputs the node resolved, when they cover every input, reference
input and collateral input the transaction names; 'CaptureIncomplete'
otherwise.
-}
checkResolved
    :: ConwayTx
    -> Map TxIn (TxOut ConwayEra)
    -> Either UnobservedCause (Map TxIn (TxOut ConwayEra))
checkResolved tx resolved
    | named `Set.isSubsetOf` Map.keysSet resolved =
        Right (Map.restrictKeys resolved named)
    | otherwise = Left CaptureIncomplete
  where
    named = namedInputs tx

-- | The Plutus purposes the ledger will run, each with its script's hash.
neededPurposes
    :: Map TxIn (TxOut ConwayEra)
    -> ConwayTx
    -> [(PlutusPurpose AsIx ConwayEra, ScriptHash)]
neededPurposes utxo tx =
    [ (hoistPlutusPurpose toAsIx purpose, hash)
    | (purpose, hash) <- needed
    ]
  where
    AlonzoScriptsNeeded needed = getScriptsNeeded (UTxO utxo) (tx ^. bodyTxL)

{- | One failing purpose: the deployed run under the declared units, then the
traced run under the protocol maximum, and what they admit.
-}
replayPurpose
    :: PParams ConwayEra
    -> ConwayTx
    -> Text
    -> Either UnobservedCause AppliedTraced
    -> PlutusPurpose AsIx ConwayEra
    -> Maybe (Either (TransactionScriptFailure ConwayEra) ExUnits)
    -> IO PurposeReplay
replayPurpose _ tx hash traced purpose evaluated = do
    let label = T.pack (show purpose)
        precondition = either Just (const Nothing) traced
        declared = declaredUnits tx purpose
        result deployedRun tracedRun cls =
            pure
                PurposeReplay
                    { prPurpose = label
                    , prDeployedHash = hash
                    , prTracedHash =
                        either (const Nothing) (Just . hashText . atHash) traced
                    , prDeployed = deployedRun
                    , prTraced = tracedRun
                    , prClass = cls
                    }
    case evaluated of
        Just (Left (ValidationFailure supplied _ _ pwc)) -> do
            let deployed = runWith hash (withUnits supplied pwc)
            case traced of
                Left cause ->
                    result
                        (Just deployed)
                        Nothing
                        (admitReason deployed deployed (Just cause))
                Right applied -> do
                    let tracedRun =
                            runWith (hashText (atHash applied)) (withScript (atBytes applied) pwc)
                    result
                        (Just deployed)
                        (Just tracedRun)
                        (admitReason deployed tracedRun precondition)
        -- The whole script ran under the protocol maximum: the deployed bytes
        -- at the declared units succeed or run out, as its spend says.
        Just (Right used) ->
            let deployed =
                    ReplayRun
                        { runBytesHash = hash
                        , runBudgetLimit = maybe (0, 0) unitsPair declared
                        , runBudgetUsed = Just (unitsPair used)
                        , runOutcome =
                            if maybe False (exceeds used) declared
                                then BudgetExhausted
                                else Succeeded
                        , runLogs = []
                        }
            in  result
                    (Just deployed)
                    Nothing
                    (admitReason deployed deployed precondition)
        _ -> result Nothing Nothing (Unobserved ContextUnavailable)

-- | The units the transaction declared for a purpose.
declaredUnits
    :: ConwayTx -> PlutusPurpose AsIx ConwayEra -> Maybe ExUnits
declaredUnits tx purpose = case tx ^. witsTxL . rdmrsTxWitsL of
    Redeemers declared -> snd <$> Map.lookup purpose declared

exceeds :: ExUnits -> ExUnits -> Bool
exceeds (ExUnits mem steps) (ExUnits mem' steps') = mem > mem' || steps > steps'

unitsPair :: ExUnits -> (Integer, Integer)
unitsPair (ExUnits mem steps) = (toInteger mem, toInteger steps)

-- | Evaluate the ledger's script-with-arguments, with logs.
runWith :: Text -> PlutusWithContext -> ReplayRun
runWith bytesHash pwc =
    ReplayRun
        { runBytesHash = bytesHash
        , runBudgetLimit = unitsPair (pwcExUnits pwc)
        , runBudgetUsed = case outcome of
            Right budget -> unitsPair <$> exBudgetToExUnits budget
            Left _ -> Nothing
        , runOutcome = either classify (const Succeeded) outcome
        , runLogs = logs
        }
  where
    (logs, outcome) = evaluatePlutusWithContext P.Verbose pwc

{- | How an evaluation that did not finish ended: out of budget, the script
failing, or the evaluator unable to run it.
-}
classify :: P.EvaluationError -> RunOutcome
classify = \case
    P.CekError
        (ErrorWithCause (PLC.OperationalError (CekOutOfExError _)) _) ->
        BudgetExhausted
    P.CekError (ErrorWithCause (PLC.OperationalError _) _) -> ValidatorFailure
    P.InvalidReturnValue -> ValidatorFailure
    other -> EvaluationError (T.pack (show other))

-- | The same arguments, other bytes; the purpose keeps its deployed identity.
withScript
    :: ShortByteString -> PlutusWithContext -> PlutusWithContext
withScript bytes PlutusWithContext{..} =
    PlutusWithContext{pwcScript = Left (Plutus (PlutusBinary bytes)), ..}

withUnits :: ExUnits -> PlutusWithContext -> PlutusWithContext
withUnits units PlutusWithContext{..} = PlutusWithContext{pwcExUnits = units, ..}

-- ---------------------------------------------------------
-- Parameters
-- ---------------------------------------------------------

{- | One application of a validator the run deployed: its blueprint title,
the parameter values as the run applied them, and that application.
-}
data DeployedApplication = DeployedApplication
    { daTitle :: Text
    , daParameters :: Text
    , daApply :: ShortByteString -> ShortByteString
    }

-- | The traced code under a deployed application's parameters.
data AppliedTraced = AppliedTraced
    { atTitle :: Text
    , atParameters :: Text
    , atBytes :: ShortByteString
    , atHash :: ScriptHash
    }
    deriving stock (Show, Eq)

{- | The traced code with the parameters of the deployed application whose
untraced code hashes to the failing hash; 'ParametersMismatch' when no
application does.
-}
applyDeployedParameters
    :: Map Text (ShortByteString, ShortByteString)
    -- ^ per validator title: the deployed (untraced) code, the traced code
    -> [DeployedApplication]
    -> ScriptHash
    -> Either UnobservedCause AppliedTraced
applyDeployedParameters codes applications failing =
    case matching of
        applied : _ -> Right applied
        [] -> Left ParametersMismatch
  where
    matching =
        [ AppliedTraced
            { atTitle = daTitle application
            , atParameters = daParameters application
            , atBytes = tracedApplied
            , atHash = computeScriptHash tracedApplied
            }
        | application <- applications
        , Just (untraced, traced) <- [Map.lookup (daTitle application) codes]
        , computeScriptHash (daApply application untraced) == failing
        , let tracedApplied = daApply application traced
        ]

{- | The applications a rejected transaction can have run: the state script,
which takes no parameter, and the request script under the state policy and
each registry token the capture names — a token held by an output it spends,
references or creates, or named by a request it spends.
-}
deployedApplications
    :: ReplaySetup
    -> ConwayTx
    -> Map TxIn (TxOut ConwayEra)
    -> [DeployedApplication]
deployedApplications setup tx utxo =
    DeployedApplication "state.state" "" id
        : [ DeployedApplication
                "request.request"
                (hexText token)
                ( applyRequestParams
                    (rsStatePolicy setup)
                    (OnChainTokenId (BuiltinByteString token))
                )
          | token <- tokens
          ]
  where
    outputs = Map.elems utxo <> toList (tx ^. bodyTxL . outputsTxBodyL)
    tokens =
        nub $
            concatMap heldTokens outputs
                <> mapMaybe requestedToken outputs
    heldTokens out = case out ^. valueTxOutL of
        MaryValue _ (MultiAsset assets) ->
            [ SBS.fromShort name
            | (PolicyID policy, names) <- Map.toList assets
            , hashBytes policy == rsStatePolicy setup
            , AssetName name <- Map.keys names
            ]
    requestedToken out = case extractCageDatum out of
        Just (RequestDatum request) ->
            let OnChainTokenId (BuiltinByteString token) = requestToken request
            in  Just token
        _ -> Nothing

-- ---------------------------------------------------------
-- Spelling
-- ---------------------------------------------------------

txIdText :: ConwayTx -> Text
txIdText = T.pack . txIdHex

hashBytes :: ScriptHash -> ByteString
hashBytes (ScriptHash h) = hashToBytes h

hashText :: ScriptHash -> Text
hashText = hexText . hashBytes

scriptHashOfText :: Text -> Maybe ScriptHash
scriptHashOfText = fmap ScriptHash . hashFromTextAsHex

hexText :: ByteString -> Text
hexText = TE.decodeUtf8 . Base16.encode
