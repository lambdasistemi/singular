{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.Live
Description : A saved registry attached to the live chain
License     : Apache-2.0

What every command after @create@ does first: read the saved identity,
derive every pin again from this release and the recorded seed
("Singular.Registry.Config.Application"), refuse a saved identity whose
pins differ, and — with a node in hand — resolve the recorded reference
outputs and the registry's current state output, and compare the local
mirror's root with the root the ledger holds. A command never repairs a
stale or altered mirror; it refuses and says so. Applying a journalled
edge the chain evidences is reconciliation ("Singular.CLI.Reconcile"),
not repair.
-}
module Singular.CLI.Live
    ( -- * The saved registry
      Saved (..)
    , loadSaved

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

      -- * The mirror
    , Mirror
    , mirrorStore
    , openMirror
    , mirrorRoot
    , selectMirror
    , requireMirrorSelection
    , withMirror
    , selectedMirrorRoot
    , mirrorLeaf
    , acceptMirrorFold
    , recoverMirrorFold
    , rewindMirrorTo
    , savedIdentity
    , newStatePoint
    , failTrie

      -- * Receipts
    , receipt
    , txInText
    , applied
    ) where

import Control.Monad (when)
import Data.Aeson (Value, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short qualified as SBS
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((^.))

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.Tx (txIdTx)
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

import Cardano.Tx.Ledger (ConwayTx)

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
import Singular.CLI.Proof qualified as Proof
import Singular.CLI.Receipt (OutcomeClass, outcomeName)
import Singular.CLI.Receipt qualified as Receipt
import Singular.CLI.Registry
    ( RegistryConfig (..)
    , Release (..)
    , checkPins
    , configPath
    , hexT
    , loadRelease
    , partsOf
    , pinsOf
    , readConfig
    , renderIdentityError
    )
import Singular.CLI.Session (failWith, failWithFields)
import Singular.CLI.TrieHistory (historyAtRoot, readTrieHistory)
import Singular.CLI.TrieTrace (observeTrie)
import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint (NamingCodes (..))
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Config.Application (cageConfigForApplication)
import Singular.Registry.Deployment
    ( Attached (..)
    , Deployment (..)
    , attach
    , mirrorPathFor
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
import Singular.Registry.TrieState qualified as TS
import Singular.Registry.TrieState.Mirror qualified as TrieMirror
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
import System.Directory (doesFileExist)

-- | A registry directory read and checked against this release.
data Saved = Saved
    { savedDir :: FilePath
    , savedConfig :: RegistryConfig
    , savedCfg :: CageConfig
    , savedCodes :: NamingCodes
    -- ^ As the registry pins them: the application applied
    , savedToken :: TokenId
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

{- | The durable store and one independently observed caller selection.
Commands receive snapshots, never the underlying nodes or TrieManager.
-}
data Mirror = Mirror
    { mirrorStore :: TrieMirror.MirrorStore
    , mirrorSelected
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

openMirror :: Saved -> IO Mirror
openMirror saved = do
    let path = mirrorPathFor (configPath (savedDir saved))
    there <- doesFileExist path
    if there
        then pure ()
        else failWith Receipt.ProofMissing ("no saved mirror at " <> path)
    store <-
        TrieMirror.openStoredMirror
            (configPath (savedDir saved))
            (savedIdentity saved)
            >>= either
                ( const
                    ( failWith
                        Receipt.ProofMissing
                        "the saved mirror holds no trie for this registry's token"
                    )
                )
                pure
    Mirror store <$> newIORef (Left (noSelection saved))

-- Only adapter/recovery setup uses this stored root before it has a current
-- observed selection. Ordinary command reads use selectedMirrorRoot instead.
mirrorRoot :: Saved -> Mirror -> IO ByteString
mirrorRoot _ mirror = do
    Root root <-
        TrieMirror.storedRoot (mirrorStore mirror) >>= either failTrie pure
    pure root

selectMirror
    :: Saved -> Live -> Mirror -> IO (Either TS.TrieFailure ())
selectMirror saved live mirror = do
    let point = newStatePoint (liveSession live) (fst (liveState live))
    case observedRoot live of
        Left _ -> refuse (noSelection saved)
        Right root -> do
            let chosen = TS.TrieSelection (savedIdentity saved) point (Root root)
            history <-
                readTrieHistory
                    (savedDir saved)
                    (TS.pointSession point)
                    (savedIdentity saved)
            case history of
                Left why -> refuse why
                Right (create, events) -> do
                    cap <-
                        TrieMirror.mirrorTrieState
                            (mirrorStore mirror)
                            chosen
                            create
                            events
                            observeTrie
                    writeIORef (mirrorSelected mirror) (Right (cap, chosen))
                    TS.withTrieState cap chosen (const (pure ()))
  where
    refuse why = do
        writeIORef (mirrorSelected mirror) (Left why)
        pure (Left why)

requireMirrorSelection :: Saved -> Live -> Mirror -> IO ()
requireMirrorSelection saved live mirror = selectMirror saved live mirror >>= either failTrie pure

withMirror :: Mirror -> (TS.TrieSnapshot IO -> IO a) -> IO a
withMirror mirror use = do
    context <- readIORef (mirrorSelected mirror)
    case context of
        Left why -> failTrie why
        Right (cap, chosen) -> TS.withTrieState cap chosen use >>= either failTrie pure

selectedMirrorRoot :: Mirror -> IO ByteString
selectedMirrorRoot mirror = withMirror mirror (pure . unRoot . TS.trieRoot)

-- Preserve the existing leaf/root error vocabulary at the receipt boundary.
mirrorLeaf
    :: Mirror
    -> ByteString
    -> ByteString
    -> IO (Either Proof.AuthError TS.Leaf)
mirrorLeaf mirror key observed = do
    context <- readIORef (mirrorSelected mirror)
    result <- case context of
        Left why -> pure (Left why)
        Right (cap, chosen) ->
            fmap
                (>>= id)
                (TS.withTrieState cap chosen (`TS.leafAt` key))
    case result of
        Right leaf -> pure (Right leaf)
        Left why@TS.RootDoesNotChain{} -> do
            Root local <-
                TrieMirror.storedRoot (mirrorStore mirror) >>= either failTrie pure
            if local /= observed
                then pure (Left (Proof.RootMismatch local observed))
                else pure (Left (Proof.TrieRefusal why))
        Left TS.MissingProof{} -> pure (Left (Proof.ProofInconsistent key))
        Left why -> pure (Left (Proof.TrieRefusal why))

acceptMirrorFold
    :: Mirror
    -> ByteString
    -> Integer
    -> ByteString
    -> ByteString
    -> ConwayTx
    -> IO ()
acceptMirrorFold mirror key edge beforeRoot afterRoot tx = do
    context <- readIORef (mirrorSelected mirror)
    case context of
        Left why -> failTrie why
        Right (cap, chosen) -> do
            event@(TS.ObservedFold from after _) <-
                either
                    failTrie
                    pure
                    ( TrieMirror.checkedFoldRecord
                        (TS.pointSession (TS.trieSelectionPoint chosen))
                        (TS.trieSelectionIdentity chosen)
                        (Root beforeRoot)
                        (Root afterRoot)
                        ((key, edge) :| [])
                        tx
                    )
            when (from /= chosen) $
                failTrie
                    ( TS.StaleState
                        (TS.trieSelectionIdentity chosen)
                        (Just (txIdTx tx))
                        (TS.StaleSelection from chosen)
                    )
            TS.acceptObservedFold cap event >>= either failTrie pure
            writeIORef (mirrorSelected mirror) (Right (cap, after))

-- Recovery has independently established inclusion. Its before-output is
-- decoded from the actual bound signed body's Modify input, not invented.
recoverMirrorFold
    :: Cage.Session Cage.NoWitness IO
    -> Saved
    -> Mirror
    -> ByteString
    -> Integer
    -> ByteString
    -> ByteString
    -> ConwayTx
    -> IO ()
recoverMirrorFold session saved mirror key edge beforeRoot afterRoot tx = do
    let Cage.SessionId label = Cage.sessionId session
        sid = TS.SessionId label
    event@(TS.ObservedFold from after _) <-
        either
            failTrie
            pure
            ( TrieMirror.checkedFoldRecord
                sid
                (savedIdentity saved)
                (Root beforeRoot)
                (Root afterRoot)
                ((key, edge) :| [])
                tx
            )
    (create, events) <-
        readTrieHistory (savedDir saved) sid (savedIdentity saved)
            >>= either failTrie pure
    cap <-
        TrieMirror.mirrorTrieState
            (mirrorStore mirror)
            from
            create
            (historyAtRoot (Root beforeRoot) events)
            observeTrie
    TS.acceptObservedFold cap event >>= either failTrie pure
    writeIORef (mirrorSelected mirror) (Right (cap, after))

rewindMirrorTo
    :: Cage.Session Cage.NoWitness IO
    -> Saved
    -> Mirror
    -> ByteString
    -> IO ()
rewindMirrorTo session saved mirror target = do
    -- The prefix supplies actual historical output references. A fresh live
    -- selection is required later, before any command can read a snapshot.
    let Cage.SessionId label = Cage.sessionId session
        sid = TS.SessionId label
    (create@(TS.CreateRecord _ output), events) <-
        readTrieHistory (savedDir saved) sid (savedIdentity saved)
            >>= either failTrie pure
    let kept = historyAtRoot (Root target) events
        historicalPoint = case reverse kept of
            TS.ObservedFold _ to _ : _ -> TS.trieSelectionPoint to
            [] -> TS.StatePoint sid TS.Unbound output
        chosen =
            TS.TrieSelection (savedIdentity saved) historicalPoint (Root target)
    TrieMirror.replaceFromHistory (mirrorStore mirror) chosen create kept
        >>= either failTrie pure
    writeIORef (mirrorSelected mirror) (Left (noSelection saved))

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
