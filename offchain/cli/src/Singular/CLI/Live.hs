{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.Live
Description : A registry resolved from its state token, attached to the live chain
License     : Apache-2.0

A command names its registry by the state token; the release and the chain
say the rest ("Singular.Registry.StateToken"). The acquired session supplies
the references the command runs and the state output, then Session.history
reconstructs its trie from create. Selections, leaves, proofs and
speculation use that public replay; no local trie is opened.
-}
module Singular.CLI.Live
    ( -- * The saved registry
      Saved (..)
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
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((^.))

import Cardano.Crypto.Hash.Class (hashFromBytes)
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
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxIn)

import Singular.CLI.Command (RegistryAccess (..))
import Singular.CLI.Proof qualified as Proof
import Singular.CLI.Receipt (OutcomeClass, outcomeName)
import Singular.CLI.Receipt qualified as Receipt
import Singular.CLI.Registry (Release (..), hexT)
import Singular.CLI.Session (failWith, failWithFields)
import Singular.CLI.TrieTrace (observeTrie)
import Singular.Registry.Application
    ( Application (..)
    , DecodedHolding (..)
    , HoldingRules (..)
    )
import Singular.Registry.Blueprint (NamingCodes (..))
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Deployment (renderOutRef)
import Singular.Registry.Evidence qualified as Cage
import Singular.Registry.Ledger
    ( AssetName (..)
    , ConwayEra
    , Root (..)
    , TokenId (..)
    )
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.StateToken
    ( ReferenceRole (..)
    , ResolvedRegistry (..)
    , findReferences
    , findStateOutput
    , renderIdentityRefusal
    , renderReferenceRefusal
    , resolveRegistry
    )
import Singular.Registry.TrieState qualified as TS
import Singular.Registry.TrieState.Lineage (lineageTrieStateObserved)
import Singular.Registry.TxBuilder.Internal
    ( computeScriptHash
    , extractCageDatum
    , scriptHashBytes
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRoot (..)
    , OnChainTokenState (..)
    )

{- | A registry resolved from its state token in this release: the
configuration and codes it runs, and the reference outputs found for the
roles the command's transactions run. Nothing of it is read from or
written to the actor's directory.
-}
data Saved = Saved
    { savedDir :: FilePath
    -- ^ The actor's directory: its journal, never an input to identity
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

-- | A saved registry with its live outputs resolved.
data Live = Live
    { liveSession :: Cage.Session Cage.NoWitness IO
    , liveSaved :: Saved
    , liveRefs :: [(TxIn, TxOut ConwayEra)]
    , liveState :: (TxIn, TxOut ConwayEra)
    }

{- | The registry's current state output, read again from this session: the
output that holds the state token at the state address. The references are
the ones the resolution found.
-}
attachLive :: Cage.Session Cage.NoWitness IO -> Saved -> IO Live
attachLive view s = do
    found <- findStateOutput (stateToken s) view
    (stateIn, stateOut, _) <-
        either
            (failWith Receipt.StaleState . T.unpack . renderIdentityRefusal)
            pure
            found
    pure
        Live
            { liveSession = view
            , liveSaved = s
            , liveRefs = savedRefs s
            , liveState = (stateIn, stateOut)
            }

-- | The state token of a saved registry.
stateToken :: Saved -> Cage.Asset
stateToken s =
    let TokenId name = savedToken s
    in  (PolicyID (cfgScriptHash (savedCfg s)), name)

-- | The root the registry's live state output commits to.
observedRoot :: Live -> Either String ByteString
observedRoot l = case extractCageDatum (snd (liveState l)) of
    Just (StateDatum st) -> Right (unOnChainRoot (stateRoot st))
    _ -> Left "the registry's state output carries no state datum"

{- | The application address, from the registry's pinned application policy
(slice 2: identical for a script pin, since the policy is the applied
script's hash; sensible for a hash pin, whose script bytes do not exist).
-}
applicationAddr :: Saved -> Addr
applicationAddr s =
    Addr
        Testnet
        (ScriptHashObj (policyHash (cfgApplicationPolicy (savedCfg s))))
        StakeRefNull
  where
    policyHash bytes = case hashFromBytes (SBS.fromShort bytes) of
        Just h -> ScriptHash h
        Nothing -> error "applicationAddr: pinned application policy is not 28 bytes"

-- | Every output at the application's address (through the value's address).
liveOutputs
    :: Application
    -> Cage.Session Cage.NoWitness IO
    -> Saved
    -> IO [(TxIn, TxOut ConwayEra)]
liveOutputs _app view s = Cage.outputsAt view (applicationAddr s)

{- | The outputs at the application that are this registry's holding of
@key@, through the value. With holding rules (the open datum) this is the
envelope's lookup (version, registry, active policy, key, exactly one token;
a foreign envelope is not a holding); without them (neutral) there are none
(the datum is never decoded).
-}
holdingsFor
    :: Application
    -> Saved
    -> ByteString
    -> [(TxIn, TxOut ConwayEra)]
    -> [((TxIn, TxOut ConwayEra), DecodedHolding)]
holdingsFor app s key outs = case appHolding app of
    Just rules -> hrFindHoldings rules (savedCfg s) (savedToken s) key outs
    Nothing -> []

{- | The key's one live holding in this registry, or why there is none
(through the value; same words as before for the open datum, so every
refusal stays byte-identical).
-}
liveOutputFor
    :: Application
    -> Saved
    -> ByteString
    -> [(TxIn, TxOut ConwayEra)]
    -> Either String ((TxIn, TxOut ConwayEra), DecodedHolding)
liveOutputFor app s key outs = case appHolding app of
    Just rules -> case hrLiveOutputFor rules (savedCfg s) (savedToken s) key outs of
        Left why -> Left (T.unpack why)
        Right one -> Right one
    Nothing -> Left ("no live output holds key 0x" <> BC.unpack (B16.encode key))

{- | The published output carrying the applied script as a reference script
(through the value; without holding rules there is none to find).
-}
applicationReference
    :: Application -> Live -> Maybe (TxIn, TxOut ConwayEra)
applicationReference app l = case appHolding app of
    Nothing -> Nothing
    Just _ ->
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
    :: Application
    -> FilePath
    -> Release
    -> RegistryAccess
    -> Set ReferenceRole
    -> Maybe Addr
    -- ^ The actor's wallet, when the command has one
    -> Cage.Session Cage.NoWitness IO
    -> IO Saved
resolveSaved app dir release access roles wallet view = do
    resolved <-
        resolveRegistry app release (accessToken access) view
            >>= either
                (failWith Receipt.ClientRefusal . T.unpack . renderIdentityRefusal)
                pure
    -- Without holding rules (neutral) no application reference is needed
    -- (a hash pin publishes none); with them, every needed role is found.
    let needed = case appHolding app of
            Nothing -> Set.delete RoleApplication roles
            Just _ -> roles
    found <-
        findReferences view wallet (resolvedExpected resolved) needed
            >>= either
                (failWith Receipt.ClientRefusal . T.unpack . renderReferenceRefusal)
                pure
    let (_, name) = resolvedToken resolved
    pure
        Saved
            { savedDir = dir
            , savedCfg = resolvedConfig resolved
            , savedCodes = resolvedCodes resolved
            , savedToken = TokenId name
            , savedRefs = Map.elems found
            }
