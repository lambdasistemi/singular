{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

{- |
Module      : Singular.CLI.Create
Description : @singular registry create@: boot an open-datum registry from the caller's seed
License     : Apache-2.0

The caller names a seed: an unspent, ada-only output of their own wallet.
The seed decides the registry's identity — its state token name, and so
the open-datum application applied to that identity and the three witness
policies — so every pin is derived before anything is submitted, and
@--preview@ stops there, submitting nothing and writing nothing.

Otherwise, in order, each submission journalled and each result read
back before the next: the state validator is published from outside the
seed (the seed survives the publication); the boot consumes the seed and
creates the state output at the empty root; the request validator, the
three witness policies and the applied application are published as
reference outputs. Only then are the public files written: the saved
identity with its deployment record and
the committed root. A directory that already holds any registry file is
refused before a node is contacted: create never overwrites a registry.
-}
module Singular.CLI.Create (runCreate) where

import Data.Aeson (Value, toJSON)
import Data.Aeson qualified as Aeson
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.Aeson.Key qualified as Key
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Short qualified as SBS
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((^.))
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRoot (..)
    , OnChainTokenState (..)
    )
import System.Directory (createDirectoryIfMissing)

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body (mintTxBodyL)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , coinTxOutL
    , referenceScriptTxOutL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..), TxIx (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (Script, hashScript)
import Cardano.Ledger.Mary.Value (MultiAsset (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import Data.Word (Word32)

import Singular.Application.OpenDatum.Script
    ( Application (..)
    , applicationTitle
    )
import Singular.CLI.Command
    ( CreateArgs (..)
    , EntryMode (..)
    , ProviderSettings (..)
    , WriteSettings (..)
    )
import Singular.CLI.Live (receipt, txInText)
import Singular.CLI.Receipt (OutcomeClass (..), durableWrite)
import Singular.CLI.Registry
    ( Release
    , economics
    , hexT
    , loadRelease
    , mkRegistryConfig
    , parseEnterpriseAddress
    , pendingPath
    , pinsOf
    , refuseExisting
    , registryConfigFor
    , renderIdentityError
    , seedChecks
    , writeConfig
    )
import Singular.CLI.Session
    ( WriteContext (..)
    , expecting
    , failWith
    , journalObserved
    , journalObservedId
    , submitBuilt
    , txIdHex
    , withSession
    , withWrite
    )
import Singular.Registry.Blueprint (NamingCodes (..))
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Config.Application (RegistryEconomics (..))
import Singular.Registry.Deployment
    ( Deployment (..)
    , ReferenceScript (..)
    , parseOutRef
    , renderAddrBytes
    )
import Singular.Registry.Ledger
    ( AssetName (..)
    , ConwayEra
    , TokenId (..)
    )
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.Terminal (Capabilities (..), withReads)
import Singular.Registry.TxBuilder.Boot (bootTokenImpl)
import Singular.Registry.TxBuilder.Edges
    ( adaOnlyOut
    , publishRefScriptTx
    , stateRefIn
    , witnessScriptOf
    )
import Singular.Registry.TxBuilder.Internal
    ( addrKeyHashBytes
    , cageAddrFromCfg
    , cagePolicyIdFromCfg
    , emptyRoot
    , extractCageDatum
    , findStateUtxo
    , mkRequestScript
    , scriptFromBytes
    , scriptHashBytes
    , txInToRef
    )
import Singular.Registry.Wallet (Wallet (..), bech32Address)

runCreate :: CreateArgs -> IO Value
runCreate a = do
    let dir = createRegistry a
    refuseExisting dir
        >>= either (failWith ClientRefusal . renderIdentityError) pure
    rel <-
        loadRelease (createBlueprint a)
            >>= either (failWith ClientRefusal) pure
    case createMode a of
        Preview settings addrText -> do
            let magic = providerMagic settings
            -- A preview for a public address reads the node and holds no key.
            addr <-
                either
                    (failWith ClientRefusal)
                    pure
                    (parseEnterpriseAddress magic addrText)
            withReads settings $ \caps -> do
                utxos <- Cage.withLatest (capReads caps) (`Cage.outputsAt` addr)
                (_, identity) <- previewIdentity False a rel addr utxos
                pure (receipt "create" Success (("preview", toJSON True) : identity))
        Submit ws -> createWith a rel ws

createWith :: CreateArgs -> Release -> WriteSettings -> IO Value
createWith a rel ws = do
    let dir = createRegistry a
    -- A preview writes nothing: no lock, no directory, no journal.
    let session = if createPreview a then withSession else withWrite
    session dir "create" ws $ \wc -> do
        let addr = walletAddr (wcWallet wc)
        utxos <-
            Cage.withLatest (capReads (wcCapabilities wc)) (`Cage.outputsAt` addr)
        ((seedIn, cfg, pinned), identity) <-
            previewIdentity (not (createPreview a)) a rel addr utxos
        if createPreview a
            then
                pure (receipt "create" Success (("preview", toJSON True) : identity))
            else do
                -- The existence check again, now under the target's lock: a
                -- create that passed it before another create finished
                -- must not boot a second registry over the first.
                refuseExisting dir
                    >>= either (failWith ClientRefusal . renderIdentityError) pure
                createDirectoryIfMissing True dir
                -- The public identity, durable before the first submission:
                -- an interrupted create stays inspectable and is refused a
                -- second boot.
                let ProviderSettings _ magicNow _ _ = writeProvider ws
                durableWrite
                    (pendingPath dir)
                    ( BL.toStrict
                        ( encodePretty
                            ( Aeson.object
                                ( ("networkMagic" Aeson..= magicNow)
                                    : [(Key.fromText k, v) | (k, v) <- identity]
                                )
                            )
                        )
                    )
                booted <- boot wc cfg pinned seedIn
                let ProviderSettings _ magic _ _ = writeProvider ws
                    dep = deploymentOf magic cfg seedIn booted
                -- The identity marks a create that finished; trie state is read
                -- from public history by subsequent acquired commands.
                writeConfig dir (mkRegistryConfig magic addr (pinsOf cfg) dep)
                pure
                    ( receipt
                        "create"
                        Success
                        ( identity
                            <> [ ("token", toJSON (tokenHex (bootedToken booted)))
                               , ("processTime", toJSON (stateProcessTime (bootedState booted)))
                               , ("retractTime", toJSON (stateRetractTime (bootedState booted)))
                               , ("boot", toJSON (bootedBoot booted))
                               , ("transactions", toJSON (bootedTxs booted))
                               ,
                                   ( "references"
                                   , toJSON
                                        [ Aeson.object
                                            [ "role" Aeson..= refRole r
                                            , "output" Aeson..= refOutRef r
                                            , "scriptHash" Aeson..= refHash r
                                            ]
                                        | r <- bootedRefs booted
                                        ]
                                   )
                               , ("root", toJSON (hexT emptyRoot))
                               ]
                        )
                    )

-- | What a boot made.
data Booted = Booted
    { bootedToken :: TokenId
    , bootedBody :: ConwayTx
    , bootedOutput :: TxIn
    , bootedRoot :: ByteString
    , bootedState :: OnChainTokenState
    , bootedBoot :: Text
    -- ^ The boot's transaction id
    , bootedRefs :: [ReferenceScript]
    , bootedTxs :: [Text]
    -- ^ Every transaction the boot submitted, in order
    }

tokenHex :: TokenId -> Text
tokenHex (TokenId (AssetName n)) = hexT (SBS.fromShort n)

boot :: WriteContext -> CageConfig -> NamingCodes -> TxIn -> IO Booted
boot wc cfg pinned seedIn = do
    let prov = capReads (wcCapabilities wc)
        addr = walletAddr (wcWallet wc)
        -- One transaction, built from one view, journalled with its point.
        publish step reserved script = do
            (signed, refOut) <-
                submitBuilt
                    wc
                    step
                    ( const
                        (expecting ("reference:" <> hexT (scriptHashBytes (hashScript script))))
                    )
                    (\v -> publishRefScriptTx reserved v addr script)
            pure (TxIn (txIdTx signed) (TxIx 0), refOut)
    -- The state validator, published from outside the seed, unless the
    -- wallet already publishes it.
    existing <-
        Cage.withLatest prov (\v -> stateRefIn cfg <$> Cage.outputsAt v addr)
    stateRef@(stateIn, _) <-
        maybe
            ( publish
                "publish-state"
                (Set.singleton seedIn)
                (scriptFromBytes "state" (cageScriptBytes cfg))
            )
            pure
            existing
    observeReference
        wc
        "publish-state"
        addr
        (scriptFromBytes "state" (cageScriptBytes cfg))
        stateRef
    -- The boot, consuming the seed.
    (signedBoot, ()) <-
        submitBuilt
            wc
            "boot"
            (const (expecting "state"))
            (\v -> (,()) <$> bootTokenImpl cfg v addr)
    tid <- case signedBoot ^. bodyTxL . mintTxBodyL of
        MultiAsset m -> case Map.lookup (cagePolicyIdFromCfg cfg) m of
            Just names | [(name, 1)] <- Map.toList names -> pure (TokenId name)
            _ -> failWith LedgerRefusal "the boot minted no single registry token"
    stateUtxos <-
        Cage.withLatest
            prov
            (`Cage.outputsAt` cageAddrFromCfg cfg (network cfg))
    (seenOutput, seenState) <- case findStateUtxo (cagePolicyIdFromCfg cfg) tid stateUtxos of
        Nothing ->
            failWith Partial "the boot confirmed but its state output is not live"
        Just (output, out) -> do
            state <- case extractCageDatum out of
                Just (StateDatum found) -> pure found
                _ -> failWith Partial "the boot's state output carries no state datum"
            journalObserved
                wc
                "boot"
                signedBoot
                "the state output holds the registry token"
            pure (output, state)
    -- The references every later command resolves its scripts through.
    let scripts =
            [ ("request", mkRequestScript cfg tid)
            , ("witness-absent", witnessScriptOf cfg pinned 0)
            , ("witness-active", witnessScriptOf cfg pinned 1)
            , ("witness-terminal", witnessScriptOf cfg pinned 2)
            , ("application", scriptFromBytes "open-datum" (ncApplication pinned))
            ]
    published <-
        mapM
            ( \(role, script) -> do
                ref <- publish ("publish-" <> role) Set.empty script
                observeReference wc ("publish-" <> role) addr script ref
                pure (reference role addr script ref)
            )
            scripts
    let stateScript = scriptFromBytes "state" (cageScriptBytes cfg)
    pure
        Booted
            { bootedToken = tid
            , bootedBody = signedBoot
            , bootedOutput = seenOutput
            , bootedRoot = unOnChainRoot (stateRoot seenState)
            , bootedState = seenState
            , bootedBoot = txIdHex signedBoot
            , bootedRefs = reference "state" addr stateScript stateRef : published
            , bootedTxs =
                [txInTxId stateIn, txIdHex signedBoot]
                    <> map (txIdOfRef . refOutRef) published
            }
  where
    txInTxId = T.takeWhile (/= '#') . txInText
    txIdOfRef = T.takeWhile (/= '#')

{- | Read a published reference back — the exact output, live, carrying
exactly this script — and only then journal it @observed@. A missing or
different reference leaves the publication at @confirmed@, unresolved.
-}
observeReference
    :: WriteContext
    -> Text
    -> Addr
    -> Script ConwayEra
    -> (TxIn, TxOut ConwayEra)
    -> IO ()
observeReference wc step addr script (i, _) = do
    utxos <-
        Cage.withLatest (capReads (wcCapabilities wc)) (`Cage.outputsAt` addr)
    let wanted = hashScript script
    case [o | (j, o) <- utxos, j == i] of
        [o]
            | SJust carried <- o ^. referenceScriptTxOutL
            , hashScript carried == wanted ->
                journalObservedId
                    wc
                    step
                    (T.takeWhile (/= '#') (txInText i))
                    ( "reference output "
                        <> txInText i
                        <> " is live carrying script "
                        <> hexT (scriptHashBytes wanted)
                    )
        [_] ->
            failWith
                Partial
                ( T.unpack step
                    <> ": the output "
                    <> T.unpack (txInText i)
                    <> " carries another script"
                )
        _ ->
            failWith
                Partial
                ( T.unpack step
                    <> ": the published reference output "
                    <> T.unpack (txInText i)
                    <> " is not live"
                )

reference
    :: Text
    -> Addr
    -> Script ConwayEra
    -> (TxIn, TxOut ConwayEra)
    -> ReferenceScript
reference role addr script (i, _) =
    ReferenceScript
        { refRole = role
        , refHash = hexT (scriptHashBytes (hashScript script))
        , refOutRef = txInText i
        , refAddress = T.pack (bech32Address addr)
        , refAddressBytes = renderAddrBytes addr
        }

deploymentOf :: Word32 -> CageConfig -> TxIn -> Booted -> Deployment
deploymentOf magic cfg seedIn b =
    Deployment
        { depRelease = "singular"
        , depLeanRevision = ""
        , depNetworkMagic = magic
        , depSeedOutRef = txInText seedIn
        , depCageToken = tokenHex (bootedToken b)
        , depStatePolicy = hexT (scriptHashBytes (cfgScriptHash cfg))
        , depRequestHash =
            maybe
                ""
                refHash
                (lookup "request" [(refRole r, r) | r <- bootedRefs b])
        , depApplicationHash = hexT (SBS.fromShort (cfgApplicationPolicy cfg))
        , depRepresentativePolicy = hexT (SBS.fromShort (cfgActivePolicy cfg))
        , depProcessTime = defaultProcessTime cfg
        , depRetractTime = defaultRetractTime cfg
        , depTip = let Coin c = defaultTip cfg in c
        , depReferenceScripts = bootedRefs b
        , depBootstrapTxs = bootedTxs b
        }

{- | The registry identity a seed would give: the chosen or the largest
ada-only output of the caller, checked to be held and ada only, the
configuration and pins every later command derives again, and the receipt
fields that name them. Nothing is written or submitted.

A create must also find another ada-only output beside the seed
('checkSeed'): it refuses without one. A preview computes the identity
regardless and reports, as @createRefusal@, the refusal a create from this
wallet would meet now, or null.
-}
previewIdentity
    :: Bool
    -- ^ whether the identity is for a create about to submit
    -> CreateArgs
    -> Release
    -> Addr
    -> [(TxIn, TxOut ConwayEra)]
    -> IO ((TxIn, CageConfig, NamingCodes), [(Text, Value)])
previewIdentity submitting a rel addr utxos = do
    seedIn <- case createSeed a of
        Just s -> either (failWith ClientRefusal) pure (parseOutRef (T.pack s))
        Nothing -> case sortOn
            (Down . (^. coinTxOutL) . snd)
            (filter (adaOnlyOut . snd) utxos) of
            ((i, _) : _) -> pure i
            [] ->
                failWith
                    ClientRefusal
                    "the wallet holds no ada-only output to preview a seed with"
    funding <-
        either
            (failWith ClientRefusal . renderIdentityError)
            pure
            (seedChecks submitting seedIn utxos)
    let chosen =
            economics
                { reProcessTime = createProcessTime a
                , reRetractTime = createRetractTime a
                }
        (cfg, pinned) = registryConfigFor rel chosen (txInToRef seedIn)
        identity =
            [ ("application", toJSON (applicationTitle OpenDatumApplication))
            , ("seed", toJSON (txInText seedIn))
            , ("wallet", toJSON (T.pack (bech32Address addr)))
            , ("walletKeyHash", toJSON (hexT (addrKeyHashBytes addr)))
            , ("pins", toJSON (pinsOf cfg))
            ]
                <> funding
    pure ((seedIn, cfg, pinned), identity)
