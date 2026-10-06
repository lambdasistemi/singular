{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.Live
Description : A saved registry attached to the live chain
License     : Apache-2.0

A saved identity is checked against this release and the recorded seed.
The acquired session supplies its live references and state output, then
Session.history reconstructs its trie from create. Selections, leaves,
proofs and speculation use that public replay; no local trie is opened.
-}
module Singular.CLI.Live
    ( -- * The saved registry
      Saved (..)
    , loadSaved
    , resolveSaved

      -- * Attached to the chain
    , Live (..)
    , attachLive
    , observedRoot
    , applicationAddr
    , liveOutputs
    , liveOutputFor
    , holdingsFor
    , applicationReference
    , coinOf
    , assetsOf
    , valueJson

      -- * Public lineage
    , TrieContext
    , openTrie
    , selectTrie
    , requireTrieSelection
    , withTrie
    , selectedTrieRoot
    , trieLeaf
    , savedIdentity
    , newStatePoint
    , failTrie

      -- * Receipts
    , receipt
    , txInText
    , applied
    ) where

import Data.Aeson (Value, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short qualified as SBS
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((^.))

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , coinTxOutL
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (Network (Testnet), StrictMaybe (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxIn)

import Singular.Application.OpenDatum.Envelope
    ( Control (..)
    , Envelope (..)
    , envelopeVersion
    , registryBytes
    )
import Singular.Application.OpenDatum.Release (heldOf, liveEnvelope)
import Singular.Application.OpenDatum.Script
    ( Application (..)
    , applicationTitle
    )
import Singular.CLI.Command (RegistryAccess)
import Singular.CLI.Proof qualified as Proof
import Singular.CLI.Receipt (OutcomeClass, outcomeName)
import Singular.CLI.Receipt qualified as Receipt
import Singular.CLI.Registry
    ( RegistryConfig (..)
    , Release (..)
    , checkPins
    , hexT
    , loadRelease
    , partsOf
    , pinsOf
    , readConfig
    , renderIdentityError
    )
import Singular.CLI.Session (failWith, failWithFields)
import Singular.CLI.TrieTrace (observeTrie)
import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint (NamingCodes (..))
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Deployment.Attach (cageConfigForApplication)
import Singular.Registry.Deployment
    ( Attached (..)
    , Deployment (..)
    , attach
    , parseOutRef
    , renderOutRef
    )
import Singular.Registry.Evidence qualified as Cage
import Singular.Registry.Ledger
    ( AssetName (..)
    , ConwayEra
    , Root (..)
    , TokenId (..)
    )
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.StateToken (ReferenceRole)
import Singular.Registry.TrieState qualified as TS
import Singular.Registry.TrieState.Lineage (lineageTrieStateObserved)
import Singular.Registry.TxBuilder.Internal
    ( computeScriptHash
    , extractCageDatum
    , scriptHashBytes
    , txInToRef
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRoot (..)
    , OnChainTokenState (..)
    )

-- | A registry directory read and checked against this release.
data Saved = Saved
    { savedDir :: FilePath
    , savedConfig :: RegistryConfig
    , savedCfg :: CageConfig
    , savedCodes :: NamingCodes
    -- ^ As the registry pins them: the application applied
    , savedToken :: TokenId
    , savedRefs :: [(TxIn, TxOut ConwayEra)]
    -- ^ The reference outputs found for the roles the command runs
    }

-- | The applied open-datum script of a saved registry.
applied :: Saved -> SBS.ShortByteString
applied = ncApplication . savedCodes

{- | Read the registry at @dir@ and derive every pin again from the
release at @blueprint@ and the recorded seed; refuse any difference.
-}
loadSaved :: FilePath -> FilePath -> IO Saved
loadSaved dir blueprint = do
    conf <- readConfig dir
    rel <-
        loadRelease blueprint >>= either (failWith Receipt.ClientRefusal) pure
    if confApplication conf == applicationTitle OpenDatumApplication
        then pure ()
        else
            failWith
                Receipt.ClientRefusal
                ( "the saved registry names application "
                    <> show (confApplication conf)
                    <> "; this command serves "
                    <> show (applicationTitle OpenDatumApplication)
                )
    let dep = confDeployment conf
    (cfg, pinned) <-
        either
            (failWith Receipt.ClientRefusal)
            pure
            ( cageConfigForApplication
                OpenDatumApplication
                (releaseCodes rel)
                (releaseState rel)
                (releaseRequest rel)
                dep
            )
    either
        (failWith Receipt.ClientRefusal . renderIdentityError)
        pure
        (checkPins conf (pinsOf cfg))
    seedIn <-
        either
            (failWith Receipt.ClientRefusal)
            pure
            (parseOutRef (depSeedOutRef dep))
    pure
        Saved
            { savedDir = dir
            , savedConfig = conf
            , savedCfg = cfg
            , savedCodes = pinned
            , savedToken =
                TokenId (AssetName (SBS.toShort (deriveAssetName (txInToRef seedIn))))
            , savedRefs = []
            }

-- | A saved registry with its live outputs resolved.
data Live = Live
    { liveSession :: Cage.Session Cage.NoWitness IO
    , liveSaved :: Saved
    , liveRefs :: [(TxIn, TxOut ConwayEra)]
    , liveState :: (TxIn, TxOut ConwayEra)
    }

-- | Resolve the recorded references and the current state output.
attachLive :: Cage.Session Cage.NoWitness IO -> Saved -> IO Live
attachLive view s = do
    att <-
        attach view (confDeployment (savedConfig s)) (partsOf (savedCfg s))
    pure
        Live
            { liveSession = view
            , liveSaved = s
            , liveRefs = attRefUtxos att
            , liveState = attStateUtxo att
            }

-- | The root the registry's live state output commits to.
observedRoot :: Live -> Either String ByteString
observedRoot l = case extractCageDatum (snd (liveState l)) of
    Just (StateDatum st) -> Right (unOnChainRoot (stateRoot st))
    _ -> Left "the registry's state output carries no state datum"

-- | The applied open-datum script's address.
applicationAddr :: Saved -> Addr
applicationAddr s =
    Addr
        Testnet
        (ScriptHashObj (computeScriptHash (applied s)))
        StakeRefNull

-- | Every output at the application's address.
liveOutputs
    :: Cage.Session Cage.NoWitness IO
    -> Saved
    -> IO [(TxIn, TxOut ConwayEra)]
liveOutputs view s = Cage.outputsAt view (applicationAddr s)

{- | The outputs at the application that are this registry's holding of
@key@: an envelope of version 1 naming this registry's full state asset,
its pinned active policy and the key, over exactly one of the key's
active token under that pinned policy. An output anyone paid to the
address under an envelope naming another registry, policy or key is not
a holding of this one.
-}
holdingsFor
    :: Saved
    -> ByteString
    -> [(TxIn, TxOut ConwayEra)]
    -> [((TxIn, TxOut ConwayEra), Envelope)]
holdingsFor s key outs =
    [ (u, e)
    | u@(_, o) <- outs
    , Right e <- [liveEnvelope o]
    , let c = envControl e
    , ctlVersion c == envelopeVersion
    , registryBytes (ctlRegistry c) == identity
    , ctlActivePolicy c == SBS.fromShort (cfgActivePolicy (savedCfg s))
    , ctlKey c == key
    , heldOf c o == 1
    ]
  where
    identity =
        scriptHashBytes (cfgScriptHash (savedCfg s))
            <> let TokenId (AssetName n) = savedToken s in SBS.fromShort n

-- | The key's one live holding in this registry, or why there is none.
liveOutputFor
    :: Saved
    -> ByteString
    -> [(TxIn, TxOut ConwayEra)]
    -> Either String ((TxIn, TxOut ConwayEra), Envelope)
liveOutputFor s key outs =
    case holdingsFor s key outs of
        [one] -> Right one
        [] -> Left ("no live output holds key 0x" <> BC.unpack (B16.encode key))
        _ ->
            Left
                ( "more than one live output claims key 0x"
                    <> BC.unpack (B16.encode key)
                )

-- | The published output carrying the applied script as a reference script.
applicationReference :: Live -> Maybe (TxIn, TxOut ConwayEra)
applicationReference l =
    case [ u
         | u@(_, o) <- liveRefs l
         , SJust sc <- [o ^. referenceScriptTxOutL]
         , hashScript sc == computeScriptHash (applied (liveSaved l))
         ] of
        (u : _) -> Just u
        [] -> Nothing

-- | A capability and its caller's selection; no nodes or files are retained.
newtype TrieContext = TrieContext
    { trieSelected
        :: IORef (Either TS.TrieFailure (TS.TrieState IO, TS.TrieSelection))
    }

savedIdentity :: Saved -> TS.RegistryIdentity
savedIdentity saved =
    let TokenId name = savedToken saved
    in  TS.RegistryIdentity
            (TS.StatePolicyId (scriptHashBytes (cfgScriptHash (savedCfg saved))))
            name

newStatePoint
    :: Cage.Session Cage.NoWitness IO -> TxIn -> TS.StatePoint
newStatePoint session output =
    let Cage.SessionId label = Cage.sessionId session
        binding = case Cage.sessionBinding session of
            Cage.Unbound -> TS.Unbound
            Cage.Bound slot header -> TS.Bound slot header
    in  TS.StatePoint (TS.SessionId label) binding output

openTrie :: Saved -> IO TrieContext
openTrie saved = TrieContext <$> newIORef (Left (noSelection saved))

selectTrie
    :: Saved -> Live -> TrieContext -> IO (Either TS.TrieFailure ())
selectTrie saved live context = case observedRoot live of
    Left _ -> do
        let refused = Left (noSelection saved)
        writeIORef (trieSelected context) refused
        pure refused
    Right root -> do
        let chosen =
                TS.TrieSelection
                    (savedIdentity saved)
                    (newStatePoint (liveSession live) (fst (liveState live)))
                    (Root root)
            cap = lineageTrieStateObserved (liveSession live) observeTrie
        writeIORef (trieSelected context) (Right (cap, chosen))
        TS.withTrieState cap chosen (const (pure ()))

requireTrieSelection :: Saved -> Live -> TrieContext -> IO ()
requireTrieSelection saved live context = selectTrie saved live context >>= either failTrie pure

withTrie :: TrieContext -> (TS.TrieSnapshot IO -> IO a) -> IO a
withTrie context use = do
    held <- readIORef (trieSelected context)
    case held of
        Left why -> failTrie why
        Right (cap, chosen) -> TS.withTrieState cap chosen use >>= either failTrie pure

selectedTrieRoot :: TrieContext -> IO ByteString
selectedTrieRoot context = withTrie context (pure . unRoot . TS.trieRoot)

-- Preserve proof refusals at the command boundary. History failures use
-- their existing TrieState name, payload and outcome through failTrie.
trieLeaf
    :: TrieContext
    -> ByteString
    -> ByteString
    -> IO (Either Proof.AuthError TS.Leaf)
trieLeaf context key _ = withTrie context $ \snap -> do
    result <- TS.leafAt snap key
    case result of
        Right leaf -> pure (Right leaf)
        Left TS.MissingProof{} -> pure (Left (Proof.ProofInconsistent key))
        Left why -> failTrie why

-- | No selection is held yet for the saved registry.
noSelection :: Saved -> TS.TrieFailure
noSelection saved = TS.StaleState (savedIdentity saved) Nothing TS.NoSelection

{- | Stop with a trie refusal: its name as the reason, and the registry, the
transaction where one is known and the cause as receipt fields.
-}
failTrie :: TS.TrieFailure -> IO a
failTrie why =
    failWithFields
        outcome
        ("TrieState " <> T.unpack (TS.trieFailureName why))
        (TS.trieFailureFields why)
  where
    outcome = case why of
        TS.MissingProof{} -> Receipt.ProofMissing
        TS.WrongRegistry{} -> Receipt.ClientRefusal
        TS.UndecodableRequest{} -> Receipt.ClientRefusal
        TS.HistoryIncomplete
            _
            _
            (TS.ProviderHistoryFailure (Cage.HistoryReadFailure _)) -> Receipt.ClientRefusal
        TS.HistoryIncomplete{} -> Receipt.StaleState
        TS.RootDoesNotChain{} -> Receipt.StaleState
        TS.StaleState{} -> Receipt.StaleState

-- | One command's printed receipt.
receipt :: Text -> OutcomeClass -> [(Text, Value)] -> Value
receipt command outcome fields =
    object
        ( [ "command" .= command
          , "outcome" .= outcomeName outcome
          ]
            <> [(Key.fromText k, v) | (k, v) <- fields]
        )

txInText :: TxIn -> Text
txInText = renderOutRef

-- | The lovelace an output holds.
coinOf :: TxOut ConwayEra -> Integer
coinOf o = let Coin c = o ^. coinTxOutL in c

-- | The non-ada assets an output actually holds, as a receipt states them.
assetsOf :: TxOut ConwayEra -> [Value]
assetsOf o =
    [ object
        [ "policy" .= hexT (scriptHashBytes p)
        , "name" .= hexT (SBS.fromShort n)
        , "quantity" .= q
        ]
    | let MaryValue _ (MultiAsset m) = o ^. valueTxOutL
    , (PolicyID p, assets) <- Map.toList m
    , (AssetName n, q) <- Map.toList assets
    ]

-- | What an output actually holds: its lovelace and its other assets.
valueJson :: TxOut ConwayEra -> Value
valueJson o = object ["lovelace" .= coinOf o, "assets" .= assetsOf o]

{- | Resolve the registry a command names by its state token, in this
session, and find the references its transactions run. The actor's
directory is where its journal lives; nothing in it is read here.
-}
resolveSaved
    :: FilePath
    -> Release
    -> RegistryAccess
    -> Set ReferenceRole
    -> [(TxIn, TxOut ConwayEra)]
    -- ^ The actor's wallet outputs
    -> Cage.Session Cage.NoWitness IO
    -> IO Saved
resolveSaved _ _ _ _ _ _ =
    failWith Receipt.ClientRefusal "resolveSaved: not implemented"
