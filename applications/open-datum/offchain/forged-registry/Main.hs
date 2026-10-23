{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Main
Description : A test harness: a registry whose datum pins a forged active policy
License     : Apache-2.0

A tool for the forged-pins journey, never a product command: no command a user
runs can pin a policy the release does not derive, so the one registry the
journey needs, a genuine registry made by the real contracts and the real boot
whose datum pins an always-true active policy, is made here. Every subcommand
reads its provider, its wallet and its release from flags, runs against a
running development network, and prints one JSON object on standard output;
the boot's own narration goes to standard error.

> forged-registry boot  --mode forged|genuine [--application open|closed]
> forged-registry mint  --key TEXT
> forged-registry fold-evidence --seed TXID#IX
> forged-registry fold-altering-a-pin

The shared flags are @--koios-url@, @--network-time@, @--network-magic@,
@--wallet-skey@ and @--blueprint@ (the deployment blueprint).

@boot@ makes a registry for this application's open mode, or for its closed one
under @--application closed@: the application pin is the honest derivation,
the active pin is the always-true script's hash under
@--mode forged@ and the honest derivation under @--mode genuine@, the control.
Nothing else differs between the two.

@mint@ mints a token named after the key under the always-true policy and pays
it to the wallet: what a reader that trusts the datum takes for the key's
registration.

@fold-evidence@ is the evidence for the on-chain hardening: it books an
insertion on the forged registry and submits two folds, one that mints under
the honest derivation of the active policy instead of the pinned one, and one
that mints the pinned token and, beside it, a token under the honest witness
policy, and prints the node's answer to each.

@fold-altering-a-pin@ boots its own registry with honest pins, books an
insertion, submits a fold that swaps the active pin in the new state datum for
the always-true script's hash, an honest fold that also mints a token under the
registry's own active policy beyond what its request owes, and then the honest
fold of the same request, and prints the node's answer to each.
-}
module Main (main) where

import Control.Exception (ErrorCall (..), try)
import Control.Monad (unless, void, when)
import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy.Char8 qualified as LBS
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import Lens.Micro ((%~), (&), (.~), (^.))
import System.Environment (getArgs)
import System.Exit (die)
import System.IO
    ( Handle
    , hFlush
    , stderr
    , stdout
    )
import Text.Read (readMaybe)

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (bodyTxL, mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , inputsTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , coinTxOutL
    , datumTxOutL
    , getMinCoinTxOut
    , mkBasicTxOut
    )
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Core (Script, hashScript)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxId, TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import Control.Tracer (nullTracer)
import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins.Internal (BuiltinByteString (..))

import Singular.Application.OpenDatum.Book
    ( insertApproval
    , insertDestination
    )
import Singular.Application.OpenDatum.InsertEnvelope (insertEnvelope)
import Singular.Application.OpenDatum.Value
    ( closedDatumApplication
    , openDatumApplication
    )
import Singular.CLI.Registry
    ( economics
    , hexT
    , loadRelease
    , pinsOf
    , registryConfigFor
    )
import Singular.Registry.Application (Application (..))
import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint (NamingCodes (..))
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Deployment (parseOutRef, renderOutRef)
import Singular.Registry.Driver qualified as Driver
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (Coin (..), ConwayEra, TokenId (..))
import Singular.Registry.LedgerProvider
    ( Asset
    , LedgerProvider
    , Network
    , SubmitResult (..)
    )
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.Signing (signTx, signedTx)
import Singular.Registry.StateToken
    ( ReferenceRole (..)
    , Release (..)
    , carriesReference
    , expectedReferences
    , findReferences
    , renderReferenceRefusal
    , renderStateToken
    )
import Singular.Registry.Terminal (submitWithWallet, withReads)
import Singular.Registry.Trie (TrieManager (..))
import Singular.Registry.Trie.PureManager (mkPureTrieManager)
import Singular.Registry.TxBuilder.ConnectedFold
    ( ConnectedFoldArgs (..)
    , ConnectedMint (..)
    , RawRedeemer (..)
    , connectedFoldTx
    )
import Singular.Registry.TxBuilder.Edges
    ( BookingApproval (..)
    , adaOnlyOut
    , bookEdgeWith
    , certifyBooking
    , publishRefScript
    , registryContextFor
    , witnessScriptOf
    )
import Singular.Registry.TxBuilder.Internal
    ( addrKeyHashBytes
    , cageAddrFromCfg
    , cagePolicyIdFromCfg
    , computeScriptHash
    , extractCageDatum
    , findStateUtxo
    , findUtxoByTxIn
    , mkInlineDatum
    , requestAddrFromCfg
    , scriptFromBytes
    , scriptHashBytes
    , toPlcData
    , txInToRef
    )
import Singular.Registry.TxBuilder.Update
    ( RegistryContext (..)
    , RegistryDuties (..)
    , registryDuties
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainTokenState (..)
    , edgeInsertActive
    )
import Singular.Registry.Wallet
    ( Wallet (..)
    , bech32Address
    , loadWallet
    )

{- | The always-true script: a Plutus V3 program that accepts any use for any
redeemer and any context. It is the program @(lam ctx (con unit ()))@ at
version 1.1.0, written out in the flat encoding the ledger reads: the three
version numbers (1, 1, 0), the lambda tag, the constant tag with the type tag
of unit, and the padding, wrapped once as a byte string. It stands for the
policy a registry's creator pins as the active policy so that anything can be
minted under it.
-}
forgedScriptBytes :: SBS.ShortByteString
forgedScriptBytes = SBS.pack [0x45, 0x01, 0x01, 0x00, 0x24, 0x99]

-- | The always-true script.
forgedScript :: Script ConwayEra
forgedScript = scriptFromBytes "forged-active-policy" forgedScriptBytes

-- | The forged active policy: the always-true script's hash, 28 bytes.
forgedPin :: SBS.ShortByteString
forgedPin = SBS.toShort (scriptHashBytes (computeScriptHash forgedScriptBytes))

-- | Which active pin a boot writes into the datum.
data Mode = Forged | Genuine
    deriving stock (Eq, Show)

-- | The providers, wallet, application and release every subcommand needs.
data Env = Env
    { envCaps :: Capabilities NoWitness IO
    , envWallet :: Wallet
    , envApp :: Application
    , envRelease :: Release
    , envFlags :: [String]
    }

main :: IO ()
main = do
    args <- getArgs
    -- The library narrates a boot on standard output; the one JSON object this
    -- tool prints must be alone on it.
    out <- hDuplicate stdout
    hDuplicateTo stderr stdout
    case args of
        ("boot" : flags) -> withEnv flags (bootCommand out)
        ("mint" : flags) -> withEnv flags (mintCommand out)
        ("fold-evidence" : flags) -> withEnv flags (foldEvidenceCommand out)
        ("fold-altering-a-pin" : flags) -> withEnv flags (alteringCommand out)
        _ ->
            die
                "usage: forged-registry (boot|mint|fold-evidence|fold-altering-a-pin) \
                \--koios-url URL --network-time DIR --network-magic N \
                \--wallet-skey FILE --blueprint FILE [--mode forged|genuine] \
                \[--seed TXID#IX] [--key TEXT]"

-- ---------------------------------------------------------
-- Setting up
-- ---------------------------------------------------------

withEnv :: [String] -> (Env -> IO a) -> IO a
withEnv flags action = do
    url <- need "--koios-url"
    timeDir <- need "--network-time"
    magicText <- need "--network-magic"
    keyPath <- need "--wallet-skey"
    blueprint <- need "--blueprint"
    magic <-
        maybe
            (die ("--network-magic is not a number: " <> magicText))
            pure
            (readMaybe magicText)
    wallet <- loadWallet magic keyPath
    app <- case flagValue "--application" flags of
        Nothing -> pure openDatumApplication
        Just "open" -> pure openDatumApplication
        Just "closed" -> pure closedDatumApplication
        Just other -> die ("--application is open or closed, not " <> other)
    release <- loadRelease app blueprint >>= either die pure
    let settings = ProviderSettings url magic Nothing (Just timeDir)
        env caps =
            Env
                { envCaps = caps
                , envWallet = wallet
                , envApp = app
                , envRelease = release
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

emit :: Handle -> Value -> IO ()
emit out value = LBS.hPutStrLn out (encode value) >> hFlush out

provider :: Env -> (Network, LedgerProvider NoWitness IO)
provider = capReads . envCaps

payerOf :: Env -> Addr
payerOf = walletAddr . envWallet

-- | Sign with the wallet, submit, and wait: the whole transaction must land.
landed :: Env -> ConwayTx -> IO ConwayTx
landed env = submitWithWallet (envWallet env) (envCaps env)

outputsOf :: Env -> Addr -> IO [(TxIn, TxOut ConwayEra)]
outputsOf env addr = Cage.withLatest (provider env) (`Cage.outputsAt` addr)

-- | The wallet's largest output holding nothing but ada and no script.
largestAdaOnly
    :: [(TxIn, TxOut ConwayEra)] -> IO (TxIn, TxOut ConwayEra)
largestAdaOnly utxos =
    case sortOn
        (Down . (^. coinTxOutL) . snd)
        (filter (adaOnlyOut . snd) utxos) of
        u : _ -> pure u
        [] -> die "the wallet holds no ada-only output"

-- | The registry a seed names: its configuration and the codes it runs.
registryFor :: Env -> TxIn -> Mode -> (CageConfig, NamingCodes)
registryFor env seed mode =
    let (cfg, pinned) =
            registryConfigFor
                (envApp env)
                (envRelease env)
                economics
                (txInToRef seed)
    in  case mode of
            Genuine -> (cfg, pinned)
            Forged -> (cfg{cfgActivePolicy = forgedPin}, pinned)

tokenIdOf :: TxIn -> TokenId
tokenIdOf seed =
    TokenId (AssetName (SBS.toShort (deriveAssetName (txInToRef seed))))

stateTokenOf :: Env -> TxIn -> Asset
stateTokenOf env seed =
    ( PolicyID (computeScriptHash (releaseState (envRelease env)))
    , AssetName (SBS.toShort (deriveAssetName (txInToRef seed)))
    )

seedFlag :: Env -> IO TxIn
seedFlag env = case flagValue "--seed" (envFlags env) of
    Nothing -> die "missing --seed"
    Just spelled -> either die pure (parseOutRef (T.pack spelled))

-- ---------------------------------------------------------
-- boot
-- ---------------------------------------------------------

{- | Boot a registry from one of the wallet's outputs through the real boot,
with the active pin the mode names, and publish the scripts the registry's
commands resolve through, as @create@ does.
-}
bootCommand :: Handle -> Env -> IO ()
bootCommand out env = do
    mode <- case flagValue "--mode" (envFlags env) of
        Just "forged" -> pure Forged
        Just "genuine" -> pure Genuine
        _ -> die "--mode is forged or genuine"
    (seed, reg, cfg, pinned) <- bootWith env mode
    emit out $
        object
            [ "stateToken" .= renderStateToken (stateTokenOf env seed)
            , "seed" .= renderOutRef seed
            , "mode" .= (if mode == Forged then "forged" else "genuine" :: Text)
            , "pins" .= pinsOf cfg
            , "forgedActivePolicy" .= hexT (SBS.fromShort forgedPin)
            , "honestActivePolicy"
                .= hexT
                    (SBS.fromShort (cfgActivePolicy (fst (registryFor env seed Genuine))))
            , "bootTransaction" .= txIdText (txIdTx (Driver.registryBootTx reg))
            , "walletAddress" .= T.pack (bech32Address (payerOf env))
            , "applicationHash"
                .= hexT (scriptHashBytes (computeScriptHash (ncApplication pinned)))
            ]

bootWith
    :: Env
    -> Mode
    -> IO (TxIn, Driver.Registry, CageConfig, NamingCodes)
bootWith env mode = do
    let prov = provider env
        payer = payerOf env
        stateScript = scriptFromBytes "state" (releaseState (envRelease env))
    held <- outputsOf env payer
    unless (any (carriesReference (hashScript stateScript) . snd) held) $
        void (publishRefScript prov (landed env) payer stateScript)
    utxos <- outputsOf env payer
    (seed, _) <- largestAdaOnly utxos
    let (cfg, pinned) = registryFor env seed mode
    tm <- mkPureTrieManager
    reg <- Driver.bootRegistry cfg pinned prov (landed env) payer tm
    -- the application's own publication, as the product's create makes it
    void $
        publishRefScript
            prov
            (landed env)
            payer
            (scriptFromBytes "application" (ncApplication pinned))
    pure (seed, reg, cfg, pinned)

-- ---------------------------------------------------------
-- mint
-- ---------------------------------------------------------

{- | Mint one token named after the key under the always-true policy and pay it
to the wallet.
-}
mintCommand :: Handle -> Env -> IO ()
mintCommand out env = do
    key <- case flagValue "--key" (envFlags env) of
        Just text | not (null text) -> pure (BC.pack text)
        _ -> die "missing --key"
    let payer = payerOf env
        policy = PolicyID (hashScript forgedScript)
        name = AssetName (SBS.toShort key)
        minted = MultiAsset (Map.singleton policy (Map.singleton name 1))
    unsigned <- Cage.withLatest (provider env) $ \v -> do
        pp <- Cage.parameters v
        utxos <- Cage.outputsAt v payer
        (feeIn, feeOut) <- largestAdaOnly utxos
        let Coin held = feeOut ^. coinTxOutL
            fee = 2_000_000
            holding c = mkBasicTxOut payer (MaryValue (Coin c) minted)
            Coin first = getMinCoinTxOut pp (holding 0)
            Coin settled = getMinCoinTxOut pp (holding first)
            change = held - settled - fee
        when (change <= 0) $
            die "the wallet's largest output is too small to mint from"
        let body =
                mkBasicTxBody
                    & inputsTxBodyL .~ Set.singleton feeIn
                    & outputsTxBodyL
                        .~ StrictSeq.fromList
                            [ holding settled
                            , mkBasicTxOut payer (MaryValue (Coin change) mempty)
                            ]
                    & feeTxBodyL .~ Coin fee
            approval =
                BookingApproval
                    { baAsset = minted
                    , baRedeemer = PLC.Constr 0 []
                    , baScript = forgedScript
                    , baScriptReference = Nothing
                    , baReferenceInputs = Set.empty
                    }
        pure (certifyBooking pp feeIn (Just approval) (mkBasicTx body))
    signed <- landed env unsigned
    emit out $
        object
            [ "policy" .= hexT (scriptHashBytes (hashScript forgedScript))
            , "assetName" .= hexT key
            , "assetNameText" .= T.pack (BC.unpack key)
            , "output" .= renderOutRef (TxIn (txIdTx signed) (TxIx 0))
            , "address" .= T.pack (bech32Address payer)
            ]

-- ---------------------------------------------------------
-- folds
-- ---------------------------------------------------------

-- | One fold of one booked request, and what it is built to do.
data FoldPlan = FoldPlan
    { fpCfg :: CageConfig
    -- ^ the configuration the fold is built for
    , fpWitnesses :: Map.Map Integer (Script ConwayEra)
    -- ^ witness scripts that replace the honest derivation, by kind
    , fpExtra :: Maybe (Script ConwayEra, ByteString)
    -- ^ one more token minted beside the request's own: script and name
    , fpAttach :: [Script ConwayEra]
    -- ^ scripts no published reference carries
    , fpSkipEvaluation :: Bool
    -- ^ state the units instead of evaluating, so the node judges the fold
    }

-- | The plain fold of the registry's own request, evaluated before it is built.
plainPlan :: CageConfig -> FoldPlan
plainPlan cfg =
    FoldPlan
        { fpCfg = cfg
        , fpWitnesses = Map.empty
        , fpExtra = Nothing
        , fpAttach = []
        , fpSkipEvaluation = False
        }

{- | Book an insertion of the key on the registry the configuration names, with
the application's own booking: the envelope it builds, the approval its script
certifies and the destination that carries the envelope. The application's mint
policy judges the booking against the registry's actual state; that it accepts
it is what makes the request one a fold takes. Returns the request's output.
-}
bookInsert
    :: Env -> CageConfig -> NamingCodes -> TokenId -> ByteString -> IO TxIn
bookInsert env cfg pinned tid key = do
    let payer = payerOf env
        net = network cfg
        deposit = 2_000_000
        applied = ncApplication pinned
        envelope =
            insertEnvelope
                cfg
                tid
                key
                (addrKeyHashBytes payer)
                deposit
                (PLC.Map [(PLC.B "owner", PLC.B "harness")])
    cageUtxos <- outputsOf env (cageAddrFromCfg cfg net)
    (stateIn, _) <-
        maybe
            (die "the registry's state output is not on the chain")
            pure
            (findStateUtxo (cagePolicyIdFromCfg cfg) tid cageUtxos)
    booking <-
        bookEdgeWith
            cfg
            (provider env)
            (landed env)
            payer
            tid
            key
            edgeInsertActive
            (insertDestination net applied envelope)
            deposit
            (Just (insertApproval net applied stateIn envelope))
    pure (TxIn (txIdTx booking) (TxIx 0))

{- | Build the fold of the booked request as the plan says, with the
connected-fold builder the registry's own folds use: the registry's duties
for the request, plus the plan's difference.
-}
buildFold
    :: Env
    -> TrieManager IO
    -> TokenId
    -> TxIn
    -> NamingCodes
    -> Asset
    -> FoldPlan
    -> IO ConwayTx
buildFold env tm tid reqIn pinned token plan = Cage.withLatest (provider env) $ \v -> do
    let cfg = fpCfg plan
        payer = payerOf env
        net = network cfg
    pp <- Cage.parameters v
    cageUtxos <- Cage.outputsAt v (cageAddrFromCfg cfg net)
    stateUtxo <-
        maybe
            (die "the registry's state output is not on the chain")
            pure
            (findStateUtxo (cagePolicyIdFromCfg cfg) tid cageUtxos)
    requests <- Cage.outputsAt v (requestAddrFromCfg cfg tid net)
    request <-
        maybe
            ( die
                ("the request " <> T.unpack (renderOutRef reqIn) <> " is not pending")
            )
            pure
            (findUtxoByTxIn reqIn requests)
    wallet <- Cage.outputsAt v payer
    feeUtxo <- largestAdaOnly wallet
    -- the references the honest derivation of this registry names: the state
    -- script, the request script and the active witness
    let expected = expectedReferences (appPin (envApp env)) (envRelease env) token
        needed = Set.fromList [RoleState, RoleRequest, RoleWitnessActive]
    found <-
        findReferences v (Just payer) expected needed
            >>= either (die . T.unpack . renderReferenceRefusal) pure
    let refs = Map.elems found
    context <- registryContextFor cfg pinned v refs
    let ctx =
            context
                { rcWitnessScripts =
                    Map.union (fpWitnesses plan) (rcWitnessScripts context)
                }
        oldState = case extractCageDatum (snd stateUtxo) of
            Just (StateDatum s) -> s
            _ -> error "the state output carries no state datum"
    duties <-
        either die pure (registryDuties cfg pp oldState ctx [request] [True])
    let extraMint = case fpExtra plan of
            Nothing -> []
            Just (script, name) ->
                [ ConnectedMint
                    { cmPolicy = PolicyID (hashScript script)
                    , cmAssets = Map.singleton (AssetName (SBS.toShort name)) 1
                    , cmRedeemer = RawRedeemer (PLC.Constr 0 [])
                    , cmScript = script
                    }
                ]
        extraOutput = case fpExtra plan of
            Nothing -> []
            Just (script, name) ->
                let held c =
                        mkBasicTxOut
                            payer
                            ( MaryValue
                                (Coin c)
                                ( MultiAsset
                                    ( Map.singleton
                                        (PolicyID (hashScript script))
                                        (Map.singleton (AssetName (SBS.toShort name)) 1)
                                    )
                                )
                            )
                    Coin first = getMinCoinTxOut pp (held 0)
                    Coin settled = getMinCoinTxOut pp (held first)
                in  [held settled]
    fst
        <$> connectedFoldTx
            ConnectedFoldArgs
                { cfaCfg = cfg
                , cfaSession = v
                , cfaTrie = tm
                , cfaToken = tid
                , cfaFeeAddr = payer
                , cfaStateUtxo = stateUtxo
                , cfaReqUtxos = [request]
                , cfaFeeUtxo = feeUtxo
                , cfaSpends = rdSpends duties
                , cfaMints = rdMints duties <> extraMint
                , cfaOutputs = rdOutputs duties <> extraOutput
                , cfaSigners = rdSigners duties
                , cfaRefUtxos = refs
                , cfaAttachScripts = fpAttach plan
                , cfaSkipEval = fpSkipEvaluation plan
                , cfaAdjustRoot = id
                }

-- | What the node said to one submission.
data Answer = Accepted Text | Refused Text Text | NotSubmitted Text
    deriving stock (Eq, Show)

{- | Submit a transaction signed by the wallet and report the answer; wait only
when it was accepted.
-}
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

answerJson :: Answer -> Value
answerJson = \case
    Accepted txid -> object ["outcome" .= ("accepted" :: Text), "transaction" .= txid]
    Refused txid why ->
        object
            [ "outcome" .= ("refused" :: Text)
            , "transaction" .= txid
            , "answer" .= why
            ]
    NotSubmitted why ->
        object ["outcome" .= ("not-submitted" :: Text), "answer" .= why]

{- | The token the plan mints beside the request's own, as the journey reads it:
the policy and the name.
-}
extraToken :: Script ConwayEra -> ByteString -> Value
extraToken script name =
    object
        [ "policy" .= hexT (scriptHashBytes (hashScript script))
        , "assetName" .= hexT name
        ]

-- ---------------------------------------------------------
-- fold-evidence: the genuine witness policy of the forged registry
-- ---------------------------------------------------------

foldEvidenceCommand :: Handle -> Env -> IO ()
foldEvidenceCommand out env = do
    seed <- seedFlag env
    let (cfgForged, pinned) = registryFor env seed Forged
        (cfgHonest, _) = registryFor env seed Genuine
        tid = tokenIdOf seed
        token = stateTokenOf env seed
        genuineWitness = witnessScriptOf cfgHonest pinned 1
        stolen = "alice"
    tm <- mkPureTrieManager
    createTrie tm tid
    reqIn <- bookInsert env cfgForged pinned tid "bob"
    -- the honest derivation of the active policy instead of the pinned one
    insteadTx <-
        buildFold
            env
            tm
            tid
            reqIn
            pinned
            token
            (plainPlan cfgHonest){fpSkipEvaluation = True}
    instead <- answerTo env insteadTx
    -- the pinned token the request owes, and beside it a token under the
    -- honest witness policy that nothing owes
    besideTx <-
        buildFold
            env
            tm
            tid
            reqIn
            pinned
            token
            (plainPlan cfgForged)
                { fpWitnesses = Map.singleton 1 forgedScript
                , fpExtra = Just (genuineWitness, stolen)
                , fpAttach = [forgedScript]
                }
    beside <- answerTo env besideTx
    emit out $
        object
            [ "stateToken" .= renderStateToken token
            , "request" .= renderOutRef reqIn
            , "forgedActivePolicy" .= hexT (SBS.fromShort forgedPin)
            , "honestActivePolicy"
                .= hexT (SBS.fromShort (cfgActivePolicy cfgHonest))
            , "honestInsteadOfPinned" .= answerJson instead
            , "pinnedAndHonestBeside" .= answerJson beside
            , "extraToken" .= extraToken genuineWitness stolen
            ]

-- ---------------------------------------------------------
-- fold-altering-a-pin
-- ---------------------------------------------------------

{- | Replace the active pin in the new state datum, the continuation output of a
fold, by the forged policy: the one thing a fold of a registry must never do.
-}
swapActivePin :: ConwayTx -> ConwayTx
swapActivePin tx =
    tx
        & bodyTxL . outputsTxBodyL %~ (StrictSeq.fromList . swapFirst . toList)
  where
    swapFirst :: [TxOut ConwayEra] -> [TxOut ConwayEra]
    swapFirst = \case
        output : rest -> swap output : rest
        [] -> error "the fold has no continuation output"
    swap :: TxOut ConwayEra -> TxOut ConwayEra
    swap output = case extractCageDatum output of
        Just (StateDatum s) ->
            output
                & datumTxOutL
                    .~ mkInlineDatum
                        ( toPlcData
                            ( StateDatum
                                s
                                    { stateActivePolicy =
                                        BuiltinByteString (SBS.fromShort forgedPin)
                                    }
                            )
                        )
        _ -> error "the continuation output carries no state datum"

alteringCommand :: Handle -> Env -> IO ()
alteringCommand out env = do
    (seed, _reg, cfg, pinned) <- bootWith env Genuine
    let tid = tokenIdOf seed
        token = stateTokenOf env seed
        honestWitness = witnessScriptOf cfg pinned 1
        beyond = "beyond"
    tm <- mkPureTrieManager
    createTrie tm tid
    reqIn <- bookInsert env cfg pinned tid "kept"
    fold <- buildFold env tm tid reqIn pinned token (plainPlan cfg)
    let altered = swapActivePin fold
    when (altered == fold) $ die "the pin swap changed nothing"
    swapped <- answerTo env altered
    -- Evaluated here, before any submission: on an honest registry the
    -- builder's own evaluation of the deployed validator refuses it.
    extra <-
        try @ErrorCall
            ( buildFold
                env
                tm
                tid
                reqIn
                pinned
                token
                (plainPlan cfg){fpExtra = Just (honestWitness, beyond)}
            )
            >>= \case
                Right tx -> answerTo env tx
                Left (ErrorCall why) -> pure (NotSubmitted (T.pack why))
    honest <- answerTo env fold
    emit out $
        object
            [ "stateToken" .= renderStateToken token
            , "request" .= renderOutRef reqIn
            , "forgedActivePolicy" .= hexT (SBS.fromShort forgedPin)
            , "activePolicy" .= hexT (SBS.fromShort (cfgActivePolicy cfg))
            , "alteredPin" .= answerJson swapped
            , "extraMintOnHonestRegistry" .= answerJson extra
            , "extraToken" .= extraToken honestWitness beyond
            , "unalteredFold" .= answerJson honest
            ]

-- | A transaction identity as the cardano tools spell it: 64 hex digits.
txIdText :: TxId -> Text
txIdText txid = T.takeWhile (/= '#') (renderOutRef (TxIn txid (TxIx 0)))
