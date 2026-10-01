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
stale or altered mirror; it refuses and says so.
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

      -- * The mirror
    , Mirror (..)
    , openMirror
    , saveOpenMirror
    , mirrorRoot

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
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Lens.Micro ((^.))

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.Tx.Out (TxOut, referenceScriptTxOutL)
import Cardano.Ledger.BaseTypes (Network (Testnet), StrictMaybe (..))
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.TxIn (TxIn)

import MPF.Backend.Pure (MPFInMemoryDB)

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
import Singular.CLI.Receipt (OutcomeClass, outcomeName)
import Singular.CLI.Receipt qualified as Receipt
import Singular.CLI.Registry
    ( RegistryConfig (..)
    , Release (..)
    , checkPins
    , configPath
    , loadRelease
    , partsOf
    , pinsOf
    , readConfig
    , renderIdentityError
    )
import Singular.CLI.Session (failWith)
import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint (NamingCodes (..))
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Config.Application (cageConfigForApplication)
import Singular.Registry.Deployment
    ( Attached (..)
    , Deployment (..)
    , attach
    , loadMirror
    , mirrorPathFor
    , parseOutRef
    , renderOutRef
    , saveMirror
    )
import Singular.Registry.Ledger
    ( AssetName (..)
    , ConwayEra
    , Root (..)
    , TokenId (..)
    )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.Trie (Trie (..), TrieManager (..))
import Singular.Registry.Trie.PureManager (mkPureTrieManagerFrom)
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
    { liveSaved :: Saved
    , liveRefs :: [(TxIn, TxOut ConwayEra)]
    , liveState :: (TxIn, TxOut ConwayEra)
    }

-- | Resolve the recorded references and the current state output.
attachLive :: Cage.View IO -> Saved -> IO Live
attachLive view s = do
    att <-
        attach view (confDeployment (savedConfig s)) (partsOf (savedCfg s))
    pure
        Live
            { liveSaved = s
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
    :: Cage.View IO -> Saved -> IO [(TxIn, TxOut ConwayEra)]
liveOutputs view s = Cage.viewUTxOsAt view (applicationAddr s)

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

-- | The saved mirror, opened as a trie manager for this registry.
data Mirror = Mirror
    { mirrorTries :: TrieManager IO
    , mirrorDump :: IO (Map.Map TokenId MPFInMemoryDB)
    }

{- | The saved mirror of an attached registry. Missing proof material is
refused @proof-missing@ — no file, or no trie for this registry's token —
and never replaced by a new empty trie: only @create@ initialises one.
-}
openMirror :: Saved -> IO Mirror
openMirror s = do
    let path = mirrorPathFor (configPath (savedDir s))
    there <- doesFileExist path
    if there
        then pure ()
        else failWith Receipt.ProofMissing ("no saved mirror at " <> path)
    saved <- loadMirror (configPath (savedDir s))
    if Map.member (savedToken s) saved
        then pure ()
        else
            failWith
                Receipt.ProofMissing
                "the saved mirror holds no trie for this registry's token"
    (tm, dump) <- mkPureTrieManagerFrom saved
    pure (Mirror tm dump)

saveOpenMirror :: Saved -> Mirror -> IO ()
saveOpenMirror s m = mirrorDump m >>= saveMirror (configPath (savedDir s))

mirrorRoot :: Saved -> Mirror -> IO ByteString
mirrorRoot s m = do
    Root r <- withTrie (mirrorTries m) (savedToken s) getRoot
    pure r

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
