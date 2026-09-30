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
    , ReplayIndex (..)
    , newReplayIndex
    , addRejection
    , purposesOf
    , recordComparison
    , capturingSubmitter

      -- * Capture
    , checkResolved

      -- * Parameters
    , DeployedApplication (..)
    , AppliedTraced (..)
    , applyDeployedParameters
    , witnessApplications

      -- * Evaluation
    , classify

      -- * Offline
    , runReplayCapsule
    ) where

import Codec.Serialise
    ( DeserialiseFailure
    , Serialise
    , deserialiseOrFail
    , serialise
    )
import Control.Exception
    ( SomeException
    , evaluate
    , try
    )
import Control.Monad (forM, guard, unless, when)
import Control.Monad.Trans.Except (runExcept)
import Data.Aeson
    ( Value (..)
    , object
    , (.=)
    )
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Lazy.Char8 qualified as BSL8
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
import Data.Maybe (fromMaybe, isNothing, mapMaybe)
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
import System.FilePath
    ( dropTrailingPathSeparator
    , takeDirectory
    , (</>)
    )
import System.Timeout (timeout)
import Text.Read (readMaybe)

import Cardano.Crypto.Hash.Class (hashFromTextAsHex, hashToBytes)
import Cardano.Ledger.Address (Addr (..))
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
import Cardano.Ledger.Api.Tx.Out (TxOut, addrTxOutL, valueTxOutL)
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL)
import Cardano.Ledger.Binary
    ( decCBOR
    , decodeFull
    , decodeFullAnnotator
    , serialize
    )
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams, eraProtVerHigh)
import Cardano.Ledger.Credential (Credential (..))
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
import Cardano.Slotting.EpochInfo (EpochInfo, hoistEpochInfo)
import Cardano.Slotting.Time (SystemStart (..))
import Cardano.Tx.Ledger (ConwayTx)
import Ouroboros.Consensus.HardFork.Combinator.Ledger.Query
    ( QueryHardFork (GetInterpreter)
    , pattern QueryHardFork
    )
import Ouroboros.Consensus.HardFork.History.EpochInfo
    ( interpreterToEpochInfo
    )
import Ouroboros.Consensus.HardFork.History.Qry (Interpreter)
import Ouroboros.Consensus.Ledger.Query
    ( Query (BlockQuery, GetSystemStart)
    )
import PlutusCore.Data qualified as PLC (Data (I))
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
import Cardano.Node.Client.Types (Block)
import Singular.Registry.Blueprint
    ( Blueprint (..)
    , Validator (..)
    , applyBytesParam
    , applyDataParam
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
    , OnChainTokenState (..)
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
    , reNodeId :: Text
    , reSetup :: Either UnobservedCause ReplaySetup
    , reIndex :: ReplayIndex
    }

{- | The replay evidence a session keeps: where it goes, the row running, one
entry per rejection in the order the run met them, and what each rejection's
failing purposes admitted, by transaction id, for the comparison that follows.
-}
data ReplayIndex = ReplayIndex
    { riDir :: FilePath
    -- ^ the run's receipts directory; evidence goes under @replay/@
    , riRow :: IORef Text
    , riEntries :: IORef [Value]
    , riPurposes :: IORef (Map Text [(Text, ReplayClass)])
    }

-- | An empty index for a receipts directory.
newReplayIndex :: FilePath -> IO ReplayIndex
newReplayIndex dir =
    ReplayIndex dir <$> newIORef "" <*> newIORef [] <*> newIORef Map.empty

{- | Add one rejection's entry, with its failing purposes by deployed hash, and
write the whole index.
-}
addRejection :: ReplayIndex -> Text -> Value -> [(Text, ReplayClass)] -> IO ()
addRejection index txid entry purposes = do
    modifyIORef' (riEntries index) (<> [entry])
    modifyIORef' (riPurposes index) (Map.insert txid purposes)
    writeIndex index

-- | What a rejection's failing purposes admitted, by deployed hash.
purposesOf :: ReplayIndex -> Text -> IO [(Text, ReplayClass)]
purposesOf index txid =
    Map.findWithDefault [] txid <$> readIORef (riPurposes index)

{- | Record a refused step's comparison on its rejection's entry — the model's
reason, the comparison, and class A, the fact of an executed model reason —
and write the index, before the runner acts on it.
-}
recordComparison :: ReplayIndex -> Text -> Text -> ReasonComparison -> IO ()
recordComparison _ _ _ _ = pure ()

writeIndex :: ReplayIndex -> IO ()
writeIndex index = do
    entries <- readIORef (riEntries index)
    createDirectoryIfMissing True (riDir index </> "replay")
    BSL.writeFile
        (riDir index </> "replay" </> "index.json")
        (Aeson.encode entries)

-- | The two builds a replay reads, checked against each other at start.
data ReplaySetup = ReplaySetup
    { rsProvenance :: TracedProvenance
    , rsCodes :: Map Text (ShortByteString, ShortByteString)
    -- ^ per validator: the deployed code, the traced code
    , rsStatePolicy :: ByteString
    -- ^ the deployed state script's hash, the request's first parameter
    , rsUnrouted :: [(Text, Text)]
    {- ^ the deployed blueprint's parameterless validators the replay does
    not trace, by title and hash: a failing hash equal to one of these is
    identified, and has no route
    -}
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
    setup <-
        loadSetup deployedPath =<< lookupEnv "REGISTRY_TRACED_BLUEPRINT"
    index <- newReplayIndex dir
    pure
        ReplayEnv
            { reNode = node
            , reLsq = lsq
            , reNodeId = nodeId
            , reSetup = setup
            , reIndex = index
            }

{- | The deployed blueprint and the traced one, with the provenance beside the
traced one; any missing, unreadable or mismatched piece is 'ToolchainMismatch'.
-}
loadSetup
    :: FilePath -> Maybe FilePath -> IO (Either UnobservedCause ReplaySetup)
loadSetup deployedPath tracedPath = do
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
                        let unrouted =
                                [ (vTitle v, vHash v)
                                | v <- validators d
                                , vParameters v == 0
                                , not (any (`T.isPrefixOf` vTitle v) replayedValidators)
                                ]
                        pure (ReplaySetup p codes policy unrouted)
    pure $ case result of
        Right (Just setup) -> Right setup
        Right Nothing -> Left ToolchainMismatch
        Left (_ :: SomeException) -> Left ToolchainMismatch

-- | The registry validators a refusal is replayed for, by blueprint title.
replayedValidators :: [Text]
replayedValidators = ["state.state", "request.request", "witness.witness"]

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
    row <- readIORef (riRow (reIndex env))
    let txid = txIdText tx
        failing = map T.pack (refusalScriptHashes (T.unpack nodeText))
    dir <- freshDirectory (riDir (reIndex env) </> "replay") (T.unpack txid)
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
    addRejection
        (reIndex env)
        txid
        entry
        [(prDeployedHash p, prClass p) | (_, p) <- purposes]
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
    (purposes, classes) <-
        replayCore
            (reSetup env)
            tx
            resolved
            pp
            (epochInfoOf interpreter)
            systemStart
            failing
    pure (Just captureId, purposes, classes)

-- | The ledger's slot arithmetic from the node's hard-fork interpreter.
epochInfoOf :: Interpreter xs -> EpochInfo (Either Text)
epochInfoOf =
    hoistEpochInfo (first (T.pack . show) . runExcept)
        . interpreterToEpochInfo

{- | Replay a captured rejection: the one core both the live capture and an
offline capsule go through. Each failing hash is first identified — a routed
family whose untraced application reproduces it, or a cause — and only a
routed one is evaluated.
-}
replayCore
    :: Either UnobservedCause ReplaySetup
    -> ConwayTx
    -> Map TxIn (TxOut ConwayEra)
    -> PParams ConwayEra
    -> EpochInfo (Either Text)
    -> SystemStart
    -> [Text]
    -> IO ([(Text, PurposeReplay)], [ReplayClass])
replayCore setupOrCause tx resolved pp epochInfo systemStart failing
    | null failing = pure ([], [Unobserved Phase1])
    | otherwise = case (checkResolved tx resolved, setupOrCause) of
        (Left cause, _) -> unreplayed cause
        (_, Left cause) -> unreplayed cause
        (Right utxo, Right setup) -> do
            let evaluated = evalTxExUnits pp tx (UTxO utxo) epochInfo systemStart
                purposes =
                    [ (hashText hash, purpose)
                    | (purpose, hash) <- neededPurposes utxo tx
                    ]
                applications = deployedApplications setup tx utxo
                roles = capturedRoles tx utxo
            replays <-
                fmap concat $
                    forM failing $ \hash -> do
                        let own = [p | (h, p) <- purposes, h == hash]
                        applied <-
                            try
                                ( evaluate
                                    ( tracedFor
                                        setup
                                        applications
                                        (Map.lookup hash roles)
                                        hash
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
            pure (replays, map (prClass . snd) replays)
  where
    unreplayed cause =
        pure
            ( [ ( hash
                , PurposeReplay "none" hash Nothing Nothing Nothing (Unobserved cause)
                )
              | hash <- failing
              ]
            , [Unobserved cause | _ <- failing]
            )
    tracedHashOf = either (const Nothing) (Just . hashText . atHash)

{- | The traced code for a failing hash, or why there is none: the hash is
identified among the replay's families first — the routed ones by their
untraced applications built from the capture, the untraced parameterless
validators by their own hash, and the role the capture records for the script
— and only then are the matching family's parameters applied.
-}
tracedFor
    :: ReplaySetup
    -> [DeployedApplication]
    -> Maybe Text
    -> Text
    -> Either UnobservedCause AppliedTraced
tracedFor setup applications role hash = do
    title <- identifyScript families role hash
    failing <-
        maybe (Left ParametersMismatch) Right (scriptHashOfText hash)
    applyDeployedParameters
        (rsCodes setup)
        [a | a <- applications, daTitle a == title]
        failing
  where
    families =
        [ ScriptFamily
            title
            True
            [ hashText (computeScriptHash (daApply a untraced))
            | a <- applications
            , daTitle a == title
            ]
        | (title, (untraced, _)) <- Map.toList (rsCodes setup)
        ]
            <> [ ScriptFamily title False [unroutedHash]
               | (title, unroutedHash) <- rsUnrouted setup
               ]

{- | What the capture records each script as, by its hash: the script an
output carrying a state or request datum sits at, and the policies the state
datum pins — the witnesses, and the application.
-}
capturedRoles
    :: ConwayTx -> Map TxIn (TxOut ConwayEra) -> Map Text Text
capturedRoles tx utxo =
    Map.fromList $
        concatMap
            roleOf
            (Map.elems utxo <> toList (tx ^. bodyTxL . outputsTxBodyL))
  where
    roleOf out = case extractCageDatum out of
        Just (StateDatum st) ->
            [(h, "state.state") | Just h <- [scriptAt out]]
                <> [ (pin (stateActivePolicy st), "witness.witness")
                   , (pin (stateAbsentPolicy st), "witness.witness")
                   , (pin (stateTerminalPolicy st), "witness.witness")
                   , (pin (stateAppPolicy st), "application")
                   ]
        Just (RequestDatum _) -> [(h, "request.request") | Just h <- [scriptAt out]]
        _ -> []
    scriptAt out = case out ^. addrTxOutL of
        Addr _ (ScriptHashObj h) _ -> Just (hashText h)
        _ -> Nothing
    pin (BuiltinByteString bytes) = hexText bytes

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

{- | The witness policies a registry can have run: @witness(kind, registry)@ at
kinds 0, 1 and 2, the registry being the state policy followed by a captured
registry token.
-}
witnessApplications
    :: ByteString -> [ByteString] -> [DeployedApplication]
witnessApplications statePolicy tokens =
    [ DeployedApplication
        "witness.witness"
        ("kind " <> T.pack (show kind) <> ", registry " <> hexText registry)
        (applyBytesParam registry . applyDataParam (PLC.I kind))
    | token <- tokens
    , let registry = statePolicy <> token
    , kind <- [0, 1, 2]
    ]

{- | The applications a rejected transaction can have run: the state script,
which takes no parameter, and, for each registry token the capture names — a
token held by an output it spends, references or creates, or named by a
request it spends — the request script under the state policy and that token,
and the three witnesses of that registry.
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
            <> witnessApplications (rsStatePolicy setup) tokens
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

-- ---------------------------------------------------------
-- Offline
-- ---------------------------------------------------------

{- | Replay a capsule a run kept, without a node: the saved transaction,
resolved outputs, protocol parameters and era data go through 'replayCore',
the same core a live capture does. The capture id is recomputed from the
saved files and must equal the one the run recorded. The outcome is written
under @replay-offline/<rejectedTxId>/@ beside the receipts, never over the
original.
-}
runReplayCapsule
    :: [String] -> FilePath -> FilePath -> FilePath -> IO ()
runReplayCapsule invocation capsuleDir deployedPath tracedPath = do
    let capsule = dropTrailingPathSeparator capsuleDir
    files <-
        forM capsuleFiles $ \name -> (,) name <$> BS.readFile (capsule </> name)
    original <-
        Aeson.eitherDecodeFileStrict (capsule </> "outcome.json")
            >>= either fail pure
    let recomputed = captureIdOf files
        recorded = textField "captureId" original
        txid = textField "rejectedTxId" original
        failing = case original of
            Object o -> case KM.lookup "failingHashes" o of
                Just (Array hashes) -> [h | String h <- toList hashes]
                _ -> []
            _ -> []
        bytesOf name = fromMaybe BS.empty (lookup name files)
    unless (Just recomputed == recorded) $
        fail
            ( "capture id "
                <> T.unpack recomputed
                <> " differs from the recorded "
                <> show recorded
            )
    tx <-
        either (fail . show) pure $
            decodeFullAnnotator
                (eraProtVerHigh @ConwayEra)
                "transaction"
                decCBOR
                (BSL.fromStrict (bytesOf "transaction.cbor"))
    UTxO resolved <-
        either (fail . show) pure $
            decodeFull
                (eraProtVerHigh @ConwayEra)
                (BSL.fromStrict (bytesOf "resolved.cbor"))
    pp <-
        either
            fail
            pure
            (Aeson.eitherDecodeStrict (bytesOf "protocol-parameters.json"))
    era <-
        either fail pure (Aeson.eitherDecodeStrict (bytesOf "era.json"))
    systemStart <-
        maybe (fail "era.json: unreadable systemStart") (pure . SystemStart) $
            textField "systemStart" era
                >>= T.stripPrefix "SystemStart "
                >>= readMaybe . T.unpack
    history <-
        either (const (fail "era.json: eraHistory is not hex")) pure $
            maybe (Left ()) (first (const ()) . Base16.decode . TE.encodeUtf8) $
                textField "eraHistory" era
    interpreter <-
        either (fail . show) pure $
            decodeAnswer
                (BlockQuery (QueryHardFork GetInterpreter))
                (BSL.fromStrict history)
    setup <- loadSetup deployedPath (Just tracedPath)
    (purposes, classes) <-
        replayCore
            setup
            tx
            resolved
            pp
            (epochInfoOf interpreter)
            systemStart
            failing
    let receipts = takeDirectory (takeDirectory capsule)
        out = receipts </> "replay-offline" </> maybe "unknown" T.unpack txid
    taken <- doesDirectoryExist out
    when taken $ fail ("an offline outcome is already written at " <> out)
    createDirectoryIfMissing True out
    BSL.writeFile
        (out </> "outcome.json")
        ( Aeson.encode
            ( object
                [ "rejectedTxId" .= txid
                , "captureId" .= recomputed
                , "recordedCaptureId" .= recorded
                , "capsule" .= capsule
                , "command" .= unwords invocation
                , "deployedBlueprint" .= deployedPath
                , "tracedBlueprint" .= tracedPath
                , "failingHashes" .= failing
                , "purposes" .= map snd purposes
                , "classes" .= classes
                ]
            )
        )
    putStrLn
        ( "replay-capsule: capture "
            <> T.unpack recomputed
            <> " matches the recorded id"
        )
    mapM_
        ( \(role, p) ->
            putStrLn
                ( "replay-capsule: "
                    <> T.unpack role
                    <> " "
                    <> T.unpack (prPurpose p)
                    <> " "
                    <> BSL8.unpack (Aeson.encode (prClass p))
                )
        )
        purposes
    putStrLn
        ("replay-capsule: outcome written to " <> out </> "outcome.json")
  where
    textField name = \case
        Object o -> case KM.lookup name o of
            Just (String t) -> Just t
            _ -> Nothing
        _ -> Nothing

-- | The capsule files a capture id is computed over.
capsuleFiles :: [FilePath]
capsuleFiles =
    [ "transaction.cbor"
    , "resolved.cbor"
    , "protocol-parameters.json"
    , "era.json"
    ]

-- | Decode a saved local-state answer as the type its query returns.
decodeAnswer
    :: (Serialise r)
    => Query Block r -> BSL.ByteString -> Either DeserialiseFailure r
decodeAnswer _ = deserialiseOrFail
