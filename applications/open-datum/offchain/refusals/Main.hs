{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Main
Description : A test harness: a fold with one fact made wrong, submitted for the node to judge
License     : Apache-2.0

A tool for the refusals journey, never a product command: the packaged commands
decline, before anything is sent, every fold the validators would refuse, so
that the node never gets to judge one. This harness builds the fold of a pending
registration the way the library's fold builder does, with one fact made wrong,
and submits it, so that the answer printed is the node's. Every subcommand reads
its provider, its wallet and its release from flags, runs against a running
development network, and prints one JSON object on standard output.

> no-pin-refusals spares
> no-pin-refusals plain-copy --pending TXID#IX
> no-pin-refusals fold --case CASE --pending TXID#IX [--pending TXID#IX ...] [--parked TXID#IX] [--spare TXID#IX]
> no-pin-refusals update --case CASE --holding TXID#IX --payload FILE
> no-pin-refusals leave --case CASE --holding TXID#IX

The shared flags are @--koios-url@, @--network-time@, @--network-magic@,
@--wallet-skey@, @--blueprint@ (the release's validators) and @--state-token@
(the registry).

@spares@ mints two tokens under a script that accepts any use: one parked at the
state address with a root datum, the way anyone may park a token there, and one
paid to the wallet.

@plain-copy@ pays the value of a pending registration, without its approval, to
the request address with the same datum: a registration that nothing approved.

@fold@ folds the pending registrations it is given as the wallet, from the chain
alone, and submits one batch. The cases are the honest fold and the facts that make
it wrong: @no-approval@ (the registration carries no approval), @other-address@
(the key's token is delivered to the folder's address), @less-than-deposit@ (the
holding keeps less than the deposit), @second-registration@ (the key is already
in the registry, shown by the proof the registry itself gives for it),
@extra-token@ (the continuing state output also holds a token the folder took
from another output) and @parked-state@ (a token parked at the state address is
spent as a state beside the registry's own), and @state-policy-movement@ (the
batch also mints and moves another token under the state policy). Each alteration changes exactly one
fact of the honest fold; the output names it.

@update@ and @leave@ spend a live holding with the update redeemer, as the
wallet, and submit one transaction. The successor output is at the holding's
address with the holding's control. @update --case honest@ replaces the payload
with the file's, signed by the holding's controller; @update --case
no-controller-signature@ is the same update signed by a wallet that is not the
controller. @leave --case honest@ recreates the holding with its token and its
payload; @leave --case token-out@ is the same spend by the controller with the
key's token not returned to the holding. A case whose wallet is not the one the
case names is not built.
-}
module Main (main) where

import BatchMeasurement qualified
import Codec.Serialise (deserialiseOrFail)
import Control.Monad (forM, forM_, unless, void, when)
import CreationCarrying qualified
import Data.Aeson (Value, encode, object, (.=))
import Data.Aeson.Types (Pair)
import Data.Bifunctor (second)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as LBS
import Data.ByteString.Short qualified as SBS
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins.Internal (BuiltinData (..))
import PlutusTx.IsData.Class (fromBuiltinData)
import System.Environment (getArgs)
import System.Exit (die)
import System.IO (Handle, hFlush, stderr, stdout)
import Text.Read (readMaybe)

import Cardano.Crypto.Hash (hashToBytes)
import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.PParams (ppMaxTxExUnitsL, ppMaxTxSizeL)
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body (mintTxBodyL)
import Cardano.Ledger.Api.Tx.Out
    ( addrTxOutL
    , coinTxOutL
    , datumTxOutL
    , mkBasicTxOut
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes qualified as Ledger
    ( Network (Testnet)
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (Script, hashScript)
import Cardano.Ledger.Keys (KeyHash (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.TxIn (TxId, TxIn (..))
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)
import Control.Tracer (nullTracer)

import Singular.Application.OpenDatum.Requests.Fold
    ( openDatumApplication
    )
import Singular.Application.OpenDatum.Requests.Records
    ( AsData (..)
    , MintAction (..)
    , ProtectedControl (..)
    , SpendAction (..)
    , decodeLiveDatum
    , mintRedeemer
    , spendRedeemer
    )
import Singular.Application.OpenDatum.Requests.Script
    ( RequestScript (..)
    , requestPolicy
    , requestScriptFromBlueprint
    )
import Singular.Application.OpenDatum.Requests.Script qualified as Request
import Singular.CLI.Payload (readPayloadFile)
import Singular.CLI.Steps (renderRefusal, scriptSource)
import Singular.Registry.Blueprint (loadBlueprint)
import Singular.Registry.Bundle
    ( Bundle (..)
    , BundleTransaction (..)
    , checkBundle
    , decodeBundle
    , decodeTransactionEnvelope
    )
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Deployment (parseOutRef, renderOutRef)
import Singular.Registry.Evidence (Evidenced (..), NoWitness)
import Singular.Registry.Ledger (ConwayEra, Root (..), TxOut)
import Singular.Registry.LedgerProvider
    ( Asset
    , LedgerProvider
    , Network
    , OutputQuery (..)
    , Session (..)
    , SubmitResult (..)
    )
import Singular.Registry.LocalEvaluation (evaluationInputs)
import Singular.Registry.PlainJson (PayloadSchema (PlainSchema))
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.SessionIO qualified as Services
import Singular.Registry.Signing (signTx, signedTx)
import Singular.Registry.StateToken (parseStateToken)
import Singular.Registry.Terminal (withReads)
import Singular.Registry.TrieState
    ( Leaf (..)
    , RegistryIdentity (..)
    , StatePoint (..)
    , StatePolicyId (..)
    , TrieFailure
    , TrieSelection (..)
    , TrieSnapshot
    , TrieState (..)
    , leafAt
    , membership
    , membershipBytes
    , speculateEdges
    , trieFailureName
    , walkProofs
    , walkRoot
    )
import Singular.Registry.TxBuilder.Internal
    ( mkInlineDatum
    , scriptFromBytes
    , scriptHashBytes
    )
import Singular.Registry.Types
    ( ProofStep
    , edgeInsertActive
    , edgeUpdateTerminal
    )
import Singular.Registry.Wallet
    ( Wallet (..)
    , bech32Address
    , loadWallet
    )
import Singular.State.Assemble
    ( NoQuery
    , Payer (..)
    , Program
    , assemble
    , inlineDatumOf
    , readOutputs
    , resolvePayer
    , tipSlot
    , validityFromTip
    )
import Singular.State.Fold
    ( Application (..)
    , Registration (..)
    , Request (..)
    )
import Singular.State.Fold qualified as Fold
import Singular.State.Lineage
    ( Replayed (..)
    , registryTrieState
    , replayRegistry
    )
import Singular.State.Preimage
    ( activeTokenName
    , approvalName
    , terminationPreimage
    )
import Singular.State.Publication (References (..), planReferences)
import Singular.State.Records
    ( Change (..)
    , decodeStateDatum
    , foldRedeemer
    , foldedRedeemer
    , stateDatum
    )
import Singular.State.Script
    ( ScriptSource
    , StateScript (..)
    , referenceOutputs
    , stateAddress
    , statePolicy
    , stateScriptFromBlueprint
    , useScript
    )

-- ---------------------------------------------------------
-- Setting up
-- ---------------------------------------------------------

-- | The provider, wallet, release and registry every subcommand needs.
data Env = Env
    { envCaps :: Capabilities NoWitness IO
    , envWallet :: Wallet
    , envState :: Script ConwayEra
    , envRequest :: Script ConwayEra
    , envToken :: Asset
    , envFlags :: [String]
    }

main :: IO ()
main = do
    args <- getArgs
    -- The library narrates on standard output; the one JSON object this tool
    -- prints must be alone on it.
    out <- hDuplicate stdout
    hDuplicateTo stderr stdout
    case args of
        ("evaluate-batch" : flags) -> BatchMeasurement.run out flags
        ["batch-release", path] -> do
            blueprint <- loadBlueprint path >>= either die pure
            request <- either die pure (requestScriptFromBlueprint blueprint)
            state <-
                either
                    die
                    pure
                    (stateScriptFromBlueprint blueprint (PolicyID (hashScript request)))
            emit out $
                object
                    [ "state" .= show (hashScript state)
                    , "request" .= show (hashScript request)
                    ]
        ["wallet-address", magicText, key] -> do
            magic <-
                maybe (die "invalid network magic") pure (readMaybe magicText)
            wallet <- loadWallet magic key
            emit out (object ["address" .= bech32Address (walletAddr wallet)])
        ("keep-batch" : flags) -> withEnv flags (keepBatchCommand out)
        ("build-beyond-capacity" : flags) -> withEnv flags (beyondCommand out)
        ("send-batch" : flags) -> withEnv flags (sendBatchCommand out)
        ("creation" : flags) -> CreationCarrying.run out flags
        ("spares" : flags) -> withEnv flags (sparesCommand out)
        ("plain-copy" : flags) -> withEnv flags (plainCopyCommand out)
        ("fold" : flags) -> withEnv flags (foldCommand out)
        ("terminate" : flags) -> withEnv flags (terminationCommand out)
        ("update" : flags) -> withEnv flags (updateCommand out)
        ("leave" : flags) -> withEnv flags (leaveCommand out)
        _ ->
            die
                "usage: no-pin-refusals (spares|plain-copy|fold|terminate|update|leave) \
                \--koios-url URL --network-time DIR --network-magic N \
                \--wallet-skey FILE --blueprint FILE --state-token POLICY.NAME \
                \[--case CASE] [--pending TXID#IX] [--parked TXID#IX] [--spare TXID#IX] \
                \[--holding TXID#IX] [--payload FILE]"

withEnv :: [String] -> (Env -> IO a) -> IO a
withEnv flags action = do
    url <- need "--koios-url"
    timeDir <- need "--network-time"
    magicText <- need "--network-magic"
    keyPath <- need "--wallet-skey"
    blueprintPath <- need "--blueprint"
    tokenText <- need "--state-token"
    magic <-
        maybe
            (die ("--network-magic is not a number: " <> magicText))
            pure
            (readMaybe magicText)
    wallet <- loadWallet magic keyPath
    blueprint <- loadBlueprint blueprintPath >>= either die pure
    requestScript <-
        either die pure (requestScriptFromBlueprint blueprint)
    stateScript <-
        either
            die
            pure
            ( stateScriptFromBlueprint
                blueprint
                (PolicyID (hashScript requestScript))
            )
    token <-
        either (die . T.unpack) pure (parseStateToken (T.pack tokenText))
    let settings = ProviderSettings url magic Nothing (Just timeDir)
        env caps =
            Env
                { envCaps = caps
                , envWallet = wallet
                , envState = stateScript
                , envRequest = requestScript
                , envToken = token
                , envFlags = flags
                }
    withReads nullTracer nullTracer settings (action . env)
  where
    need name = maybe (die ("missing " <> name)) pure (flagValue name flags)

flagValue :: String -> [String] -> Maybe String
flagValue name = \case
    (a : v : rest)
        | a == name -> Just v
        | otherwise -> flagValue name (v : rest)
    _ -> Nothing

requiredFlag :: Env -> String -> IO String
requiredFlag env name =
    maybe (die ("missing " <> name)) pure (flagValue name (envFlags env))

flagValues :: String -> [String] -> [String]
flagValues name = \case
    (a : v : rest)
        | a == name -> v : flagValues name rest
        | otherwise -> flagValues name (v : rest)
    _ -> []

outRefFlag :: Env -> String -> IO TxIn
outRefFlag env name = case flagValue name (envFlags env) of
    Nothing -> die ("missing " <> name)
    Just spelled -> either die pure (parseOutRef (T.pack spelled))

provider :: Env -> (Network, LedgerProvider NoWitness IO)
provider = capReads . envCaps

payerOf :: Env -> Addr
payerOf = walletAddr . envWallet

emit :: Handle -> Value -> IO ()
emit out value = LBS.hPutStrLn out (encode value) >> hFlush out

-- | The registry the token names.
registryOf :: Env -> RegistryIdentity
registryOf env =
    let (PolicyID policy, name) = envToken env
    in  RegistryIdentity (StatePolicyId (scriptHashBytes policy)) name

{- | The scripts of the release and where this transaction takes them from:
the live reference copies the registry's creation published.
-}
sourcesOf
    :: Env
    -> Session NoWitness IO
    -> IO (StateScript, RequestScript)
sourcesOf env session = do
    references <-
        planReferences session (payerOf env) [envState env, envRequest env]
            >>= either (die . renderRefusal) pure
    case referencesPublication references of
        Nothing -> pure ()
        Just _ ->
            die
                "the registry's scripts are not published: create the registry first"
    let found = [(hash, ref) | (hash, (ref, _)) <- referencesLive references]
        source :: Script ConwayEra -> ScriptSource
        source script = scriptSource script found
    pure
        ( StateScript (envState env) (source (envState env))
        , RequestScript (envRequest env) (source (envRequest env))
        )

-- ---------------------------------------------------------
-- Reading the chain
-- ---------------------------------------------------------

-- | The registry's state output, and the root it carries.
findState
    :: Env
    -> Session NoWitness IO
    -> IO (TxIn, TxOut ConwayEra, ByteString)
findState env session = do
    found <-
        readOutputs session (HoldingAsset (envToken env))
            >>= either (die . show) pure
    case found of
        [(ref, out)] -> case inlineDatumOf out >>= decodeStateDatum of
            Just root -> pure (ref, out, root)
            Nothing -> die "the registry's state output carries no root"
        _ -> die "the registry's state token is not in exactly one output"

outputAt :: Session NoWitness IO -> TxIn -> IO (TxOut ConwayEra)
outputAt session ref =
    readOutputs session (AtTxIn ref) >>= \case
        Right [(_, out)] -> pure out
        _ ->
            die
                ("the output " <> T.unpack (renderOutRef ref) <> " is not on the chain")

-- | The registry's trie at its current state, as a public reader rebuilds it.
withTrie
    :: Env
    -> Session NoWitness IO
    -> TxIn
    -> ByteString
    -> (TrieSnapshot IO -> IO a)
    -> IO a
withTrie env session stateIn root use =
    withTrieState (registryTrieState session) selection use
        >>= either (die . trieRefusal) pure
  where
    selection =
        TrieSelection
            { trieSelectionIdentity = registryOf env
            , trieSelectionPoint =
                StatePoint (sessionId session) (sessionBinding session) stateIn
            , trieSelectionRoot = Root root
            }

trieRefusal :: TrieFailure -> String
trieRefusal failure =
    "the registry's trie cannot be read: "
        <> T.unpack (trieFailureName failure)

-- ---------------------------------------------------------
-- The fold, as the library builds it, with one fact open to change
-- ---------------------------------------------------------

-- | Every fact of a fold of one pending registration that a case may change.
data Facts = Facts
    { fPending :: (TxIn, TxOut ConwayEra)
    , fRegistration :: Registration
    , fApproval :: AssetName
    -- ^ The approval the registration commits to
    , fBurn :: Bool
    -- ^ The fold burns the approval the pending registration holds
    , fProof :: [ProofStep]
    -- ^ The proof the change carries
    , fNewRoot :: ByteString
    , fHolding :: (Addr, Coin)
    -- ^ Where the key's token is delivered, and with how much
    , fStateExtra :: Maybe (TxIn, MaryValue)
    -- ^ A token taken from another output into the continuing state output
    , fParked :: Maybe TxIn
    -- ^ A token parked at the state address, spent as a state
    , fMintState :: Bool
    -- ^ The fold also mints a token of the existing registry state
    }

-- | The fold of the registry the library's builder makes, as facts.
honestFacts
    :: Env
    -> Session NoWitness IO
    -> Application
    -> NE.NonEmpty (TxIn, TxOut ConwayEra)
    -> (TxIn, TxOut ConwayEra, ByteString)
    -> IO (NE.NonEmpty Facts)
honestFacts env session application pendings (stateIn, _, root) = do
    registrations <- forM pendings $ \pending ->
        maybe
            (die "the pending registration is not a registration of open datum")
            pure
            ( case appDecode application (registryOf env) [] (snd pending) of
                Just (RegistrationRequest decoded) -> Just decoded
                _ -> Nothing
            )
    (proofs, newRoot) <-
        withTrie env session stateIn root $ \snapshot ->
            speculateEdges
                snapshot
                ( fmap
                    (\registration -> (regKey registration, toInteger edgeInsertActive))
                    registrations
                )
                >>= either
                    (die . trieRefusal)
                    (\walked -> pure (walkProofs walked, unRoot (walkRoot walked)))
    nonemptyProofs <-
        maybe (die "the registry gave no proofs") pure (NE.nonEmpty proofs)
    when (length proofs /= length registrations) $
        die "the registry's proof count differs from the pending count"
    pure $
        NE.zipWith
            ( \(pending, registration) proof ->
                Facts
                    { fPending = pending
                    , fRegistration = registration
                    , fApproval = approvalOfPending pending application
                    , fBurn = True
                    , fProof = proof
                    , fNewRoot = newRoot
                    , fHolding = (regHolding registration, regDeposit registration)
                    , fStateExtra = Nothing
                    , fParked = Nothing
                    , fMintState = False
                    }
            )
            (NE.zip pendings registrations)
            nonemptyProofs

{- | The approval the pending registration holds: the one token of the
application's policy in its value.
-}
approvalOfPending
    :: (TxIn, TxOut ConwayEra) -> Application -> AssetName
approvalOfPending (_, out) application =
    case out ^. valueTxOutL of
        MaryValue _ (MultiAsset assets) ->
            case Map.lookup (appPolicy application) assets of
                Just names | [(name, _)] <- Map.toList names -> name
                _ -> AssetName mempty

-- | A transaction program as the state builders write it.
foldProgram
    :: Env
    -> StateScript
    -> RequestScript
    -> (TxIn, TxOut ConwayEra, ByteString)
    -> TxIn
    -> NE.NonEmpty Facts
    -> Payer
    -> Program ()
foldProgram env stateScript requestScript (stateIn, stateOut, _) seed facts payer = do
    let registry = registryOf env
        policy = statePolicy stateScript
        (_, stateName) = envToken env
        stateValue =
            MaryValue
                (stateOut ^. coinTxOutL)
                (MultiAsset (Map.singleton policy (Map.singleton stateName 1)))
                <> foldMap (maybe mempty snd . fStateExtra) facts
    _ <-
        Tx.payTo'
            (stateAddress (payerNetwork payer) stateScript)
            stateValue
            (BuiltinData (stateDatum (fNewRoot (NE.last facts))))
    holdingIndices <- forM facts $ \fact -> do
        let registration = fRegistration fact
            key = regKey registration
            (holdingAddress, holdingCoin) = fHolding fact
            holding =
                mkBasicTxOut
                    holdingAddress
                    ( MaryValue
                        holdingCoin
                        ( MultiAsset
                            ( Map.singleton
                                policy
                                (Map.singleton (activeTokenName registry key) 1)
                            )
                        )
                    )
                    & datumTxOutL .~ mkInlineDatum (regDatum registration)
        Tx.output holding
    let changes =
            NE.zipWith
                ( \fact holdingIndex ->
                    let registration = fRegistration fact
                        Coin deposit = regDeposit registration
                    in  Register
                            { changeRequest = fst (fPending fact)
                            , changeKey = regKey registration
                            , changeHolding = toInteger holdingIndex
                            , changeDeposit = deposit
                            , changeProof = fProof fact
                            }
                )
                facts
                holdingIndices
        redeemer = BuiltinData (foldRedeemer seed (NE.toList changes))
    _ <- Tx.spendScript stateIn redeemer
    forM_ facts $ \fact -> do
        forM_ (fParked fact) $ \parked -> Tx.spendScript parked redeemer
        forM_ (fStateExtra fact) $ \(extra, _) -> Tx.spend extra
    Tx.mint
        policy
        ( Map.fromListWith
            (+)
            ( [ (activeTokenName registry (regKey (fRegistration fact)), 1)
              | fact <- NE.toList facts
              ]
                <> [(stateName, 1) | any fMintState facts]
            )
        )
        (BuiltinData foldedRedeemer)
    useScript (ssScript stateScript) (ssSource stateScript)
    forM_ (NE.zip facts holdingIndices) $ \(fact, holdingIndex) ->
        Tx.spendScript
            (fst (fPending fact))
            (AsData (spendRedeemer (RegistrationFold (toInteger holdingIndex))))
    let burns =
            Map.fromListWith
                (+)
                [(fApproval fact, -1) | fact <- NE.toList facts, fBurn fact]
    unless (Map.null burns) $
        Tx.mint
            (requestPolicy requestScript)
            burns
            (AsData (mintRedeemer [ApprovalBurn]))
    Request.useScript requestScript
    Tx.collateral (fst (payerFunding payer))

{- | Build the fold of these facts. A script that refuses stops no build: the
budget of a refused script is stated, so that the node judges the fold.
-}
buildFold
    :: Env
    -> Session NoWitness IO
    -> StateScript
    -> RequestScript
    -> Application
    -> (TxIn, TxOut ConwayEra, ByteString)
    -> NE.NonEmpty Facts
    -> IO ConwayTx
buildFold env session stateScript requestScript application state@(stateIn, stateOut, root) facts = do
    payer <-
        resolvePayer session (payerOf env) >>= either (die . show) pure
    Replayed{replayedSeed = seed} <- seedOf env session stateIn root
    stateScriptOutputs <-
        referenceOutputs session (ssScript stateScript) (ssSource stateScript)
            >>= either (die . renderRefusal) pure
    now <- tipSlot session
    deadline <-
        Services.floorSlot
            session
            ( foldl'
                min
                (regDeadline (fRegistration (NE.head facts)))
                (map (regDeadline . fRegistration) (NE.tail facts))
            )
    upper <-
        validityFromTip session now deadline
            >>= maybe (die "the processing window of the registration is closed") pure
    parkedOutput <-
        traverse
            (\ref -> (,) ref <$> outputAt session ref)
            (mapMaybe fParked (NE.toList facts))
    extraOutput <-
        traverse
            (\(ref, _) -> (,) ref <$> outputAt session ref)
            (mapMaybe fStateExtra (NE.toList facts))
    let funding = payerFunding payer
        spent =
            [funding, (stateIn, stateOut)]
                <> map fPending (NE.toList facts)
                <> parkedOutput
                <> extraOutput
    assembleLenient
        session
        spent
        (stateScriptOutputs <> appReferences application)
        (payerOf env)
        ( do
            foldProgram env stateScript requestScript state seed facts payer
            Tx.validFrom now
            Tx.validTo upper
        )
        >>= either (die . T.unpack) pure

-- | The seed of the registry, as its public history gives it.
seedOf
    :: Env
    -> Session NoWitness IO
    -> TxIn
    -> ByteString
    -> IO Replayed
seedOf env session stateIn root =
    replayRegistry session selection
        >>= either (die . trieRefusal) (pure . fst)
  where
    selection =
        TrieSelection
            { trieSelectionIdentity = registryOf env
            , trieSelectionPoint =
                StatePoint (sessionId session) (sessionBinding session) stateIn
            , trieSelectionRoot = Root root
            }

{- | The builder of the state builders, with the session's evaluator except
that a script that refuses is given a generous budget, so that the transaction
is built and the node judges it.
-}
assembleLenient
    :: Session NoWitness IO
    -> [(TxIn, TxOut ConwayEra)]
    -> [(TxIn, TxOut ConwayEra)]
    -> Addr
    -> Program ()
    -> IO (Either Text ConwayTx)
assembleLenient session spent referenced change program = do
    protocol <- Services.parameters session
    built <-
        Tx.build
            (Tx.mkPParamsBound protocol)
            (Tx.InterpretIO noQuery)
            lenient
            spent
            referenced
            change
            program
    pure (either (Left . T.pack . show) Right built)
  where
    noQuery :: NoQuery a -> IO b
    noQuery query = case query of {}
    lenient tx =
        Map.map (either (const (Right generous)) Right)
            <$> Services.evaluateTx session tx
    generous = ExUnits 3_000_000 2_000_000_000

-- ---------------------------------------------------------
-- Submitting
-- ---------------------------------------------------------

-- | What the node said to one submission.
data Answer = Accepted Text | Refused Text Text

-- | Sign with the wallet, submit, and wait only when it was accepted.
answerTo :: Env -> ConwayTx -> IO Answer
answerTo env tx = do
    let signed = signTx (walletSignKey (envWallet env)) tx
    capSubmit (envCaps env) signed >>= \case
        SubmitAccepted txid -> do
            capConfirm (envCaps env) (signedTx signed)
            pure (Accepted (txIdText txid))
        SubmitRefused why -> pure (Refused (txIdText (txIdTx tx)) why)
        SubmitFailed why -> die ("the submission failed: " <> T.unpack why)
        wrong -> die ("the submission met the wrong network: " <> show wrong)

answerJson :: Answer -> [Pair]
answerJson = \case
    Accepted txid -> ["outcome" .= ("accepted" :: Text), "transaction" .= txid]
    Refused txid why ->
        [ "outcome" .= ("refused" :: Text)
        , "transaction" .= txid
        , "answer" .= why
        ]

txIdText :: TxId -> Text
txIdText txid = T.takeWhile (/= '#') (renderOutRef (TxIn txid (toEnum 0)))

-- | Retain an ordinary packaged fold's bundle before any input is spent.
keepBatchCommand :: Handle -> Env -> IO ()
keepBatchCommand out env = do
    path <- measurementFlag env "--bundle"
    bundle <- BC.readFile path >>= either (die . show) pure . decodeBundle
    either (die . show) pure (checkBundle bundle)
    tx <- case NE.toList (bundleTransactions bundle) of
        [one] ->
            either
                (die . show)
                pure
                (decodeTransactionEnvelope (bundleTxEnvelope one))
        _ ->
            die "the measured fold bundle must contain exactly one transaction"
    Services.withLatest (provider env) $ \session -> keepBatch out env session tx

{- | Test-only: use the ordinary fold construction with raised capacity guards.
No node, provider or product parameter is changed. The original target and
node parameters still judge the resulting transaction independently.
-}
beyondCommand :: Handle -> Env -> IO ()
beyondCommand out env = Services.withLatest (provider env) $ \session -> do
    (stateScript, requestScript) <- sourcesOf env session
    application <-
        openDatumApplication session requestScript Ledger.Testnet
            >>= either (die . show) pure
    refs <-
        traverse
            (either die pure . parseOutRef . T.pack)
            (flagValues "--pending" (envFlags env))
    when (null refs) (die "a capacity probe needs named pending requests")
    let raised =
            session
                { protocolParameters = fmap (fmap raise) (protocolParameters session)
                }
        raise fact =
            fact
                { value =
                    value fact
                        & ppMaxTxExUnitsL .~ ExUnits 1_000_000_000 1_000_000_000_000
                        & ppMaxTxSizeL .~ 1_000_000
                }
    built <-
        Fold.buildFold
            raised
            stateScript
            application
            (registryOf env)
            refs
            (payerOf env)
            Nothing
            >>= either (die . show) pure
    keepBatch out env session (Fold.foldTransaction built)

keepBatch
    :: Handle -> Env -> Session NoWitness IO -> ConwayTx -> IO ()
keepBatch out env session tx = do
    destination <- measurementFlag env "--output"
    timeDirectory <- measurementFlag env "--network-time"
    inputs <- forM (Set.toAscList (evaluationInputs tx)) $ \reference ->
        (,) reference <$> outputAt session reference
    let signed = signedTx (signTx (walletSignKey (envWallet env)) tx)
    BatchMeasurement.keep destination timeDirectory signed inputs
    (stateIn, _, root) <- findState env session
    replayed <- seedOf env session stateIn root
    emit out $
        object
            [ "outcome" .= ("kept" :: Text)
            , "transaction" .= txIdText (txIdTx signed)
            , "registrySizeBefore" .= length (replayedKeys replayed)
            , "foldedCount" .= length (Fold.foldedRequests signed)
            ]

sendBatchCommand :: Handle -> Env -> IO ()
sendBatchCommand out env = do
    path <- measurementFlag env "--transaction"
    tx <- BatchMeasurement.readTransaction path
    answer <- answerTo env tx
    emit out (object (answerJson answer))

measurementFlag :: Env -> String -> IO String
measurementFlag env name =
    maybe
        (die ("missing " <> name))
        pure
        (flagValue name (envFlags env))

-- ---------------------------------------------------------
-- fold
-- ---------------------------------------------------------

foldCommand :: Handle -> Env -> IO ()
foldCommand out env = do
    caseName <-
        maybe (die "missing --case") pure (flagValue "--case" (envFlags env))
    refs <-
        traverse
            (either die pure . parseOutRef . T.pack)
            (flagValues "--pending" (envFlags env))
    pendingRefs <- maybe (die "missing --pending") pure (NE.nonEmpty refs)
    Services.withLatest (provider env) $ \session -> do
        (stateScript, requestScript) <- sourcesOf env session
        application <-
            openDatumApplication session requestScript Ledger.Testnet
                >>= either (die . show) pure
        state@(stateIn, _, root) <- findState env session
        pendings <-
            traverse (\ref -> (,) ref <$> outputAt session ref) pendingRefs
        honest <-
            honestFacts env session application pendings state
        let first = NE.head honest
            replaceFirst fact = fact NE.:| NE.tail honest
        (facts, fact) <- case caseName of
            "honest" -> pure (honest, "none: the fold as the library builds it" :: Text)
            "no-approval" ->
                pure
                    ( replaceFirst first{fBurn = False, fApproval = AssetName mempty}
                    , "the pending registration holds no approval"
                    )
            "other-address" ->
                pure
                    ( replaceFirst first{fHolding = (payerOf env, snd (fHolding first))}
                    , "the key's token is delivered to the folder's address, not the committed one"
                    )
            "less-than-deposit" ->
                pure
                    ( replaceFirst
                        first
                            { fHolding =
                                second (lessBy 100_000) (fHolding first)
                            }
                    , "the holding keeps 100000 lovelace less than the deposit"
                    )
            "second-registration" -> do
                present <-
                    presenceProof env session state (regKey (fRegistration first))
                pure
                    ( replaceFirst first{fProof = present, fNewRoot = root}
                    , "the key is already in the registry: the proof carried is the registry's own proof of it"
                    )
            "extra-token" -> do
                spare <- outRefFlag env "--spare"
                spareOutput <- outputAt session spare
                pure
                    ( replaceFirst
                        first
                            { fStateExtra = Just (spare, spareOutput ^. valueTxOutL & withoutAda)
                            }
                    , "the continuing state output also holds a token taken from another output"
                    )
            "parked-state" -> do
                parked <- outRefFlag env "--parked"
                pure
                    ( replaceFirst first{fParked = Just parked}
                    , "a token parked at the state address is spent as a state beside the registry's own"
                    )
            "state-policy-movement" ->
                pure
                    ( replaceFirst first{fMintState = True}
                    , "the batch also mints and moves another token under the state policy"
                    )
            other -> die ("--case is not one of the cases: " <> other)
        tx <-
            buildFold
                env
                session
                stateScript
                requestScript
                application
                state
                facts
        answer <- answerTo env tx
        let MultiAsset minted = tx ^. bodyTxL . mintTxBodyL
            (policy, name) = envToken env
            mintedRegistryToken =
                Map.findWithDefault
                    0
                    name
                    (Map.findWithDefault Map.empty policy minted)
        emit out $
            object
                ( [ "case" .= caseName
                  , "alteredFact" .= fact
                  , "pending" .= renderOutRef (NE.head pendingRefs)
                  , "pendings" .= map renderOutRef (NE.toList pendingRefs)
                  , "mintedRegistryToken" .= mintedRegistryToken
                  , "state" .= renderOutRef stateIn
                  ]
                    <> answerJson answer
                )
  where
    lessBy n (Coin c) = Coin (c - n)
    withoutAda (MaryValue _ assets) = MaryValue (Coin 0) assets

{- | Submit a termination made wrong in one fact. The request has been reached
through the packaged registration and booking commands. The application spend
always names the genuine request and key; a different-key state change is
therefore judged by the state validator, independently of that spend.

For the unapproved-change case the state change names ordinary funding, which
holds no approval, while the genuine request is spent separately. An approval
elsewhere in the transaction cannot approve that named input.
-}
terminationCommand :: Handle -> Env -> IO ()
terminationCommand out env = do
    caseName <- need "--case"
    key <- BC.pack <$> need "--key"
    pendingRef <- outRefFlag env "--pending"
    let registry = registryOf env
        active = activeTokenName registry key
        approval = approvalName (terminationPreimage key registry)
    Services.withLatest (provider env) $ \session -> do
        (stateScript, requestScript) <- sourcesOf env session
        application <-
            openDatumApplication session requestScript Ledger.Testnet
                >>= either (die . show) pure
        pending <- outputAt session pendingRef
        unlessTermination (appDecode application registry [key] pending)
        (stateIn, stateOut, root) <- findState env session
        payer <-
            resolvePayer session (payerOf env) >>= either (die . show) pure
        Replayed{replayedSeed = seed} <- seedOf env session stateIn root
        (changeKey, fact) <- case caseName of
            "burn-without-fold" ->
                pure
                    ( key
                    , "the active token is burned without spending the registry state"
                        :: Text
                    )
            "other-key" -> do
                other <- BC.pack <$> need "--other-key"
                when (other == key) $ die "the other key must differ"
                pure
                    ( other
                    , "the state change terminates another active key than the request approves"
                    )
            "no-approval" ->
                pure
                    ( key
                    , "the state change names an ordinary input with no approval instead of the approved request"
                    )
            "spend-without-burn" ->
                pure
                    ( key
                    , "the request is spent and its approval burned but its active token is not burned"
                    )
            _ -> die "unknown termination case"
        (proof, newRoot) <- withTrie env session stateIn root $ \snapshot -> do
            leaf <- leafAt snapshot changeKey >>= either (die . trieRefusal) pure
            when (leaf /= Active) $ die "the change must start from an active key"
            walked <-
                speculateEdges
                    snapshot
                    (NE.singleton (changeKey, toInteger edgeUpdateTerminal))
                    >>= either (die . trieRefusal) pure
            case walkProofs walked of
                [one] -> pure (one, unRoot (walkRoot walked))
                _ -> die "no single termination proof"
        references <-
            referenceOutputs session (ssScript stateScript) (ssSource stateScript)
                >>= either (die . renderRefusal) pure
        let withState = caseName /= "burn-without-fold" && caseName /= "spend-without-burn"
            burnActive = caseName /= "spend-without-burn"
            funding = payerFunding payer
            changedRequest = if caseName == "no-approval" then fst funding else pendingRef
            spent =
                [funding, (pendingRef, pending)] <> [(stateIn, stateOut) | withState]
            program = do
                void (Tx.spend (fst funding))
                when withState $ do
                    _ <-
                        Tx.payTo'
                            (stateAddress (payerNetwork payer) stateScript)
                            (stateOut ^. valueTxOutL)
                            (BuiltinData (stateDatum newRoot))
                    void $
                        Tx.spendScript
                            stateIn
                            ( BuiltinData
                                (foldRedeemer seed [Terminate changedRequest changeKey proof])
                            )
                when burnActive $ do
                    Tx.mint
                        (statePolicy stateScript)
                        (Map.singleton active (-1))
                        (BuiltinData foldedRedeemer)
                    useScript (ssScript stateScript) (ssSource stateScript)
                void $
                    Tx.spendScript
                        pendingRef
                        (AsData (spendRedeemer (TerminationFold registry key)))
                Tx.mint
                    (requestPolicy requestScript)
                    (Map.singleton approval (-1))
                    (AsData (mintRedeemer [ApprovalBurn]))
                Request.useScript requestScript
                Tx.collateral (fst funding)
        tx <-
            assembleLenient
                session
                spent
                (references <> appReferences application)
                (payerOf env)
                (void program)
                >>= either (die . T.unpack) pure
        answer <- answerTo env tx
        emit out $
            object
                ( [ "case" .= caseName
                  , "alteredFact" .= fact
                  , "pending" .= renderOutRef pendingRef
                  , "state" .= renderOutRef stateIn
                  ]
                    <> answerJson answer
                )
  where
    need name =
        maybe (die ("missing " <> name)) pure (flagValue name (envFlags env))
    unlessTermination = \case
        Just TerminationRequest{} -> pure ()
        _ -> die "the input is not a genuine termination request for this key"

-- ---------------------------------------------------------
-- update and leave
-- ---------------------------------------------------------

{- | Spend a live holding with the update redeemer, as the wallet, and submit
the transaction. The successor is at the holding's address with the holding's
control, whatever else a case changes. A case names the wallet it runs as: a
wallet that is not the one the case names is refused before anything is built,
so that a control is never signed by another wallet and an attempt never by the
controller.
-}
holdingSpend
    :: Handle
    -> Env
    -> (String, Text)
    -- ^ The case, and the one fact it makes wrong
    -> Bool
    -- ^ The wallet is the holding's controller
    -> Bool
    -- ^ The successor holds the key's token
    -> Maybe PLC.Data
    -- ^ The payload that replaces the holding's own
    -> IO ()
holdingSpend out env (caseName, fact) byController keepsToken replacement = do
    reference <- outRefFlag env "--holding"
    Services.withLatest (provider env) $ \session -> do
        (_, requestScript) <- sourcesOf env session
        application <-
            openDatumApplication session requestScript Ledger.Testnet
                >>= either (die . show) pure
        before <- outputAt session reference
        (control, held, controller) <-
            maybe
                (die "the output is not a live holding of this application")
                pure
                ( do
                    datum <- inlineDatumOf before
                    (protected, payload) <- decodeLiveDatum datum
                    case datum of
                        PLC.Constr 2 [control, _] ->
                            Just (control, payload, controlController protected)
                        _ -> Nothing
                )
        payer <-
            resolvePayer session (payerOf env) >>= either (die . show) pure
        let KeyHash walletKey = payerKey payer
        when ((hashToBytes walletKey == controller) /= byController) $
            die $
                if byController
                    then "the wallet is not the holding's controller"
                    else "the wallet is the holding's controller"
        let value = before ^. valueTxOutL
            MaryValue coin _ = value
            funding = payerFunding payer
            successor = PLC.Constr 2 [control, fromMaybe held replacement]
            program = do
                index <-
                    Tx.payTo'
                        (before ^. addrTxOutL)
                        (if keepsToken then value else MaryValue coin mempty)
                        (AsData successor)
                _ <-
                    Tx.spendScript
                        reference
                        (AsData (spendRedeemer (LiveUpdate (toInteger index))))
                Request.useScript requestScript
                Tx.requireSignature (payerKey payer)
                Tx.collateral (fst funding)
        tx <-
            assembleLenient
                session
                [funding, (reference, before)]
                (appReferences application)
                (payerOf env)
                (void program)
                >>= either (die . T.unpack) pure
        answer <- answerTo env tx
        emit out $
            object
                ( [ "case" .= caseName
                  , "alteredFact" .= fact
                  , "holding" .= renderOutRef reference
                  ]
                    <> answerJson answer
                )

updateCommand :: Handle -> Env -> IO ()
updateCommand out env = do
    caseName <- requiredFlag env "--case"
    payload <-
        requiredFlag env "--payload" >>= readPayloadFile PlainSchema
    case caseName of
        "honest" ->
            holdingSpend
                out
                env
                ( caseName
                , "none: the update as the library builds it, signed by the holding's controller"
                )
                True
                True
                (Just payload)
        "no-controller-signature" ->
            holdingSpend
                out
                env
                ( caseName
                , "the update is signed by a wallet that is not the holding's controller"
                )
                False
                True
                (Just payload)
        other -> die ("--case is not one of the cases: " <> other)

leaveCommand :: Handle -> Env -> IO ()
leaveCommand out env = do
    caseName <- requiredFlag env "--case"
    case caseName of
        "honest" ->
            holdingSpend
                out
                env
                (caseName, "none: the holding is recreated with the key's token")
                True
                True
                Nothing
        "token-out" ->
            holdingSpend
                out
                env
                (caseName, "the key's token is not returned to the holding")
                True
                False
                Nothing
        other -> die ("--case is not one of the cases: " <> other)

-- | The proof the registry itself gives for a key it holds.
presenceProof
    :: Env
    -> Session NoWitness IO
    -> (TxIn, TxOut ConwayEra, ByteString)
    -> ByteString
    -> IO [ProofStep]
presenceProof env session (stateIn, _, root) key =
    withTrie env session stateIn root $ \snapshot -> do
        leaf <- leafAt snapshot key >>= either (die . trieRefusal) pure
        when (leaf == Unknown) $ die "the registry does not hold the key"
        bytes <-
            membership snapshot key leaf
                >>= either (die . trieRefusal) (pure . membershipBytes)
        case deserialiseOrFail (BL.fromStrict bytes) of
            Right (PLC.List steps) ->
                maybe
                    (die "the registry's answer for the key could not be read")
                    pure
                    (traverse (fromBuiltinData . BuiltinData) steps)
            _ -> die "the registry's answer for the key could not be read"

-- ---------------------------------------------------------
-- plain-copy
-- ---------------------------------------------------------

{- | Pay the value of a pending registration, without its approval, to the
request address with the same datum.
-}
plainCopyCommand :: Handle -> Env -> IO ()
plainCopyCommand out env = do
    pendingRef <- outRefFlag env "--pending"
    Services.withLatest (provider env) $ \session -> do
        original <- outputAt session pendingRef
        payer <-
            resolvePayer session (payerOf env) >>= either (die . show) pure
        let MaryValue coin _ = original ^. valueTxOutL
            copy =
                mkBasicTxOut (original ^. addrTxOutL) (MaryValue coin mempty)
                    & datumTxOutL .~ (original ^. datumTxOutL)
        tx <-
            assemble
                session
                [payerFunding payer]
                []
                (payerOf env)
                (void (Tx.output copy))
                >>= either (die . T.unpack) pure
        answer <- answerTo env tx
        case answer of
            Accepted txid ->
                emit out $
                    object
                        [ "outcome" .= ("accepted" :: Text)
                        , "transaction" .= txid
                        , "output" .= renderOutRef (TxIn (txIdTx tx) (toEnum 0))
                        , "copyOf" .= renderOutRef pendingRef
                        ]
            Refused _ why -> die ("the copy was refused: " <> T.unpack why)

-- ---------------------------------------------------------
-- spares
-- ---------------------------------------------------------

{- | The script that accepts any use: a Plutus V3 program that returns unit
for any context. It is the program @(lam ctx (con unit ()))@ at version 1.1.0,
written out in the flat encoding the ledger reads.
-}
acceptingScript :: Script ConwayEra
acceptingScript =
    scriptFromBytes
        "accepting"
        (SBS.pack [0x45, 0x01, 0x01, 0x00, 0x24, 0x99])

-- | Mint a token parked at the state address and one paid to the wallet.
sparesCommand :: Handle -> Env -> IO ()
sparesCommand out env =
    Services.withLatest (provider env) $ \session -> do
        (stateScript, _) <- sourcesOf env session
        (_, _, root) <- findState env session
        payer <-
            resolvePayer session (payerOf env) >>= either (die . show) pure
        let policy = PolicyID (hashScript acceptingScript)
            parkedName = AssetName (SBS.toShort (BC.pack "parked"))
            spareName = AssetName (SBS.toShort (BC.pack "spare"))
            tokenOf name =
                MaryValue
                    (Coin 0)
                    (MultiAsset (Map.singleton policy (Map.singleton name 1)))
        tx <-
            assemble
                session
                [payerFunding payer]
                []
                (payerOf env)
                ( do
                    _ <-
                        Tx.payTo'
                            (stateAddress (payerNetwork payer) stateScript)
                            (tokenOf parkedName)
                            (BuiltinData (stateDatum root))
                    _ <- Tx.payTo (payerOf env) (tokenOf spareName)
                    Tx.mint
                        policy
                        (Map.fromList [(parkedName, 1), (spareName, 1)])
                        (BuiltinData (PLC.Constr 0 []))
                    Tx.attachScript acceptingScript
                    Tx.collateral (fst (payerFunding payer))
                )
                >>= either (die . T.unpack) pure
        answer <- answerTo env tx
        case answer of
            Accepted txid ->
                emit out $
                    object
                        [ "outcome" .= ("accepted" :: Text)
                        , "transaction" .= txid
                        , "parked" .= renderOutRef (TxIn (txIdTx tx) (toEnum 0))
                        , "spare" .= renderOutRef (TxIn (txIdTx tx) (toEnum 1))
                        ]
            Refused _ why -> die ("the spares were refused: " <> T.unpack why)
