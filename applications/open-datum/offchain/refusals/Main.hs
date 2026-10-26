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
> no-pin-refusals fold --case CASE --pending TXID#IX [--parked TXID#IX] [--spare TXID#IX]

The shared flags are @--koios-url@, @--network-time@, @--network-magic@,
@--wallet-skey@, @--blueprint@ (the release's validators) and @--state-token@
(the registry).

@spares@ mints two tokens under a script that accepts any use: one parked at the
state address with a root datum, the way anyone may park a token there, and one
paid to the wallet.

@plain-copy@ pays the value of a pending registration, without its approval, to
the request address with the same datum: a registration that nothing approved.

@fold@ folds the pending registration it is given as the wallet, from the chain
alone, and submits it. The cases are the honest fold and the five facts that make
it wrong: @no-approval@ (the registration carries no approval), @other-address@
(the key's token is delivered to the folder's address), @less-than-deposit@ (the
holding keeps less than the deposit), @second-registration@ (the key is already
in the registry, shown by the proof the registry itself gives for it),
@extra-token@ (the continuing state output also holds a token the folder took
from another output) and @parked-state@ (a token parked at the state address is
spent as a state beside the registry's own). Each alteration changes exactly one
fact of the honest fold; the output names it.
-}
module Main (main) where

import Codec.Serialise (deserialiseOrFail)
import Control.Monad (forM_, void, when)
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

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (txIdTx)
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
    , SpendAction (..)
    , mintRedeemer
    , spendRedeemer
    )
import Singular.Application.OpenDatum.Requests.Script
    ( RequestScript (..)
    , requestPolicy
    , requestScriptFromBlueprint
    )
import Singular.Application.OpenDatum.Requests.Script qualified as Request
import Singular.CLI.Steps (renderRefusal, scriptSource)
import Singular.Registry.Blueprint (loadBlueprint)
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Deployment (parseOutRef, renderOutRef)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (ConwayEra, Root (..), TxOut)
import Singular.Registry.LedgerProvider
    ( Asset
    , LedgerProvider
    , Network
    , OutputQuery (..)
    , Session (..)
    , SubmitResult (..)
    )
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
import Singular.Registry.Types (ProofStep, edgeInsertActive)
import Singular.Registry.Wallet (Wallet (..), loadWallet)
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
    )
import Singular.State.Lineage
    ( Replayed (..)
    , registryTrieState
    , replayRegistry
    )
import Singular.State.Preimage (activeTokenName)
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
        ("spares" : flags) -> withEnv flags (sparesCommand out)
        ("plain-copy" : flags) -> withEnv flags (plainCopyCommand out)
        ("fold" : flags) -> withEnv flags (foldCommand out)
        _ ->
            die
                "usage: no-pin-refusals (spares|plain-copy|fold) \
                \--koios-url URL --network-time DIR --network-magic N \
                \--wallet-skey FILE --blueprint FILE --state-token POLICY.NAME \
                \[--case CASE] [--pending TXID#IX] [--parked TXID#IX] [--spare TXID#IX]"

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
    }

-- | The fold of the registry the library's builder makes, as facts.
honestFacts
    :: Env
    -> Session NoWitness IO
    -> Application
    -> (TxIn, TxOut ConwayEra)
    -> (TxIn, TxOut ConwayEra, ByteString)
    -> IO Facts
honestFacts env session application pending (stateIn, _, root) = do
    registration <-
        maybe
            (die "the pending registration is not a registration of open datum")
            pure
            (appDecode application (snd pending))
    (proofs, newRoot) <-
        withTrie env session stateIn root $ \snapshot ->
            speculateEdges
                snapshot
                (NE.singleton (regKey registration, toInteger edgeInsertActive))
                >>= either
                    (die . trieRefusal)
                    (\walked -> pure (walkProofs walked, unRoot (walkRoot walked)))
    proof <- case proofs of
        [one] -> pure one
        _ -> die "the registry gave no single answer for the key"
    pure
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
            }

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
    -> Facts
    -> Payer
    -> Program ()
foldProgram env stateScript requestScript (stateIn, stateOut, _) seed facts payer = do
    let registration = fRegistration facts
        registry = registryOf env
        policy = statePolicy stateScript
        (_, stateName) = envToken env
        key = regKey registration
        (holdingAddress, holdingCoin) = fHolding facts
        (pendingRef, _) = fPending facts
        stateValue =
            MaryValue
                (stateOut ^. coinTxOutL)
                (MultiAsset (Map.singleton policy (Map.singleton stateName 1)))
                <> maybe mempty snd (fStateExtra facts)
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
    _ <-
        Tx.payTo'
            (stateAddress (payerNetwork payer) stateScript)
            stateValue
            (BuiltinData (stateDatum (fNewRoot facts)))
    holdingIndex <- Tx.output holding
    let Coin deposit = regDeposit registration
        redeemer =
            BuiltinData
                ( foldRedeemer
                    seed
                    [ Register
                        { changeRequest = pendingRef
                        , changeKey = key
                        , changeHolding = toInteger holdingIndex
                        , changeDeposit = deposit
                        , changeProof = fProof facts
                        }
                    ]
                )
    _ <- Tx.spendScript stateIn redeemer
    forM_ (fParked facts) $ \parked -> Tx.spendScript parked redeemer
    forM_ (fStateExtra facts) $ \(extra, _) -> Tx.spend extra
    Tx.mint
        policy
        (Map.singleton (activeTokenName registry key) 1)
        (BuiltinData foldedRedeemer)
    useScript (ssScript stateScript) (ssSource stateScript)
    _ <-
        Tx.spendScript
            pendingRef
            (AsData (spendRedeemer (RegistrationFold (toInteger holdingIndex))))
    when (fBurn facts) $
        Tx.mint
            (requestPolicy requestScript)
            (Map.singleton (fApproval facts) (-1))
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
    -> Facts
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
        Services.floorSlot session (regDeadline (fRegistration facts))
    upper <-
        validityFromTip session now deadline
            >>= maybe (die "the processing window of the registration is closed") pure
    parkedOutput <-
        traverse (\ref -> (,) ref <$> outputAt session ref) (fParked facts)
    extraOutput <-
        traverse
            (\(ref, _) -> (,) ref <$> outputAt session ref)
            (fStateExtra facts)
    let funding = payerFunding payer
        spent =
            [funding, (stateIn, stateOut), fPending facts]
                <> maybe [] pure parkedOutput
                <> maybe [] pure extraOutput
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

-- ---------------------------------------------------------
-- fold
-- ---------------------------------------------------------

foldCommand :: Handle -> Env -> IO ()
foldCommand out env = do
    caseName <-
        maybe (die "missing --case") pure (flagValue "--case" (envFlags env))
    pendingRef <- outRefFlag env "--pending"
    Services.withLatest (provider env) $ \session -> do
        (stateScript, requestScript) <- sourcesOf env session
        application <-
            openDatumApplication session requestScript Ledger.Testnet
                >>= either (die . show) pure
        state@(stateIn, _, root) <- findState env session
        pendingOutput <- outputAt session pendingRef
        honest <-
            honestFacts env session application (pendingRef, pendingOutput) state
        (facts, fact) <- case caseName of
            "honest" -> pure (honest, "none: the fold as the library builds it" :: Text)
            "no-approval" ->
                pure
                    ( honest{fBurn = False, fApproval = AssetName mempty}
                    , "the pending registration holds no approval"
                    )
            "other-address" ->
                pure
                    ( honest{fHolding = (payerOf env, snd (fHolding honest))}
                    , "the key's token is delivered to the folder's address, not the committed one"
                    )
            "less-than-deposit" ->
                pure
                    ( honest
                        { fHolding =
                            second (lessBy 100_000) (fHolding honest)
                        }
                    , "the holding keeps 100000 lovelace less than the deposit"
                    )
            "second-registration" -> do
                present <-
                    presenceProof env session state (regKey (fRegistration honest))
                pure
                    ( honest{fProof = present, fNewRoot = root}
                    , "the key is already in the registry: the proof carried is the registry's own proof of it"
                    )
            "extra-token" -> do
                spare <- outRefFlag env "--spare"
                spareOutput <- outputAt session spare
                pure
                    ( honest
                        { fStateExtra = Just (spare, spareOutput ^. valueTxOutL & withoutAda)
                        }
                    , "the continuing state output also holds a token taken from another output"
                    )
            "parked-state" -> do
                parked <- outRefFlag env "--parked"
                pure
                    ( honest{fParked = Just parked}
                    , "a token parked at the state address is spent as a state beside the registry's own"
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
    lessBy n (Coin c) = Coin (c - n)
    withoutAda (MaryValue _ assets) = MaryValue (Coin 0) assets

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
