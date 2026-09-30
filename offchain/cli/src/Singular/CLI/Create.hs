{-# LANGUAGE OverloadedStrings #-}

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
identity with its deployment record, the empty authenticated mirror, and
the committed root. A directory that already holds any registry file is
refused before a node is contacted: create never overwrites a registry.
-}
module Singular.CLI.Create (runCreate) where

import Data.Aeson (Value, toJSON)
import Data.Aeson qualified as Aeson
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.Aeson.Key qualified as Key
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Short qualified as SBS
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((^.))
import System.Directory (createDirectoryIfMissing)

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body (mintTxBodyL)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , coinTxOutL
    , referenceScriptTxOutL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (Script, hashScript)
import Cardano.Ledger.Mary.Value (MultiAsset (..))
import Cardano.Ledger.TxIn (TxIn)
import Data.Word (Word32)

import MPF.Backend.Pure (emptyMPFInMemoryDB)

import Singular.Application.OpenDatum.Script
    ( Application (..)
    , applicationTitle
    )
import Singular.CLI.Command
    ( CreateArgs (..)
    , NodeSettings (..)
    , WriteSettings (..)
    )
import Singular.CLI.Live (receipt, txInText)
import Singular.CLI.Receipt (OutcomeClass (..), durableWrite)
import Singular.CLI.Registry
    ( LocalState (..)
    , checkSeed
    , configPath
    , hexT
    , loadRelease
    , mkRegistryConfig
    , pendingPath
    , pinsOf
    , refuseExisting
    , registryConfigFor
    , renderIdentityError
    , writeConfig
    , writeLocalState
    )
import Singular.CLI.Session
    ( WriteContext (..)
    , expecting
    , failWith
    , journalObserved
    , journalObservedId
    , journalledSubmit
    , txIdHex
    , withSession
    , withWrite
    )
import Singular.Registry.Blueprint (NamingCodes (..))
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Deployment
    ( Deployment (..)
    , ReferenceScript (..)
    , parseOutRef
    , renderAddrBytes
    , saveMirror
    )
import Singular.Registry.Ledger
    ( AssetName (..)
    , ConwayEra
    , TokenId (..)
    )
import Singular.Registry.Node
    ( NodeSession (..)
    , Wallet (..)
    , bech32Address
    )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.TxBuilder.Boot (bootTokenImpl)
import Singular.Registry.TxBuilder.Edges
    ( adaOnlyOut
    , publishRefScript
    , publishStateRefReserving
    , witnessScriptOf
    )
import Singular.Registry.TxBuilder.Internal
    ( addrKeyHashBytes
    , cageAddrFromCfg
    , cagePolicyIdFromCfg
    , emptyRoot
    , findStateUtxo
    , mkRequestScript
    , scriptFromBytes
    , scriptHashBytes
    , txInToRef
    )

runCreate :: CreateArgs -> IO Value
runCreate a = do
    let dir = createRegistry a
    refuseExisting dir
        >>= either (failWith ClientRefusal . renderIdentityError) pure
    rel <-
        loadRelease (createBlueprint a)
            >>= either (failWith ClientRefusal) pure
    -- A preview writes nothing: no lock, no directory, no journal.
    let session = if createPreview a then withSession else withWrite
    session dir "create" (createWrite a) $ \wc -> do
        let sess = wcSession wc
            prov = nsProvider sess
            addr = walletAddr (wcWallet wc)
        utxos <- Cage.queryUTxOs prov addr
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
        _ <-
            either
                (failWith ClientRefusal . renderIdentityError)
                pure
                (checkSeed seedIn utxos)
        let (cfg, pinned) = registryConfigFor rel (txInToRef seedIn)
            identity =
                [ ("application", toJSON (applicationTitle OpenDatumApplication))
                , ("seed", toJSON (txInText seedIn))
                , ("wallet", toJSON (T.pack (bech32Address addr)))
                , ("walletKeyHash", toJSON (hexT (addrKeyHashBytes addr)))
                , ("pins", toJSON (pinsOf cfg))
                ]
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
                let NodeSettings _ magicNow = writeNode (createWrite a)
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
                let NodeSettings _ magic = writeNode (createWrite a)
                    dep = deploymentOf magic cfg seedIn booted
                writeConfig dir (mkRegistryConfig magic addr (pinsOf cfg) dep)
                saveMirror
                    (configPath dir)
                    (Map.singleton (bootedToken booted) emptyMPFInMemoryDB)
                writeLocalState
                    dir
                    LocalState
                        { localVersion = 1
                        , localToken = tokenHex (bootedToken booted)
                        , localRoot = hexT emptyRoot
                        , localLastTx = Just (bootedBoot booted)
                        , localLastSlot = Nothing
                        }
                pure
                    ( receipt
                        "create"
                        Success
                        ( identity
                            <> [ ("token", toJSON (tokenHex (bootedToken booted)))
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
    let sess = wcSession wc
        prov = nsProvider sess
        addr = walletAddr (wcWallet wc)
        submit = journalledSubmit wc
    -- The state validator, published from outside the seed.
    stateRef@(stateIn, _) <-
        publishStateRefReserving
            (Set.singleton seedIn)
            cfg
            prov
            ( submit
                "publish-state"
                ( expecting
                    ( "reference:"
                        <> hexT
                            ( scriptHashBytes
                                (hashScript (scriptFromBytes "state" (cageScriptBytes cfg)))
                            )
                    )
                )
            )
            addr
    observeReference
        wc
        "publish-state"
        addr
        (scriptFromBytes "state" (cageScriptBytes cfg))
        stateRef
    -- The boot, consuming the seed.
    signedBoot <-
        bootTokenImpl cfg prov addr >>= submit "boot" (expecting "state")
    tid <- case signedBoot ^. bodyTxL . mintTxBodyL of
        MultiAsset m -> case Map.lookup (cagePolicyIdFromCfg cfg) m of
            Just names | [(name, 1)] <- Map.toList names -> pure (TokenId name)
            _ -> failWith LedgerRefusal "the boot minted no single registry token"
    stateUtxos <- Cage.queryUTxOs prov (cageAddrFromCfg cfg (network cfg))
    case findStateUtxo (cagePolicyIdFromCfg cfg) tid stateUtxos of
        Nothing ->
            failWith Partial "the boot confirmed but its state output is not live"
        Just _ ->
            journalObserved
                wc
                "boot"
                signedBoot
                "the state output holds the registry token"
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
                ref <-
                    publishRefScript
                        prov
                        ( submit
                            ("publish-" <> role)
                            (expecting ("reference:" <> hexT (scriptHashBytes (hashScript script))))
                        )
                        addr
                        script
                observeReference wc ("publish-" <> role) addr script ref
                pure (reference role addr script ref)
            )
            scripts
    let stateScript = scriptFromBytes "state" (cageScriptBytes cfg)
    pure
        Booted
            { bootedToken = tid
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
    utxos <- Cage.queryUTxOs (nsProvider (wcSession wc)) addr
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
