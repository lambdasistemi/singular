{- |
Module      : UpdateTerminal.Registry
Description : One node session, the registries booted in it, and their folds
License     : Apache-2.0

The story needs more than one registry in one node session, because a
refused fold never consumes the request that caused it: that request
stays pending, the next fold picks it up, and a second refusal would be
evidence about the first. Each refusal therefore gets a registry of its
own, with its own accepting control folded in it before the bad one.

* 'openSession' publishes the state validator as a reference output
  BEFORE any seed is chosen and loads the witness codes;
* 'bootRegistry' boots one registry from an ada-only output that is not
  that publication, and publishes its reference outputs;
* 'book' submits one certified booking of an edge at a key, delivering
  to the wallet;
* 'foldAndMirror' folds the pending booking and walks the same edge in
  the local trie mirror; 'foldInadmissible' folds WITHOUT mirroring and
  lets the builder construct a fold it can see the cage will reject, so
  a refusal leg reaches the chain and records the cage's reason rather
  than the builder's;
* 'rootNow' is the mirror's root, 'committedRoot' the one on chain.
-}
module UpdateTerminal.Registry
    ( Session (sessProvider, sessWallet)
    , openSession
    , Registry (..)
    , bootRegistry
    , insertOp
    , retireOp
    , walletDestination
    , book
    , foldAndMirror
    , foldInadmissible
    , rootNow
    , committedRoot
    , bootStateOf
    , txIdOf
    ) where

import Control.Monad (void)
import Data.ByteString (ByteString)
import Data.ByteString.Short (fromShort)
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Lens.Micro ((^.))

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address (serialiseAddr)
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body (mintTxBodyL)
import Cardano.Ledger.Api.Tx.Out (TxOut, referenceScriptTxOutL)
import Cardano.Ledger.BaseTypes
    ( Network (Testnet)
    , StrictMaybe (SNothing)
    )
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.Mary.Value (MultiAsset (..))
import Cardano.Ledger.TxIn (TxId (..), TxIn)
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint
    ( NamingCodes
    , loadRegistryCodesFromEnv
    )
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger
    ( AssetName (..)
    , Coin (..)
    , ConwayEra
    , Root (..)
    , TokenId (..)
    )
import Singular.Registry.LedgerProvider qualified as Provider
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.Terminal (submitWithWallet)
import Singular.Registry.Trie (Trie (..), TrieManager (..))
import Singular.Registry.Trie.Pure ()
import Singular.Registry.Trie.PureManager (mkPureTrieManager)
import Singular.Registry.TxBuilder.Boot (bootTokenImpl)
import Singular.Registry.TxBuilder.Edges qualified as Edges
import Singular.Registry.TxBuilder.Internal
    ( cageAddrFromCfg
    , cagePolicyIdFromCfg
    , computeScriptHash
    , extractCageDatum
    , findStateUtxo
    , scriptFromBytes
    , scriptHashBytes
    , txInToRef
    , walkEdge
    )
import Singular.Registry.TxBuilder.Update
    ( RegistryContext (..)
    , updateTokenWithDuties
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , Edge
    , OnChainRoot (..)
    , OnChainTokenState (..)
    , OnChainTxOutRef
    , RequestDestination
    , edgeInsertActive
    , edgeUpdateTerminal
    )
import Singular.Registry.Wallet (Wallet (..))
import UpdateTerminal.Narration (die, hex, say)
import UpdateTerminal.Options (StoryInputs (..))

-- | The node session every registry of one run shares, and one wallet.
data Session = Session
    { sessProvider
        :: (Provider.Network, Provider.LedgerProvider NoWitness IO)
    , sessWrites :: Capabilities NoWitness IO
    , sessWallet :: Wallet
    -- ^ The signed-only write and the confirmation
    , sessTries :: TrieManager IO
    , sessCodes :: NamingCodes
    , sessInputs :: StoryInputs
    }

{- | One booted registry: its config, its token, the reference outputs
its folds resolve through, and the boot transaction itself.
-}
data Registry = Registry
    { regSession :: Session
    , regCfg :: CageConfig
    , regTid :: TokenId
    , regRefs :: [(TxIn, TxOut ConwayEra)]
    , regBootTx :: ConwayTx
    , regTidBytes :: ByteString
    }

-- | The two supported transitions this story walks (#183).
insertOp, retireOp :: Edge
insertOp = edgeInsertActive
retireOp = edgeUpdateTerminal

{- | The open story names a WALLET. 'Edges.edgeDestinationOf' would send
the active token to the APPLICATION's script address, which is right for
naming and wrong here: @open.ak@ is a minting policy with no spending
arm, so a token routed there is locked forever and could never be
retired.
-}
walletDestination :: Registry -> RequestDestination
walletDestination reg = (serialiseAddr (walletAddr (sessWallet (regSession reg))), Nothing)

-- | Start the run's shared state over these capabilities.
openSession
    :: Wallet -> Capabilities NoWitness IO -> StoryInputs -> IO Session
openSession wallet caps inputs = do
    let prov = capReads caps
        address = walletAddr wallet
    tm <- mkPureTrieManager
    _ <- Cage.withLatest prov Cage.parameters
    -- #177 A-003: publish the state validator as a reference output
    -- BEFORE any seed is chosen. The publication spends the wallet's
    -- largest ada-only output, which a seed picked first could be, and
    -- boot would then look for a UTxO the publication had spent.
    _ <-
        Edges.publishRefScript
            prov
            (submitWithWallet wallet caps)
            address
            (scriptFromBytes "state" (inputStateBytes inputs))
    codes <- loadRegistryCodesFromEnv
    pure
        Session
            { sessProvider = prov
            , sessWrites = caps
            , sessWallet = wallet
            , sessTries = tm
            , sessCodes = codes
            , sessInputs = inputs
            }

-- | Boot one registry and publish its references; narrated with a label.
bootRegistry :: Session -> String -> IO Registry
bootRegistry s label = do
    let prov = sessProvider s
        submit = sessWrites s
        wallet = sessWallet s
        address = walletAddr wallet
        inputs = sessInputs s
    utxos <- Cage.withLatest prov (`Cage.outputsAt` address)
    -- Never seed from the reference publication: boot REFERENCES
    -- that output and may not also spend it.
    seedRef <- case filter (\(_, o) -> o ^. referenceScriptTxOutL == SNothing) utxos of
        [] ->
            die "the genesis wallet has no spendable UTxO to seed a registry with"
        ((txIn, _) : _) -> pure (txInToRef txIn)
    let cfg =
            cageCfg
                (inputStateBytes inputs)
                (inputRequestBytes inputs)
                (sessCodes s)
                seedRef
    unsignedBoot <-
        Cage.withLatest prov (\v -> bootTokenImpl cfg v address)
    signedBoot <- submitWithWallet wallet submit unsignedBoot
    (tid, tidBytes) <- extractTokenId cfg signedBoot
    createTrie (sessTries s) tid
    refs <-
        Edges.publishCageRefs
            cfg
            (sessCodes s)
            prov
            (submitWithWallet wallet submit)
            address
            tid
    say (label <> ": booted registry token 0x" <> T.unpack (hex tidBytes))
    pure (Registry s cfg tid refs signedBoot tidBytes)

-- | Book one certified edge at this key, delivering to the wallet.
book :: Registry -> ByteString -> Edge -> IO ()
book reg key op =
    void $
        Edges.bookEdgeTo
            (regCfg reg)
            (sessCodes (regSession reg))
            (sessProvider (regSession reg))
            ( submitWithWallet
                (sessWallet (regSession reg))
                (sessWrites (regSession reg))
            )
            (walletAddr (sessWallet (regSession reg)))
            (regTid reg)
            key
            op
            (walletDestination reg)

{- | Fold the pending booking and walk the same edge in the mirror.

The mirroring is not bookkeeping. The speculative session inside
`updateTokenWithDuties` starts from the committed trie and is discarded,
so a caller that does not commit each landed fold re-proves the next one
against the BOOT state: the retirement would submit a proof for a root
the chain left behind.
-}
foldAndMirror :: Registry -> ByteString -> Edge -> IO ConwayTx
foldAndMirror reg key op = do
    tx <- foldWith reg False
    -- #183: the edge names the leaf bytes the local mirror must
    -- write, exactly as it names the ones the cage walks.
    withTrie (sessTries (regSession reg)) (regTid reg) $ \t ->
        void (walkEdge t key op)
    pure tx

{- | Fold the pending booking even though the builder can see the cage
will reject it, and do not mirror it.

An honest builder refuses to construct a fold it can see the cage will
reject, which is right for the story and wrong for a row whose whole
point is the cage's own reason: without this the observation would
record the BUILDER's message instead.
-}
foldInadmissible :: Registry -> IO ConwayTx
foldInadmissible reg = foldWith reg True

foldWith :: Registry -> Bool -> IO ConwayTx
foldWith reg inadmissible = do
    let s = regSession reg
    tx <- Cage.withLatest (sessProvider s) $ \v -> do
        ctx0 <-
            Edges.registryContextFor
                (regCfg reg)
                (sessCodes s)
                v
                (regRefs reg)
        let ctx = ctx0{rcAllowInadmissible = inadmissible}
        updateTokenWithDuties
            (regCfg reg)
            v
            (sessTries s)
            (regTid reg)
            (walletAddr (sessWallet s))
            ctx
    submitWithWallet (sessWallet s) (sessWrites s) tx

-- | The local mirror's root for this registry.
rootNow :: Registry -> IO Root
rootNow reg = withTrie (sessTries (regSession reg)) (regTid reg) getRoot

{- | The registry's own committed root, read off the state UTxO on
chain. This is how a LEAF is observed: `Trie.lookup` answers with the
key's hash rather than its value and cannot see one, while a trie with a
different leaf at a key has a different root.
-}
committedRoot :: Registry -> IO ByteString
committedRoot reg =
    unOnChainRoot . stateRoot
        <$> readState
            reg
            "the state UTxO carries no state datum"
            "no state UTxO carrying the registry policy token"

-- | The eight-field state datum as the boot left it.
bootStateOf :: Registry -> IO OnChainTokenState
bootStateOf reg =
    readState
        reg
        "boot: the state UTxO carries no eight-field state datum"
        "boot: no state UTxO carrying the registry policy token"

readState :: Registry -> String -> String -> IO OnChainTokenState
readState reg notState missing = do
    let cfg = regCfg reg
    utxos <-
        Cage.withLatest
            (sessProvider (regSession reg))
            (`Cage.outputsAt` cageAddrFromCfg cfg Testnet)
    case findStateUtxo (cagePolicyIdFromCfg cfg) (regTid reg) utxos of
        Just (_, out) -> case extractCageDatum out of
            Just (StateDatum st) -> pure st
            _ -> die notState
        Nothing -> die missing

{- | The registry token this boot minted, and its raw name bytes for
narration.
-}
extractTokenId :: CageConfig -> ConwayTx -> IO (TokenId, ByteString)
extractTokenId cfg tx =
    let MultiAsset ma = tx ^. bodyTxL . mintTxBodyL
        assets = Map.toList (ma Map.! cagePolicyIdFromCfg cfg)
    in  case assets of
            [(AssetName an, _)] -> pure (TokenId (AssetName an), fromShort an)
            _ -> die ("boot: unexpected mint assets: " <> show (length assets))

-- | A transaction's own id, as the observation records it.
txIdOf :: ConwayTx -> ByteString
txIdOf tx =
    let TxId h = txIdTx tx
    in  hashToBytes (extractHash h)

cageCfg
    :: SBS.ShortByteString
    -> SBS.ShortByteString
    -> NamingCodes
    -> OnChainTxOutRef
    -> CageConfig
cageCfg stateBytes requestBytes codes seed =
    let stateHash = computeScriptHash stateBytes
        registryId = scriptHashBytes stateHash <> deriveAssetName seed
        (appPin, absentPin, activePin, terminalPin) =
            Edges.namingPins codes registryId
    in  CageConfig
            { cageScriptBytes = stateBytes
            , requestScriptBytes = requestBytes
            , cfgScriptHash = stateHash
            , cageSeed = seed
            , defaultProcessTime = 30_000
            , defaultRetractTime = 30_000
            , defaultTip = Coin 1_000_000
            , cfgApplicationPolicy = appPin
            , cfgActivePolicy = activePin
            , cfgAbsentPolicy = absentPin
            , cfgTerminalPolicy = terminalPin
            , cfgConsumerScript = SBS.empty
            , network = Testnet
            }
