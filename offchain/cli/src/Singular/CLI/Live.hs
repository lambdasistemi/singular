{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

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
    , standingFields
    , stampStanding
    , withStandingOnFailure

      -- * Attached to the chain
    , Live (..)
    , attachLive
    , observedRoot
    , applicationAddr
    , liveOutputs
    , liveWitness
    , liveOutputFor
    , holdingsFor
    , applicationReference
    , coinOf
    , assetsOf
    , valueJson

      -- * Public lineage
    , SelectedTrie
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

import Control.Exception
    ( SomeException
    , catch
    , fromException
    , throwIO
    , toException
    )
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short qualified as SBS
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
import Singular.CLI.Failure
    ( CommandFailure (..)
    , failWith
    , failWithFields
    , markedLike
    , reportedOf
    )
import Singular.CLI.Proof qualified as Proof
import Singular.CLI.Receipt (OutcomeClass, outcomeName)
import Singular.CLI.Receipt qualified as Receipt
import Singular.CLI.Registry (Release (..), hexT)
import Singular.CLI.TrieTrace (observeTrie)
import Singular.Registry.Application
    ( Application (..)
    , ApplicationPinStanding
    , DecodedHolding (..)
    , HoldingRules (..)
    , renderApplicationPinStanding
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
import Singular.Registry.Witness
    ( WitnessFound
    , WitnessKind
    , findWitness
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
    , savedApplicationPin :: ApplicationPinStanding
    {- ^ Whether the resolution compared the application pin with the
    datum's: the one fact the receipts say about it
    -}
    }

-- | The applied application script of a saved registry.
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

The pins of the datum are not compared again here: every fold preserves the
four pinned policies on chain (the state validator refuses a fold that alters
one, by the name pins-altered), so the comparison made when the command
resolved its registry holds for every later read of the state output.
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

{- | The key's witness of one kind, found by asking the provider who holds the
asset ('Singular.Registry.Witness.witnessAsset' names it), never by listing
the application's outputs. A provider that cannot answer stops the command as
an address read that cannot be answered does.
-}
liveWitness
    :: Cage.Session Cage.NoWitness IO
    -> Saved
    -> WitnessKind
    -> ByteString
    -> IO WitnessFound
liveWitness view s kind key =
    findWitness view (savedCfg s) kind key >>= either refused pure
  where
    refused (Cage.NetworkTimeRefusal failure) = throwIO failure
    refused failure = throwIO failure

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

{- | A registry's public trie as one successfully selected value: the
session-bound replay capability and the state point and root it was
selected at, validated before the value existed. The type exports no
constructor and no fields, so only 'selectTrie' on success produces one;
an unselected or unvalidated selection cannot be forged or held. Every
use revalidates through the capability against the session, registry,
root and state point it names, so a selection that no longer holds is
refused at use, and no snapshot is cached beyond it.
-}
data SelectedTrie = SelectedTrie
    { selectedCapability :: TS.TrieState IO
    , selectedAt :: TS.TrieSelection
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

{- | Select the registry's public trie at its live state output's point
and root. The selection is validated by running the public replay before
any value is returned: a replay that fails leaves no selection to use, so
nothing unvalidated can be written or held. The capability is bound to the
session that selected it — an immutable value is not a lifetime proof, and
uses refuse when that session, registry, root or state point no longer
holds. Reselection returns a new, independent value; the caller passes that
new value for the operation it serves.
-}
selectTrie :: Saved -> Live -> IO (Either TS.TrieFailure SelectedTrie)
selectTrie saved live = case observedRoot live of
    Left _ -> pure (Left (noSelection saved))
    Right root -> do
        let chosen =
                TS.TrieSelection
                    (savedIdentity saved)
                    (newStatePoint (liveSession live) (fst (liveState live)))
                    (Root root)
            cap = lineageTrieStateObserved (liveSession live) observeTrie
        validated <- TS.withTrieState cap chosen (const (pure ()))
        pure (SelectedTrie cap chosen <$ validated)

{- | 'selectTrie', stopping the command with the trie's own refusal when the
selection fails.
-}
requireTrieSelection :: Saved -> Live -> IO SelectedTrie
requireTrieSelection saved live = selectTrie saved live >>= either failTrie pure

{- | Use a selected trie. The use revalidates the selection through its
session-bound capability — every use reads the public history source again
— and refuses with the trie's own refusal when the session, registry, root
or state point no longer holds. A held value is one point in history, not a
cache: history that ran ahead along one chain does not invalidate it.
-}
withTrie :: SelectedTrie -> (TS.TrieSnapshot IO -> IO a) -> IO a
withTrie selected use =
    TS.withTrieState
        (selectedCapability selected)
        (selectedAt selected)
        use
        >>= either failTrie pure

selectedTrieRoot :: SelectedTrie -> IO ByteString
selectedTrieRoot selected = withTrie selected (pure . unRoot . TS.trieRoot)

-- Preserve proof refusals at the command boundary. History failures use
-- their existing TrieState name, payload and outcome through failTrie.
trieLeaf
    :: SelectedTrie
    -> ByteString
    -> ByteString
    -> IO (Either Proof.AuthError TS.Leaf)
trieLeaf selected key _ = withTrie selected $ \snap -> do
    result <- TS.leafAt snap key
    case result of
        Right leaf -> pure (Right leaf)
        Left TS.MissingProof{} -> pure (Left (Proof.ProofInconsistent key))
        Left why -> failTrie why

{- | The refusal a registry's trie carries when no selection could be made
at its live state output: the same payload a selected value's uses report
for an unheld selection.
-}
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
            , savedApplicationPin = resolvedApplicationPin resolved
            }

{- | The receipt field that says whether the application pin was compared
with the datum's, for a command that resolved a registry: once, under one
name, whatever the command prints.
-}
standingFields :: ApplicationPinStanding -> [(Text, Value)]
standingFields standing =
    [("applicationPin", toJSON (renderApplicationPinStanding standing))]

{- | Run what follows a registry's resolution so that a refusal of it names the
application pin's standing as a success does: the command resolved a registry,
and every receipt it prints says so, once. The refusal keeps its mark of
having been reported.
-}
withStandingOnFailure :: ApplicationPinStanding -> IO a -> IO a
withStandingOnFailure standing act =
    act `catch` \(e :: SomeException) -> case fromException e of
        Just (CommandFailure outcome why fields) ->
            throwIO
                ( markedLike
                    (fst (reportedOf e))
                    ( toException
                        ( CommandFailure
                            outcome
                            why
                            ( filter ((/= "applicationPin") . fst) fields
                                <> standingFields standing
                            )
                        )
                    )
                )
        Nothing -> throwIO e

{- | A printed receipt with the standing of the application pin in it, once:
an object takes the field, any other value is left as it is.
-}
stampStanding :: ApplicationPinStanding -> Value -> Value
stampStanding standing = \case
    Object o ->
        Object
            ( foldr
                (\(k, v) -> KeyMap.insert (Key.fromText k) v)
                o
                (standingFields standing)
            )
    other -> other
