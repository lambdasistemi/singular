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

Otherwise, before anything is submitted, a live carrier of the state
validator is looked for by its hash (the provider, then the wallet) and the
wallet is checked to fund every publication still to make.
Then, in order, each submission journalled and each result read back before
the next: the state validator is published from outside the seed unless a
carrier was found (the seed survives the publication); the boot consumes
the seed and creates the state output at the empty root, running the state
validator from that reference; the request validator, the three witness
policies and the applied application are published as reference outputs to
the creator's wallet. The receipt names the state token, which is the
registry: no identity file is written, and the pending identity recorded
for an interrupted create is removed once it finishes. A directory that
holds a journal or a pending create is refused before a node is contacted.
-}
module Singular.CLI.Create (runCreate) where

import Control.Exception (throwIO)
import Data.Aeson (Value, toJSON)
import Data.Aeson qualified as Aeson
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.Aeson.Key qualified as Key
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Short qualified as SBS
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Ord (Down (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((&), (.~), (^.))
import System.Directory (createDirectoryIfMissing, removeFile)

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body (mintTxBodyL)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , coinTxOutL
    , mkBasicTxOut
    , referenceScriptTxOutL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..), TxIx (..))
import Cardano.Ledger.Core (Script, hashScript)
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)

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
    ( Release (..)
    , economics
    , hexT
    , parseEnterpriseAddress
    , pendingPath
    , pinsOf
    , publicationFunding
    , refuseExisting
    , registryConfigFor
    , renderIdentityError
    , seedChecks
    )
import Singular.CLI.Session
    ( Building (..)
    , Env (..)
    , WriteContext (..)
    , expecting
    , failWith
    , journalObserved
    , journalObservedId
    , readOnce
    , readStep
    , submitBuilt
    , submitBuiltIn
    , txIdHex
    , withSession
    , withWrite
    )
import Singular.CLI.Trace
    ( EdgeAction (..)
    , Scope (..)
    , What (Created, EdgeStarted, RegistrySeen)
    , report
    )
import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint (NamingCodes (..))
import Singular.Registry.Capabilities (sessionReceipt)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Config.Application (RegistryEconomics (..))
import Singular.Registry.Deployment
    ( ReferenceScript (..)
    , parseOutRef
    , renderAddrBytes
    )
import Singular.Registry.Evidence (Evidenced (..), NoWitness)
import Singular.Registry.Ledger
    ( AssetName (..)
    , Coin (..)
    , ConwayEra
    , TokenId (..)
    )
import Singular.Registry.LedgerProvider (Asset)
import Singular.Registry.LedgerProvider qualified as LP
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.StateToken
    ( ReferenceRefusal (..)
    , ReferenceRole (..)
    , expectedReferences
    , findReferences
    , renderReferenceRefusal
    , renderStateToken
    )
import Singular.Registry.TxBuilder.Boot (bootCostBound, bootTokenFrom)
import Singular.Registry.TxBuilder.Edges
    ( adaOnlyOut
    , publishRefScriptTx
    , witnessScriptOf
    )
import Singular.Registry.TxBuilder.Internal
    ( addrKeyHashBytes
    , cageAddrFromCfg
    , cagePolicyIdFromCfg
    , computeScriptHash
    , emptyRoot
    , extractCageDatum
    , findStateUtxo
    , mkRequestScript
    , scriptFromBytes
    , scriptHashBytes
    , txInToRef
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRoot (..)
    , OnChainTokenState (..)
    )
import Singular.Registry.Wallet (Wallet (..), bech32Address)

runCreate :: Env -> CreateArgs -> IO Value
runCreate env a = do
    let dir = createRegistry a
    refuseExisting dir
        >>= either (failWith ClientRefusal . renderIdentityError) pure
    rel <-
        envLoadRelease env (createBlueprint a)
            >>= either (failWith ClientRefusal) pure
    case createMode a of
        Preview settings addrText -> do
            let magic = providerMagic settings
            -- A preview for a public address reads the provider and holds no key.
            addr <-
                either
                    (failWith ClientRefusal)
                    pure
                    (parseEnterpriseAddress magic addrText)
            readOnce env settings ["wallet outputs"] $ \caps v -> do
                utxos <- Cage.outputsAt v addr
                (_, identity) <- previewIdentity False a rel addr utxos
                scope <- sessionReceipt caps v
                pure $
                    receipt
                        "create"
                        Success
                        ( [("preview", toJSON True), ("sessionEvidence", scope)]
                            <> identity
                        )
        Submit ws -> createWith env a rel ws

createWith
    :: Env -> CreateArgs -> Release -> WriteSettings -> IO Value
createWith env a rel ws = do
    let dir = createRegistry a
    -- A preview writes nothing: no lock, no directory, no journal.
    let session = if createPreview a then withSession else withWrite
    session env dir "create" ws $ \wc -> do
        let addr = walletAddr (wcWallet wc)
        (utxos, scope) <-
            readStep
                (wcTracer wc)
                (wcSource wc)
                ["wallet outputs"]
                (wcCapabilities wc)
                ( \v -> do
                    outputs <- Cage.outputsAt v addr
                    evidence <- sessionReceipt (wcCapabilities wc) v
                    pure (outputs, evidence)
                )
        ((seedIn, cfg, pinned), identity) <-
            previewIdentity (not (createPreview a)) a rel addr utxos
        if createPreview a
            then
                pure $
                    receipt
                        "create"
                        Success
                        ( [("preview", toJSON True), ("sessionEvidence", scope)]
                            <> identity
                        )
            else do
                -- The existence check again, now under the target's lock: a
                -- create that passed it before another create finished
                -- must not boot a second registry over the first.
                refuseExisting dir
                    >>= either (failWith ClientRefusal . renderIdentityError) pure
                -- The state reference, found by its hash wherever it sits,
                -- and the funding of every publication still to make, all
                -- decided before anything is written or submitted.
                (foundState, pp) <-
                    readStep
                        (wcTracer wc)
                        (wcSource wc)
                        ["reference scripts"]
                        (wcCapabilities wc)
                        $ \v -> do
                            found <- stateReference v addr rel seedIn
                            (found,) <$> Cage.parameters v
                let token = stateTokenOf rel seedIn
                    stateScript = scriptFromBytes "state" (cageScriptBytes cfg)
                    beforeBoot = case foundState of
                        Just _ -> []
                        Nothing -> [("state", stateScript)]
                    -- The boot references a carrier of this script, found
                    -- or about to be published; its size prices the boot.
                    carrier =
                        fromMaybe
                            ( seedIn
                            , mkBasicTxOut addr (MaryValue (Coin 0) mempty)
                                & referenceScriptTxOutL .~ SJust stateScript
                            )
                            foundState
                either
                    (failWith ClientRefusal . renderIdentityError)
                    pure
                    ( publicationFunding
                        pp
                        seedIn
                        (bootCostBound pp carrier)
                        beforeBoot
                        (laterScripts cfg pinned (TokenId (snd token)))
                        utxos
                    )
                createDirectoryIfMissing True dir
                -- The pending identity, durable before the first submission:
                -- an interrupted create stays inspectable with its own token
                -- and is refused a second boot.
                let ProviderSettings _ magic _ _ = writeProvider ws
                durableWrite
                    (pendingPath dir)
                    ( BL.toStrict
                        ( encodePretty
                            ( Aeson.object
                                ( ("networkMagic" Aeson..= magic)
                                    : [(Key.fromText k, v) | (k, v) <- identity]
                                )
                            )
                        )
                    )
                booted <- boot wc cfg pinned seedIn foundState
                -- The registry is its token: nothing of it stays on disk.
                removeFile (pendingPath dir)
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

-- | The state token a seed makes under this release.
stateTokenOf :: Release -> TxIn -> Asset
stateTokenOf rel seedIn =
    ( PolicyID (computeScriptHash (releaseState rel))
    , AssetName (SBS.toShort (deriveAssetName (txInToRef seedIn)))
    )

{- | A live output carrying the state script, found by its hash through the
provider, then the wallet; none when neither has one.
-}
stateReference
    :: LP.Session NoWitness IO
    -> Addr
    -- ^ The creator's wallet
    -> Release
    -> TxIn
    -> IO (Maybe (TxIn, TxOut ConwayEra))
stateReference v wallet rel seedIn = do
    found <-
        findReferences
            v
            (Just wallet)
            (expectedReferences rel (stateTokenOf rel seedIn))
            (Set.singleton RoleState)
    case found of
        Right chosen -> pure (Map.lookup RoleState chosen)
        Left (ReferenceMissing _ _) -> pure Nothing
        Left refusal ->
            failWith NodeUnavailable (T.unpack (renderReferenceRefusal refusal))

-- | The scripts published after the boot, by role, as the registry runs them.
laterScripts
    :: CageConfig -> NamingCodes -> TokenId -> [(Text, Script ConwayEra)]
laterScripts cfg pinned tid =
    [ ("request", mkRequestScript cfg tid)
    , ("witness-absent", witnessScriptOf cfg pinned 0)
    , ("witness-active", witnessScriptOf cfg pinned 1)
    , ("witness-terminal", witnessScriptOf cfg pinned 2)
    , ("application", scriptFromBytes "open-datum" (ncApplication pinned))
    ]

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

boot
    :: WriteContext
    -> CageConfig
    -> NamingCodes
    -> TxIn
    -> Maybe (TxIn, TxOut ConwayEra)
    -- ^ A live carrier of the state script, if one was found
    -> IO Booted
boot wc cfg pinned seedIn foundState = do
    let addr = walletAddr (wcWallet wc)
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
        stateScript = scriptFromBytes "state" (cageScriptBytes cfg)
    -- The state validator, published from outside the seed, unless a live
    -- carrier of it was found.
    stateRef@(stateIn, _) <-
        maybe
            (publish "publish-state" (Set.singleton seedIn) stateScript)
            pure
            foundState
    -- A carrier found elsewhere was not submitted by this create.
    let stateTxs = [txInTxId stateIn | null foundState]
    observeReference wc "publish-state" stateScript stateRef
    -- The boot, consuming the seed and running the state script from the
    -- reference, wherever it sits.
    (signedBoot, ()) <-
        submitBuiltIn
            wc
            "boot"
            []
            (const (expecting "state"))
            ( \building v -> do
                place building [InEdge Booting] (EdgeStarted Booting)
                (,()) <$> bootTokenFrom cfg stateRef v addr
            )
    tid <- case signedBoot ^. bodyTxL . mintTxBodyL of
        MultiAsset m -> case Map.lookup (cagePolicyIdFromCfg cfg) m of
            Just names | [(name, 1)] <- Map.toList names -> pure (TokenId name)
            _ -> failWith LedgerRefusal "the boot minted no single registry token"
    stateUtxos <-
        readStep
            (wcTracer wc)
            (wcSource wc)
            ["state"]
            (wcCapabilities wc)
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
            report
                (wcTracer wc)
                [InEdge Booting]
                (Created (tokenHex tid) (txInText output))
            report
                (wcTracer wc)
                [InRegistry (tokenHex tid)]
                ( RegistrySeen
                    (txInText output)
                    (hexT (unOnChainRoot (stateRoot state)))
                    (Just 0)
                )
            pure (output, state)
    -- The references the registry's later commands find by hash.
    published <-
        mapM
            ( \(role, script) -> do
                ref <- publish ("publish-" <> role) Set.empty script
                observeReference wc ("publish-" <> role) script ref
                pure (reference role script ref)
            )
            (laterScripts cfg pinned tid)
    pure
        Booted
            { bootedToken = tid
            , bootedBody = signedBoot
            , bootedOutput = seenOutput
            , bootedRoot = unOnChainRoot (stateRoot seenState)
            , bootedState = seenState
            , bootedBoot = txIdHex signedBoot
            , bootedRefs = reference "state" stateScript stateRef : published
            , bootedTxs =
                stateTxs
                    <> [txIdHex signedBoot]
                    <> map (txIdOfRef . refOutRef) published
            }
  where
    txInTxId = T.takeWhile (/= '#') . txInText
    txIdOfRef = T.takeWhile (/= '#')

{- | Read a reference back — the exact output, live, carrying exactly this
script — and only then journal it @observed@. A read the provider
refused — a backend failure, a released view, a missing output — is
attributed as the typed failure the client holds: thrown inside the timed
step, so the step ends failed and no absence is claimed from a read that
was not made (#416). A read that answered — with the output, another
script, or nothing — is a fact; a missing or different reference leaves
the publication at @confirmed@, unresolved.
-}
observeReference
    :: WriteContext
    -> Text
    -> Script ConwayEra
    -> (TxIn, TxOut ConwayEra)
    -> IO ()
observeReference wc step script (i, _) = do
    found <-
        readStep
            (wcTracer wc)
            (wcSource wc)
            ["reference scripts"]
            (wcCapabilities wc)
            ( \v ->
                LP.outputs v (LP.AtTxIn i)
                    >>= either throwIO (pure . map snd . value)
            )
    let wanted = hashScript script
    case found of
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
                    <> ": the reference output "
                    <> T.unpack (txInText i)
                    <> " is not live"
                )

-- | A reference as the receipt names it: its role, script and place.
reference
    :: Text
    -> Script ConwayEra
    -> (TxIn, TxOut ConwayEra)
    -> ReferenceScript
reference role script (i, o) =
    ReferenceScript
        { refRole = role
        , refHash = hexT (scriptHashBytes (hashScript script))
        , refOutRef = txInText i
        , refAddress = T.pack (bech32Address (o ^. addrTxOutL))
        , refAddressBytes = renderAddrBytes (o ^. addrTxOutL)
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
            , ("stateToken", toJSON (renderStateToken (stateTokenOf rel seedIn)))
            , ("seed", toJSON (txInText seedIn))
            , ("wallet", toJSON (T.pack (bech32Address addr)))
            , ("walletKeyHash", toJSON (hexT (addrKeyHashBytes addr)))
            , ("pins", toJSON (pinsOf cfg))
            ]
                <> funding
    pure ((seedIn, cfg, pinned), identity)
