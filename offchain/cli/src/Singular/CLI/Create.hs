{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

{- |
Module      : Singular.CLI.Create
Description : @singular registry create@: boot a registry from the caller's seed
License     : Apache-2.0

The seed decides the registry's identity — its state token name, and so
the application applied to that identity and the three witness
policies — so every pin is derived before anything is submitted, and
@--preview@ stops there, submitting nothing and writing nothing. When a
live carrier of the state validator exists, the seed is the wallet's
largest ada-only output, as before; otherwise it is the first
publication's change, computed from the body before submission, so preview
and create name the same token from one wallet view.

Otherwise, before anything is submitted, a live carrier of the state
validator is looked for by its hash (the provider, then the wallet) and the
wallet is checked to fund every publication still to make.
Then, in order, each submission journalled and each result read back before
the next: the state validator is published first when no carrier was found
(its change is the seed) and from outside the seed when one was found (the
seed survives the publication); the boot consumes
the seed and creates the state output at the empty root, running the state
validator from that reference; the request validator, the three witness
policies and the applied application are published as reference outputs to
the creator's wallet. The receipt names the state token, which is the
registry: no identity file is written, and the pending identity recorded
for an interrupted create is removed once it finishes. An explicit seed
already names its managed partition, so a real create meets the
existing-state refusal before any chain read and before seed validation; a
provider it cannot use is never contacted. An automatically selected seed
still needs one view of the wallet's outputs first, so a provider failure
during selection is reported as node-unavailable and the existing-state
refusal happens under the target's lock, after selection and before any
submission. A preview never refuses for existing state: it only reads,
submitting nothing and writing nothing.
-}
module Singular.CLI.Create (createApplication, runCreate, stateTokenOf) where

import Control.Exception
    ( ErrorCall (..)
    , SomeAsyncException
    , SomeException
    , fromException
    , throwIO
    , try
    )
import Control.Monad (unless, when)
import Data.Aeson (Value, toJSON)
import Data.Aeson qualified as Aeson
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.Aeson.Key qualified as Key
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing)
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
    , mkBasicTxOut
    , referenceScriptTxOutL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..), TxIx (..))
import Cardano.Ledger.Core (PParams, Script, hashScript)
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)

import Singular.CLI.Command
    ( ApplicationPolicy (..)
    , CreateArgs (..)
    , EntryMode (..)
    , ProviderSettings (..)
    , WriteSettings (..)
    )
import Singular.CLI.FlagGroup (Signer (..))
import Singular.CLI.Live (receipt, txInText)
import Singular.CLI.ManagedState
    ( addressPartition
    , managedDir
    , resolveStateRoot
    )
import Singular.CLI.Receipt
    ( OutcomeClass (..)
    , durableWrite
    , readJournal
    , unjudgedMembers
    )
import Singular.CLI.Reconcile (reconcileBundles, refusePendingBundle)
import Singular.CLI.Registry
    ( IdentityError (..)
    , Release (..)
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
    , seedHeld
    , selectSeed
    )
import Singular.CLI.Session
    ( Building (..)
    , CommandFailure (..)
    , ConfirmedSubmission
    , Env (..)
    , WriteContext (..)
    , confirmedTx
    , confirmedTxId
    , expecting
    , failWith
    , journalObserved
    , journalObservedId
    , loadSignerWallet
    , readOnce
    , readStep
    , refuseTakenBundle
    , submitBuilt
    , submitBuiltIn
    , withSession
    , withTargetLockOr
    , withWrite
    )
import Singular.CLI.Trace
    ( EdgeAction (..)
    , Scope (..)
    , What (Created, EdgeStarted, RegistrySeen)
    , report
    )
import Singular.Registry.Application
    ( Application (..)
    , ApplicationPin (..)
    , appPin
    , hashPinnedApplication
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
    , renderOutRef
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
    ( PublicationFundingError (..)
    , adaOnlyOut
    , firstPublicationChange
    , publicationFee
    , publicationMinChange
    , publicationRefCoin
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
import Singular.Registry.Wallet (bech32Address)

{- | The application a @registry create@ runs with: the hash the flag pins
through 'hashPinnedApplication', or the composed value. A neutral value
without the flag, and a flag on a value that already fixes its pin, are
refused by name before anything is built or signed.
-}
createApplication
    :: Application -> Maybe ApplicationPolicy -> IO Application
createApplication app policy = case (appPin app, policy) of
    (PinFromState, Just (ApplicationPolicy hashed)) ->
        pure (hashPinnedApplication hashed)
    (PinFromState, Nothing) -> failWith ClientRefusal needsApplicationPolicy
    (_, Just _) -> failWith ClientRefusal applicationPolicyNotAccepted
    (_, Nothing) -> pure app

-- | Why a create without the flag is refused on a neutral value.
needsApplicationPolicy :: String
needsApplicationPolicy =
    "registry create needs --application-policy HEX: this application reads its pin from the state datum of a registry that does not exist yet, so give the 28-byte policy hash in hex (56 characters) to pin"

-- | Why the flag is refused on a value that already fixes its pin.
applicationPolicyNotAccepted :: String
applicationPolicyNotAccepted =
    "--application-policy is not accepted here: the application value already fixes its pin, so the pin comes from the application value"

runCreate :: Application -> Env -> CreateArgs -> IO Value
runCreate app env a = do
    -- An external signer's bundle path is judged first: an existing one is
    -- refused before the blueprint, the wallet or the state root is read.
    case createMode a of
        Submit WriteSettings{writeSigner = SignerExternal _ bundle} ->
            refuseTakenBundle bundle
        _ -> pure ()
    -- A direct caller composing the neutral value meets the same refusal
    -- as the dispatch: at boot no state datum exists to read a pin from.
    case appPin app of
        PinFromState -> failWith ClientRefusal needsApplicationPolicy
        _ -> pure ()
    rel <-
        envLoadRelease env app (createBlueprint a)
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
                pp <- Cage.parameters v
                mustPub <- mustPublishState v addr rel
                ((seedIn, cfg, pinned, _seedFrom), identity) <-
                    previewIdentity app False a rel addr utxos pp mustPub
                scope <- sessionReceipt caps v
                judged <- case lookup "createRefusal" identity of
                    Just Aeson.Null -> do
                        foundState <-
                            if mustPub then pure Nothing else stateReference app v addr rel seedIn
                        let stateScript = scriptFromBytes "state" (cageScriptBytes cfg)
                            beforeBoot = case foundState of
                                Just _ -> []
                                Nothing -> [("state", stateScript)]
                            token = stateTokenOf rel seedIn
                            carrier =
                                fromMaybe
                                    ( seedIn
                                    , mkBasicTxOut addr (MaryValue (Coin 0) mempty)
                                        & referenceScriptTxOutL .~ SJust stateScript
                                    )
                                    foundState
                        pure $ case publicationFunding
                            pp
                            seedIn
                            (bootCostBound pp carrier)
                            beforeBoot
                            (laterScripts cfg pinned (TokenId (snd token)))
                            utxos of
                            Left err -> Just (T.pack (renderIdentityError err))
                            Right _ -> Nothing
                    _ -> pure Nothing
                let identity' = case judged of
                        Nothing -> identity
                        Just refusal ->
                            ("createRefusal", toJSON refusal)
                                : filter ((/= "createRefusal") . fst) identity
                pure $
                    receipt
                        "create"
                        Success
                        ( [("preview", toJSON True), ("sessionEvidence", scope)]
                            <> identity'
                        )
        Submit ws -> createWith app env a rel ws

{- | Run the pre-lock selection read, reporting a provider it cannot use as
node-unavailable with the session's own wording. A failure the command
itself classified, and any asynchronous failure, propagates unchanged.
-}
catchSelection :: IO a -> ProviderSettings -> IO a
catchSelection act settings = do
    result <- try act
    case result of
        Right x -> pure x
        Left (e :: SomeException) -> case fromException e of
            Just (_ :: CommandFailure) -> throwIO e
            Nothing -> case fromException e of
                Just (_ :: SomeAsyncException) -> throwIO e
                Nothing ->
                    failWith
                        NodeUnavailable
                        ( "the provider at "
                            <> providerUrl settings
                            <> " could not be used: "
                            <> show e
                        )

{- | A staged create still waiting for its signatures stops another create
of the same registry before any existing-state check, whichever signer
this one uses: the same wallet and seed derive the same token and
directory, and the first bundle must land or die before anything else is
built there. A journal with no member left to judge reads nothing from the
chain, and the existing-state check then behaves as before; so does a
journal that does not decode, which holds no bundle admission can read and
which that check refuses.
-}
admitBeforeExisting :: Env -> ProviderSettings -> FilePath -> IO ()
admitBeforeExisting env settings dir = do
    journalled <-
        either (\(ErrorCall _) -> []) id <$> try (readJournal dir)
    unless (null (unjudgedMembers journalled)) $ do
        (_, waiting) <-
            readOnce env settings ["chain tip", "journal transactions"] $ \_ v ->
                withTargetLockOr
                    dir
                    (reconcileBundles "create" dir v)
                    (pure ([], []))
        mapM_ (`refusePendingBundle` []) (take 1 waiting)

createWith
    :: Application
    -> Env
    -> CreateArgs
    -> Release
    -> WriteSettings
    -> IO Value
createWith app env a rel ws = do
    let magic = providerMagic (writeProvider ws)
    -- The caller's address names the partition for either signer: a key
    -- file's payment key hash is its address's.
    (callerAddr, _) <- loadSignerWallet magic (writeSigner ws)
    root <- resolveStateRoot (createStateDir a)
    let addr = callerAddr
        settings = writeProvider ws
    -- An explicit seed already names its managed partition before any chain
    -- read: a real create with existing state there refuses before seed
    -- validation, so a second boot of one seed is refused for the existing
    -- state however far chain inclusion has progressed. A preview never
    -- refuses for existing state: it still only reads. An automatically
    -- selected seed still needs its wallet view first and is checked after
    -- selection below.
    case createSeed a of
        Just s | not (createPreview a) -> do
            named <- either (failWith ClientRefusal) pure (parseOutRef (T.pack s))
            let namedDir =
                    managedDir
                        root
                        magic
                        (stateTokenOf rel named)
                        (addressPartition callerAddr)
            admitBeforeExisting env settings namedDir
            refuseExisting namedDir
                >>= either (failWith ClientRefusal . renderIdentityError) pure
        _ -> pure ()
    -- The seed is selected before any lock or journal use, from one view
    -- of the wallet's outputs. An automatically selected seed is validated,
    -- never re-selected, under the lock, so the managed journal always binds
    -- the state token this command creates: a seed spent in between refuses
    -- instead of silently booting another registry. A provider the selection
    -- read cannot use is reported as node-unavailable, as a session
    -- established for a write would report it, never as a client refusal.
    (utxos, ppPre, mustPubPre, scope) <-
        readOnce
            env
            settings
            ["wallet outputs"]
            ( \caps v -> do
                outputs <- Cage.outputsAt v addr
                pp <- Cage.parameters v
                mustPub <- mustPublishState v addr rel
                evidence <- sessionReceipt caps v
                pure (outputs, pp, mustPub, evidence)
            )
            `catchSelection` settings
    ((seedIn, cfg, pinned, seedFromPre), identity) <-
        previewIdentity
            app
            (not (createPreview a))
            a
            rel
            addr
            utxos
            ppPre
            mustPubPre
    let token = stateTokenOf rel seedIn
        dir = managedDir root magic token (addressPartition callerAddr)
    -- A preview writes nothing: no lock, no directory, no journal.
    if createPreview a
        then withSession env dir "create" ws $ \wc -> do
            judged <- case lookup "createRefusal" identity of
                Just Aeson.Null -> do
                    (foundState, pp) <-
                        readStep
                            (wcTracer wc)
                            (wcSource wc)
                            ["reference scripts"]
                            (wcCapabilities wc)
                            $ \v -> do
                                found <- stateReference app v addr rel seedIn
                                (found,) <$> Cage.parameters v
                    let stateScript = scriptFromBytes "state" (cageScriptBytes cfg)
                        beforeBoot = case foundState of
                            Just _ -> []
                            Nothing -> [("state", stateScript)]
                        carrier =
                            fromMaybe
                                ( seedIn
                                , mkBasicTxOut addr (MaryValue (Coin 0) mempty)
                                    & referenceScriptTxOutL .~ SJust stateScript
                                )
                                foundState
                    pure $ case publicationFunding
                        pp
                        seedIn
                        (bootCostBound pp carrier)
                        beforeBoot
                        (laterScripts cfg pinned (TokenId (snd token)))
                        utxos of
                        Left err -> Just (T.pack (renderIdentityError err))
                        Right _ -> Nothing
                _ -> pure Nothing
            let identity' = case judged of
                    Nothing -> identity
                    Just refusal ->
                        ("createRefusal", toJSON refusal)
                            : filter ((/= "createRefusal") . fst) identity
            pure $
                receipt
                    "create"
                    Success
                    ( [("preview", toJSON True), ("sessionEvidence", scope)]
                        <> identity'
                    )
        else do
            admitBeforeExisting env settings dir
            refuseExisting dir
                >>= either (failWith ClientRefusal . renderIdentityError) pure
            withWrite env dir "create" ws $ \wc -> do
                -- The existence check again, now under the target's lock: a
                -- create that passed it before another create finished
                -- must not boot a second registry over the first. It runs
                -- before the seed is revalidated, so a concurrent double
                -- boot of one seed is refused for the existing state,
                -- not for the seed the winner just spent.
                refuseExisting dir
                    >>= either (failWith ClientRefusal . renderIdentityError) pure
                let addrUnder = wcCaller wc
                    stateScriptPre = scriptFromBytes "state" (releaseState rel)
                (freshUtxos, ppFreshPre, mustPubFresh) <-
                    readStep
                        (wcTracer wc)
                        (wcSource wc)
                        ["wallet outputs"]
                        (wcCapabilities wc)
                        ( \v -> do
                            outputs <- Cage.outputsAt v addrUnder
                            pp <- Cage.parameters v
                            mustPub <- mustPublishState v addrUnder rel
                            pure (outputs, pp, mustPub)
                        )
                -- The pin: a chained identity names its body before the lock;
                -- the wallet again must build the same body, or the create is
                -- refused before anything is written, like today's seed-spent
                -- refusal. An output identity still needs its seed held.
                _ <-
                    if seedFromPre == "publication-change"
                        then do
                            when (mustPubFresh /= mustPubPre) $
                                failWith
                                    ClientRefusal
                                    ( renderIdentityError
                                        ( WalletChangedSinceNamed
                                            (txInText seedIn)
                                            ( if mustPubFresh
                                                then "no live carrier"
                                                else "a live carrier now exists"
                                            )
                                        )
                                    )
                            freshChained <- case firstPublicationChange ppFreshPre addrUnder stateScriptPre freshUtxos of
                                Right (freshSeed, _, _, _, _) -> pure (Just freshSeed)
                                Left _ -> pure Nothing
                            case freshChained of
                                Just freshSeed | freshSeed == seedIn -> pure []
                                Just freshSeed ->
                                    failWith
                                        ClientRefusal
                                        ( renderIdentityError
                                            (WalletChangedSinceNamed (txInText seedIn) (txInText freshSeed))
                                        )
                                Nothing ->
                                    failWith
                                        ClientRefusal
                                        ( renderIdentityError
                                            ( WalletChangedSinceNamed
                                                (txInText seedIn)
                                                "the wallet no longer funds its first publication"
                                            )
                                        )
                        else do
                            when (mustPubFresh /= mustPubPre) $
                                failWith
                                    ClientRefusal
                                    ( renderIdentityError
                                        ( WalletChangedSinceNamed
                                            (txInText seedIn)
                                            ( if mustPubFresh
                                                then "no live carrier"
                                                else "a live carrier now exists"
                                            )
                                        )
                                    )
                            _ <-
                                either
                                    (failWith ClientRefusal . renderIdentityError)
                                    pure
                                    (seedChecks True seedIn freshUtxos)
                            -- A held sole output while the state must be published
                            -- names omit---seed, never a second output.
                            case seedHeld seedIn freshUtxos of
                                Right _
                                    | null [() | (i, o) <- freshUtxos, i /= seedIn, adaOnlyOut o]
                                    , mustPubFresh ->
                                        failWith
                                            ClientRefusal
                                            (renderIdentityError (SoleSeedWhilePublishing (renderOutRef seedIn)))
                                _ -> pure []
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
                            found <- stateReference app v addrUnder rel seedIn
                            (found,) <$> Cage.parameters v
                let stateScript = scriptFromBytes "state" (cageScriptBytes cfg)
                    beforeBoot = case foundState of
                        Just _ -> []
                        Nothing -> [("state", stateScript)]
                    -- The boot references a carrier of this script, found
                    -- or about to be published; its size prices the boot.
                    carrier =
                        fromMaybe
                            ( seedIn
                            , mkBasicTxOut addrUnder (MaryValue (Coin 0) mempty)
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
                        freshUtxos
                    )
                createDirectoryIfMissing True dir
                -- The pending identity, durable before the first submission:
                -- an interrupted create stays inspectable with its own token
                -- and is refused a second boot.
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
                booted <-
                    boot
                        wc
                        cfg
                        pinned
                        seedIn
                        foundState
                        (seedFromPre == "publication-change")
                        (pendingPath dir)
                -- The registry is its token: nothing of it stays on disk. A
                -- staged create has landed nothing yet, so its pending
                -- identity stays recorded until the bundle's own state
                -- settles it.
                unless (isJust (wcStaged wc)) $ removeFile (pendingPath dir)
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
    :: Application
    -> LP.Session NoWitness IO
    -> Addr
    -- ^ The creator's wallet
    -> Release
    -> TxIn
    -> IO (Maybe (TxIn, TxOut ConwayEra))
stateReference app v wallet rel seedIn = do
    found <-
        findReferences
            v
            (Just wallet)
            ( expectedReferences
                (appPin app)
                rel
                (stateTokenOf rel seedIn)
            )
            (Set.singleton RoleState)
    case found of
        Right chosen -> pure (Map.lookup RoleState chosen)
        Left (ReferenceMissing _ _) -> pure Nothing
        Left refusal ->
            failWith NodeUnavailable (T.unpack (renderReferenceRefusal refusal))

{- | Whether the state script must be published (#406 slice 2): no live
carrier of it by hash through the provider, then the wallet. The state
hash is seed-independent, so this decides the seed rule before any seed
exists.
-}
mustPublishState
    :: LP.Session NoWitness IO
    -> Addr
    -> Release
    -> IO Bool
mustPublishState v wallet rel = do
    let stateHash = computeScriptHash (releaseState rel)
        expected = Map.singleton RoleState stateHash
    found <-
        findReferences v (Just wallet) expected (Set.singleton RoleState)
    case found of
        Right chosen -> pure (Map.notMember RoleState chosen)
        Left (ReferenceMissing _ _) -> pure True
        Left refusal ->
            failWith NodeUnavailable (T.unpack (renderReferenceRefusal refusal))

{- | The scripts published after the boot, by role, as the registry runs them.
A hash pin publishes none for the application (slice 2: its script bytes
do not exist); a script pin publishes it as today.
-}
laterScripts
    :: CageConfig -> NamingCodes -> TokenId -> [(Text, Script ConwayEra)]
laterScripts cfg pinned tid =
    [ ("request", mkRequestScript cfg tid)
    , ("witness-absent", witnessScriptOf cfg pinned 0)
    , ("witness-active", witnessScriptOf cfg pinned 1)
    , ("witness-terminal", witnessScriptOf cfg pinned 2)
    ]
        <> [ ("application", scriptFromBytes "application" (ncApplication pinned))
           | not (SBS.null (ncApplication pinned))
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
    -- ^ The named seed: held (output) or the first publication's change
    -> Maybe (TxIn, TxOut ConwayEra)
    -- ^ A live carrier of the state script, if one was found
    -> Bool
    -- ^ Whether the seed is chained (the first publication's change)
    -> FilePath
    {- ^ The pending file, removed when the first publication is refused
    before anything is submitted (nothing may stay behind)
    -}
    -> IO Booted
boot wc cfg pinned seedIn foundState isChained pendingFile = do
    let addr = wcCaller wc
        -- One transaction, built from one view, journalled with its point.
        -- A first-publication refusal happens before any submission, so the
        -- pending file just written is removed and nothing stays behind.
        publishFirst step reserved script = do
            result <- try (publish step reserved script)
            case result of
                Right ok -> pure ok
                Left (e :: SomeException) -> do
                    _ <- try (removeFile pendingFile) :: IO (Either SomeException ())
                    throwIO e
        publish step reserved script = do
            (confirmed, refOut) <-
                submitBuilt
                    wc
                    step
                    ( const
                        (expecting ("reference:" <> hexT (scriptHashBytes (hashScript script))))
                    )
                    (\v -> publishRefScriptTx reserved v addr script)
            pure
                (confirmed, TxIn (txIdTx (confirmedTx confirmed)) (TxIx 0), refOut)
        -- The chained first publication, built once inside the submission
        -- step: the pure function computes it from the fresh view, its id
        -- must equal the named one, and only then is that very value
        -- submitted. A different id or a shortfall is a client-refusal with
        -- typed text, never `error`; no second construction remains.
        publishChainedState step script namedSeed = do
            result <-
                try $
                    submitBuilt
                        wc
                        step
                        ( const
                            (expecting ("reference:" <> hexT (scriptHashBytes (hashScript script))))
                        )
                        ( \v -> do
                            pp <- Cage.parameters v
                            utxos <- Cage.outputsAt v addr
                            case firstPublicationChange pp addr script utxos of
                                Left (PublicationShortfall{}) ->
                                    failWith
                                        ClientRefusal
                                        ( renderIdentityError
                                            ( WalletChangedSinceNamed
                                                (txInText namedSeed)
                                                "the wallet no longer funds its first publication"
                                            )
                                        )
                                Left (PublicationOversize size limit) ->
                                    failWith
                                        ClientRefusal
                                        (renderIdentityError (PublicationTooLarge "state" size limit))
                                Right (freshSeed, tx, refOut, _, _) ->
                                    if freshSeed == namedSeed
                                        then pure (tx, refOut)
                                        else
                                            failWith
                                                ClientRefusal
                                                ( renderIdentityError
                                                    (WalletChangedSinceNamed (txInText namedSeed) (txInText freshSeed))
                                                )
                        )
            case result of
                Right (confirmed, refOut) ->
                    pure
                        ( Just confirmed
                        , (TxIn (txIdTx (confirmedTx confirmed)) (TxIx 0), refOut)
                        )
                Left (e :: SomeException) -> do
                    _ <- try (removeFile pendingFile) :: IO (Either SomeException ())
                    throwIO e
        stateScript = scriptFromBytes "state" (cageScriptBytes cfg)
    -- The state validator, published from outside the seed, unless a live
    -- carrier of it was found. A found carrier has no current-command
    -- confirmed result; the Maybe below keeps the two paths explicit.
    (stateConfirmed, stateRef@(stateIn, _)) <-
        case foundState of
            Nothing ->
                if isChained
                    then publishChainedState "publish-state" stateScript seedIn
                    else do
                        (confirmed, i, o) <-
                            publishFirst "publish-state" (Set.singleton seedIn) stateScript
                        pure (Just confirmed, (i, o))
            Just found -> pure (Nothing, found)
    -- A carrier found elsewhere was not submitted by this create.
    let stateTxs = [txInTxId stateIn | null foundState]
    observeReference
        wc
        "publish-state"
        stateScript
        stateConfirmed
        stateRef
    -- The boot, consuming the seed and running the state script from the
    -- reference, wherever it sits.
    (confirmedBoot, ()) <-
        submitBuiltIn
            wc
            "boot"
            []
            (const (expecting "state"))
            ( \building v -> do
                place building [InEdge Booting] (EdgeStarted Booting)
                (,()) <$> bootTokenFrom cfg stateRef v addr
            )
    let signedBoot = confirmedTx confirmedBoot
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
                confirmedBoot
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
                (confirmed, i, o) <- publish ("publish-" <> role) Set.empty script
                observeReference
                    wc
                    ("publish-" <> role)
                    script
                    (Just confirmed)
                    (i, o)
                pure (reference role script (i, o))
            )
            (laterScripts cfg pinned tid)
    pure
        Booted
            { bootedToken = tid
            , bootedBody = signedBoot
            , bootedOutput = seenOutput
            , bootedRoot = unOnChainRoot (stateRoot seenState)
            , bootedState = seenState
            , bootedBoot = confirmedTxId confirmedBoot
            , bootedRefs = reference "state" stateScript stateRef : published
            , bootedTxs =
                stateTxs
                    <> [confirmedTxId confirmedBoot]
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

The fourth argument keeps the two reference paths explicit: 'Just' a
confirmed value this command published (journalled with its own timer and
scopes — never the zero/default path), 'Nothing' an already-live reference
found before this command (journalled by its original id, zero elapsed,
empty scopes, excluded from submitted transactions, with no signing,
preparation, submission or confirmation on reuse).
-}
observeReference
    :: WriteContext
    -> Text
    -> Script ConwayEra
    -> Maybe ConfirmedSubmission
    -> (TxIn, TxOut ConwayEra)
    -> IO ()
observeReference wc step script published (i, _) = do
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
        detail =
            "reference output "
                <> txInText i
                <> " is live carrying script "
                <> hexT (scriptHashBytes wanted)
        original = T.takeWhile (/= '#') (txInText i)
    case found of
        [o]
            | SJust carried <- o ^. referenceScriptTxOutL
            , hashScript carried == wanted -> case published of
                Just confirmed -> journalObserved wc step confirmed detail
                Nothing -> journalObservedId wc step original detail
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

{- | The application a receipt names, from the pin: the blueprint validator
title for a script or compiled pin, the policy hex for a hash pin (slice 2:
its script bytes do not exist, so no title exists to name).
-}
pinApplicationName :: ApplicationPin -> Text
pinApplicationName pin = case pin of
    PinByScript title -> title
    PinAsCompiled title -> title
    PinByHash policy -> hexT (SBS.fromShort policy)
    PinFromState -> "from-state"

{- | The registry identity a seed would give (#406 slice 2): either the
wallet's largest ada-only output (a live state carrier exists, so no
publication comes first) or the first publication's change (the state
script must be published, so the seed is the change output of that
publication, computed from the body before submission). An explicit
@--seed@ names a held output, or the previewed chained seed to pin the
identity; any other unheld seed is refused. A held sole output while the
state must be published is refused with omit-@--seed@ remedy. The receipt
carries @seedFrom@ (@output@ or @publication-change@). Nothing is written
or submitted.
-}
previewIdentity
    :: Application
    -> Bool
    -- ^ whether the identity is for a create about to submit
    -> CreateArgs
    -> Release
    -> Addr
    -> [(TxIn, TxOut ConwayEra)]
    -> PParams ConwayEra
    -> Bool
    -- ^ whether the state script must be published (no live carrier)
    -> IO ((TxIn, CageConfig, NamingCodes, Text), [(Text, Value)])
previewIdentity app submitting a rel addr utxos pp mustPublish = do
    let stateScript = scriptFromBytes "state" (releaseState rel)
        adaOnlyHeld = [u | u@(_, o) <- utxos, adaOnlyOut o]
        -- A shortfall at the first publication (auto chained, no carrier)
        -- names no seed. Preview (both modes) succeeds with `createRefusal`
        -- carrying the whole-run refusal and null seed fields, without
        -- calling the funding judgement; create fails with client-refusal
        -- and the same text before anything is written. The whole-run figure
        -- uses a dummy largest-held identity (applied params are
        -- fixed-length, so script sizes and the figure are exact).
        -- `SoleSeedWhilePublishing` is only for an explicit `--seed`.
        wholeRunText err = case (err, adaOnlyHeld) of
            (PublicationUnfunded _ needed (largest, held, _), (dummy, _) : _) ->
                let chosenDummy =
                        economics
                            { reProcessTime = createProcessTime a
                            , reRetractTime = createRetractTime a
                            }
                    (cfgDummy, pinnedDummy) =
                        registryConfigFor app rel chosenDummy (txInToRef dummy)
                    tokenDummy = stateTokenOf rel dummy
                    laterDummy = laterScripts cfgDummy pinnedDummy (TokenId (snd tokenDummy))
                    dummyCarrier =
                        ( dummy
                        , mkBasicTxOut addr (MaryValue (Coin 0) mempty)
                            & referenceScriptTxOutL .~ SJust stateScript
                        )
                    bootCostDummy = bootCostBound pp dummyCarrier
                    refCoinsDummy =
                        [ publicationRefCoin pp addr script
                        | (_, script) <- ("state", stateScript) : laterDummy
                        ]
                    runNeedDummy =
                        sum refCoinsDummy
                            + fromIntegral (1 + length laterDummy) * publicationFee
                            + bootCostDummy
                            + publicationMinChange
                in  renderIdentityError
                        (PublicationUnfunded "state" needed (largest, held, runNeedDummy))
            _ -> renderIdentityError err
        firstMarker = case adaOnlyHeld of
            ((dummy, _) : _) -> (dummy, "output-first-failure")
            [] -> error "previewIdentity: empty wallet reached first failure"
    explicit <- case createSeed a of
        Just s ->
            Just <$> either (failWith ClientRefusal) pure (parseOutRef (T.pack s))
        Nothing -> pure Nothing
    when (isNothing explicit && null adaOnlyHeld) $
        failWith
            ClientRefusal
            "the wallet holds no ada-only output to preview a seed with"
    (seedIn, seedFrom) <- case selectSeed explicit utxos pp stateScript addr mustPublish submitting of
        Right chosen -> pure chosen
        Left (SeedNotInWallet "no ada-only output") ->
            failWith
                ClientRefusal
                "the wallet holds no ada-only output to preview a seed with"
        Left err@(PublicationUnfunded "state" _ _)
            | isNothing explicit && mustPublish ->
                if submitting
                    then failWith ClientRefusal (wholeRunText err)
                    else pure firstMarker
        Left err@(PublicationTooLarge "state" _ _)
            | isNothing explicit && mustPublish ->
                if submitting
                    then failWith ClientRefusal (wholeRunText err)
                    else pure firstMarker
        Left err -> failWith ClientRefusal (renderIdentityError err)
    let isChained = seedFrom == "publication-change"
        isFirstFailure = seedFrom == "output-first-failure"
        soleHeld = case seedHeld seedIn utxos of
            Right _ -> null [() | (i, o) <- utxos, i /= seedIn, adaOnlyOut o]
            Left _ -> False
        omitNow = soleHeld && mustPublish && seedFrom == "output"
        firstRefusalText = case selectSeed explicit utxos pp stateScript addr mustPublish submitting of
            Left err -> wholeRunText err
            Right _ ->
                error
                    "previewIdentity: first-failure marker without selection refusal"
    funding <-
        if isFirstFailure
            then pure [("createRefusal", toJSON (T.pack firstRefusalText))]
            else
                if isChained
                    then
                        pure
                            [("createRefusal", toJSON (Nothing :: Maybe Text)) | not submitting]
                    else
                        if omitNow && not submitting
                            then
                                pure
                                    [
                                        ( "createRefusal"
                                        , toJSON
                                            ( T.pack
                                                (renderIdentityError (SoleSeedWhilePublishing (renderOutRef seedIn)))
                                            )
                                        )
                                    ]
                            else
                                either
                                    (failWith ClientRefusal . renderIdentityError)
                                    pure
                                    (seedChecks submitting seedIn utxos)
    let chosen =
            economics
                { reProcessTime = createProcessTime a
                , reRetractTime = createRetractTime a
                }
        (cfg, pinned) =
            registryConfigFor app rel chosen (txInToRef seedIn)
        providerFromCreate = case createMode a of
            Submit settings -> writeProvider settings
            Preview settings _ -> settings
        quotedForShell word =
            if not (null word) && all (`elem` safeChars) word
                then word
                else "'" <> concatMap escapeTick word <> "'"
          where
            safeChars = ['a' .. 'z'] <> ['A' .. 'Z'] <> ['0' .. '9'] <> "_@%+=:,./-"
            escapeTick '\'' = "'\\''"
            escapeTick letter = [letter]
        describeParts =
            [ "singular"
            , "registry"
            , "describe"
            , "--blueprint"
            , createBlueprint a
            , "--state-token"
            , T.unpack (renderStateToken (stateTokenOf rel seedIn))
            , "--koios-url"
            , providerUrl providerFromCreate
            , "--network-magic"
            , show (providerMagic providerFromCreate)
            ]
                <> case providerTimeDirectory providerFromCreate of
                    Nothing -> []
                    Just dir -> ["--network-time", dir]
        describeLine = T.pack (unwords (map quotedForShell describeParts))
        identity =
            [ ("application", toJSON (pinApplicationName (appPin app)))
            ,
                ( "stateToken"
                , if isFirstFailure
                    then toJSON Aeson.Null
                    else toJSON (renderStateToken (stateTokenOf rel seedIn))
                )
            ,
                ( "describeCommand"
                , if isFirstFailure
                    then toJSON Aeson.Null
                    else toJSON describeLine
                )
            ,
                ( "seed"
                , if isFirstFailure then toJSON Aeson.Null else toJSON (txInText seedIn)
                )
            ,
                ( "seedFrom"
                , if isFirstFailure then toJSON Aeson.Null else toJSON seedFrom
                )
            , ("wallet", toJSON (T.pack (bech32Address addr)))
            , ("walletKeyHash", toJSON (hexT (addrKeyHashBytes addr)))
            ]
                <> ([("pins", toJSON (pinsOf cfg)) | not isFirstFailure])
                <> funding
    pure ((seedIn, cfg, pinned, seedFrom), identity)
