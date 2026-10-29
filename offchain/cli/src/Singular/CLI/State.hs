{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.State
Description : Create the registry of an application, and fold its pending registrations, with the library's builders
License     : Apache-2.0

The commands that make a registry on the proved design and fold what is booked
in it. They are written once, against the library's builders, and a program
hosts them by handing over what it knows of its application: the policy of the
application and the validators it owns, the steps it adds to the creation of a
registry, and the pending registrations it lets a fold spend. The neutral
@singular@ program knows no application beyond the policy it is given; open datum
knows its request validator.

@create@ publishes the state validator, and the validators the application
owns, as reference scripts when no live copy of them exists, each in a transaction
of its own; a later registry finds the live copies and sends one transaction. The
transaction that creates the registry spends the seed.

@fold@ builds, from the chain alone, the transaction that folds the pending
registrations the caller names into the registry: it reads the registry's state,
replays its public history and proves each key absent. Nothing of the
registrations' booker is needed.
-}
module Singular.CLI.State
    ( -- * What a program hosts
      Host (..)
    , neutralHost

      -- * The commands
    , runStateCreate
    , runStateFold
    ) where

import Control.Monad (unless)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short qualified as SBS
import Data.List (nub)
import Data.Maybe (fromMaybe, maybeToList)
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((^.))

import Cardano.Crypto.Hash (hashFromBytes)
import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx.Out (coinTxOutL)
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (Script, hashScript)
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Mary.Value (PolicyID (..))
import Cardano.Ledger.TxIn (TxIn)

import Singular.CLI.Command
    ( ApplicationPolicy (..)
    , RegistryAccess (..)
    , StateCreateArgs (..)
    , StateFoldArgs (..)
    , WriteSettings (..)
    )
import Singular.CLI.Live (receipt, txInText)
import Singular.CLI.Promise (Promise (..))
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Registry (registryFields)
import Singular.CLI.Session
    ( Env
    , WriteContext (..)
    , failWith
    , readStep
    )
import Singular.CLI.Steps
    ( creationToken
    , loadReleaseBlueprint
    , observeOutput
    , refusing
    , scriptSource
    , sendStep
    , stateWrite
    )
import Singular.Registry.Blueprint (Blueprint)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (ConwayEra, TxOut)
import Singular.Registry.LedgerProvider (Session)
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.StateToken (renderStateToken)
import Singular.Registry.TrieState
    ( RegistryIdentity (..)
    , StatePolicyId (..)
    )
import Singular.Registry.TxBuilder.Internal (scriptHashBytes)
import Singular.State.Assemble
    ( Payer (..)
    , Program
    , inlineDatumOf
    , resolvePayer
    )
import Singular.State.Fold qualified as Fold
import Singular.State.Genesis (buildGenesis)
import Singular.State.Publication
    ( Publication (..)
    , ReferenceDiscovery (..)
    , References (..)
    , planNextReference
    , planReferences
    )
import Singular.State.Records (decodeStateDatum)
import Singular.State.Script
    ( ScriptSource (..)
    , StateScript (..)
    , referenceOutputs
    , stateScriptFromBlueprint
    )

-- | What a program that hosts the commands knows of its application.
data Host = Host
    { hostScripts
        :: Blueprint
        -> Maybe ApplicationPolicy
        -> Either String (PolicyID, [Script ConwayEra])
    {- ^ The policy of the application, which is the state validator's one
    parameter, and the validators the application owns, from the release's
    blueprint and the policy the caller gave, when the program lets the
    caller give it
    -}
    , hostCreation
        :: [(Script ConwayEra, ScriptSource)]
        -> TxIn
        -> RegistryIdentity
        -> Program ()
    {- ^ The steps the application adds to the transaction that creates a
    registry, given where each validator it owns is taken from, the seed and
    the registry
    -}
    , hostFold
        :: Session NoWitness IO
        -> Network
        -> [(Script ConwayEra, ScriptSource)]
        -> IO (Either String Fold.Application)
    {- ^ What the application contributes to a fold, given where each
    validator it owns is taken from
    -}
    }

{- | The program that knows no application beyond the policy it is given: it
creates a registry with no step of its own and folds nothing.
-}
neutralHost :: Host
neutralHost =
    Host
        { hostScripts = \_ given -> case given of
            Nothing -> Left "no application policy is given"
            Just (ApplicationPolicy bytes) -> case hashFromBytes (SBS.fromShort bytes) of
                Just hash -> Right (PolicyID (ScriptHash hash), [])
                Nothing -> Left "the application policy is not a 28-byte hash"
        , hostCreation = \_ _ _ -> pure ()
        , hostFold = \_ _ _ ->
            pure
                (Left "this program composes no application, so it folds nothing")
        }

-- ---------------------------------------------------------
-- create
-- ---------------------------------------------------------

{- | Create a registry: publish the scripts no live copy carries, then spend
the seed.
-}
runStateCreate :: Text -> Env -> Host -> StateCreateArgs -> IO Value
runStateCreate command env host a = do
    blueprint <- loadReleaseBlueprint (stateCreateBlueprint a)
    (application, own) <-
        either (failWith ClientRefusal) pure $
            hostScripts host blueprint (stateCreatePolicy a)
    stateScript <-
        either (failWith ClientRefusal . ("the state validator: " <>)) pure $
            stateScriptFromBlueprint blueprint application
    let ws = stateCreateWrite a
        magic = providerMagic (writeProvider ws)
        scripts = stateScript : own
    stateWrite
        env
        (stateCreateStateDir a)
        (creationToken (hashScript stateScript))
        command
        ws
        $ \wc reconciled -> do
            let payer = wcCaller wc
            (found, published, discovery) <-
                publishScripts wc payer (maybeToList (stateCreateSeed a)) scripts
            let sourceOf script = scriptSource script found
                stateSource = sourceOf stateScript
                ownSources = [(script, sourceOf script) | script <- own]
            (confirmed, (registry, seed)) <-
                sendStep
                    wc
                    "create"
                    ["wallet outputs"]
                    ( \(RegistryIdentity _ name, _) -> HoldsToken (PolicyID (hashScript stateScript)) name
                    )
                    $ \view -> do
                        funded <- resolvePayer view payer >>= refusing
                        let seed = fromMaybe (fst (payerFunding funded)) (stateCreateSeed a)
                        carriers <-
                            concat
                                <$> traverse
                                    ( \(script, source) ->
                                        referenceOutputs view script source >>= refusing
                                    )
                                    ownSources
                        (tx, registry) <-
                            buildGenesis
                                view
                                (StateScript stateScript stateSource)
                                seed
                                payer
                                carriers
                                (hostCreation host ownSources seed)
                                >>= refusing
                        pure (tx, (registry, seed))
            let RegistryIdentity _ name = registry
                token = (PolicyID (hashScript stateScript), name)
            (output, out) <-
                observeOutput wc "create" confirmed 0 (HoldsToken (fst token) name)
            pure . receipt command Success $
                registryFields magic token
                    <> [ ("stateToken", toJSON (renderStateToken token))
                       , ("seed", toJSON (txInText seed))
                       , ("stateOutput", toJSON (txInText output))
                       , ("root", toJSON (rootOf out))
                       ,
                           ( "applicationPolicy"
                           , toJSON (hexOf (scriptHashBytes (policyHash application)))
                           )
                       ,
                           ( "scripts"
                           , toJSON
                                ( scriptsFields
                                    (zip ("state" : map (const "application") own) scripts)
                                    found
                                    published
                                    discovery
                                )
                           )
                       , ("reconciled", reconciled)
                       ]
  where
    policyHash (PolicyID hash) = hash

{- | Publish one missing script at a time. Confirmation and readback finish
before the next fresh chain view chooses funding or a missing script. A rerun
reuses every genuine live copy after stateWrite reconciles uncertain sends.
-}
publishScripts
    :: WriteContext
    -> Addr
    -> [TxIn]
    -> [Script ConwayEra]
    -> IO ([(ScriptHash, TxIn)], [(ScriptHash, TxIn)], [ReferenceDiscovery])
publishScripts wc payer reserved scripts = next [] []
  where
    next published discovery = do
        let remaining =
                [ script
                | script <- scripts
                , hashScript script `notElem` map fst published
                ]
        references <-
            readStep
                (wcTracer wc)
                (wcSource wc)
                ["wallet outputs", "reference scripts"]
                (wcCapabilities wc)
                (\view -> planNextReference reserved view payer remaining)
                >>= refusing
        let seen = discovery <> referencesDiscovery references
        case referencesPublication references of
            Nothing ->
                pure
                    ( [(hash, ref) | (hash, (ref, _)) <- referencesLive references]
                        <> published
                    , published
                    , seen
                    )
            Just publication -> case publicationOutputs publication of
                [(hash, _)] -> do
                    let step = publicationStep hash
                    (confirmed, (located, freshDiscovery)) <-
                        sendStep
                            wc
                            step
                            ["wallet outputs", "reference scripts"]
                            (CarriesScript . fst . fst)
                            $ \view -> do
                                fresh <- planNextReference reserved view payer remaining >>= refusing
                                case referencesPublication fresh of
                                    Just built
                                        | [located@(actual, _)] <- publicationOutputs built
                                        , actual == hash ->
                                            pure (publicationTx built, (located, referencesDiscovery fresh))
                                    _ ->
                                        failWith
                                            ClientRefusal
                                            "the live script copies changed while publication was being planned; run the command again"
                    _ <- observeOutput wc step confirmed 0 (CarriesScript hash)
                    next (published <> [located]) (seen <> freshDiscovery)
                _ ->
                    failWith ClientRefusal "the publication must hold exactly one script"
    publicationStep hash = case scripts of
        [_] -> "publish-scripts"
        state : _ | hashScript state == hash -> "publish-state-script"
        _ -> "publish-application-script"

-- | The scripts of the creation, each with where it is taken from and whether this run published it.
scriptsFields
    :: [(Text, Script ConwayEra)]
    -> [(ScriptHash, TxIn)]
    -> [(ScriptHash, TxIn)]
    -> [ReferenceDiscovery]
    -> [Value]
scriptsFields named found published discovery =
    [ object
        [ "script" .= role
        , "hash" .= hexOf (scriptHashBytes (hashScript script))
        , "reference" .= fmap txInText (lookup (hashScript script) found)
        , "published" .= (hashScript script `elem` map fst published)
        , "outcome"
            .= ( if hashScript script `elem` map fst published
                    then "published"
                    else "reused" :: Text
               )
        , "discovery" .= discoveryField (hashScript script)
        ]
    | (role, script) <- named
    ]
  where
    discoveryField hash =
        let candidates =
                nub
                    [ candidate
                    | ReferenceDiscovery expected inspected <- discovery
                    , expected == hash
                    , candidate <- inspected
                    ]
        in  object
                [ "status"
                    .= ( if any ((== Just hash) . snd) candidates
                            then "live copy"
                            else "no live copy" :: Text
                       )
                , "candidates"
                    .= [ object
                            [ "reference" .= txInText ref
                            , "foundHash" .= fmap (hexOf . scriptHashBytes) actual
                            , "expectedHash" .= hexOf (scriptHashBytes hash)
                            , "verdict"
                                .= (if actual == Just hash then "genuine" else "foreign" :: Text)
                            ]
                       | (ref, actual) <- candidates
                       ]
                ]

-- | The root a state output's datum carries, in hex.
rootOf :: TxOut ConwayEra -> Text
rootOf out = maybe "" hexOf (inlineDatumOf out >>= decodeStateDatum)

hexOf :: ByteString -> Text
hexOf = T.pack . BC.unpack . B16.encode

-- ---------------------------------------------------------
-- fold
-- ---------------------------------------------------------

{- | Fold the pending registrations the caller names into the registry, built
from the chain alone.
-}
runStateFold :: Env -> Host -> StateFoldArgs -> IO Value
runStateFold env host a = do
    blueprint <- loadReleaseBlueprint (stateFoldBlueprint a)
    (application, own) <-
        either (failWith ClientRefusal) pure $
            hostScripts host blueprint Nothing
    stateScript <-
        either (failWith ClientRefusal . ("the state validator: " <>)) pure $
            stateScriptFromBlueprint blueprint application
    let token@(policy, name) = accessToken (stateFoldAccess a)
        ws = stateFoldWrite a
        magic = providerMagic (writeProvider ws)
        PolicyID statePolicyHash = policy
        registry =
            RegistryIdentity
                (StatePolicyId (scriptHashBytes statePolicyHash))
                name
        scripts = stateScript : own
    unless (policy == PolicyID (hashScript stateScript)) $
        failWith
            ClientRefusal
            ( "the registry's state policy is not the one the release's state validator has for this application: "
                <> "this blueprint is not the registry's release"
            )
    stateWrite env (stateFoldStateDir a) token "fold" ws $ \wc reconciled -> do
        let payer = wcCaller wc
        (confirmed, folded) <-
            sendStep
                wc
                "fold"
                ["wallet outputs", "reference scripts", "registry"]
                (const (HoldsToken policy name))
                $ \view -> do
                    references <- planReferences view payer scripts >>= refusing
                    let found = [(hash, ref) | (hash, (ref, _)) <- referencesLive references]
                        sourceOf script = scriptSource script found
                    contributed <-
                        hostFold host view Testnet [(script, sourceOf script) | script <- own]
                            >>= either (failWith ClientRefusal) pure
                    tx <-
                        Fold.buildRegistrationFold
                            view
                            (StateScript stateScript (sourceOf stateScript))
                            contributed
                            registry
                            (stateFoldPending a)
                            payer
                            >>= refusing
                    let keys = [(pending, Just key) | (pending, key) <- Fold.foldedRequests tx]
                    pure (tx, keys)
        (output, out) <-
            observeOutput wc "fold" confirmed 0 (HoldsToken policy name)
        pure . receipt "fold" Success $
            registryFields magic token
                <> [ ("stateToken", toJSON (renderStateToken token))
                   , ("stateOutput", toJSON (txInText output))
                   , ("root", toJSON (rootOf out))
                   , ("lovelace", toJSON (coinOf out))
                   ,
                       ( "folded"
                       , toJSON
                            [ object
                                [ "pending" .= txInText pending
                                , "key" .= fmap hexOf key
                                ]
                            | (pending, key) <- folded
                            ]
                       )
                   , ("reconciled", reconciled)
                   ]
  where
    coinOf out = let Coin c = out ^. coinTxOutL in c
