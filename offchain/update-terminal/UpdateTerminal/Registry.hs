{-# LANGUAGE LambdaCase #-}

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
* 'bookInsert' books one registration of a key through the shared
  registration booking: the open application's registration arm mints the
  application tag, the request policy mints the trie-ready tag, and the
  request carries the registry's cost, the tip and the carrier, delivering
  to the wallet with no datum;
* 'bookRetire' books one termination of a key through the shared
  termination booking: the wallet's output that holds the key's active
  token is the custody, the holder's signature is its spending condition,
  and the whole custody value enters the request, which mints the
  trie-ready tag alone;
* 'foldAndMirror' folds the pending booking and walks the same edge in
  the local trie mirror;
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
    , bookInsert
    , bookRetire
    , probeRetire
    , foldAndMirror
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
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , getMinCoinTxOut
    , mkBasicTxOut
    , referenceScriptTxOutL
    )
import Cardano.Ledger.BaseTypes
    ( Network (Testnet)
    , StrictMaybe (SNothing)
    )
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (TxId (..), TxIn)
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint
    ( NamingCodes (..)
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
    , SlotNo (..)
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
    , policyIdFromPin
    , requestPolicyPin
    , scriptFromBytes
    , scriptHashBytes
    , txInToRef
    , walkEdge
    )
import Singular.Registry.TxBuilder.RegistrationBooking
    ( RegistrationBooking (..)
    , bookRegistrationImpl
    , registrationWindow
    )
import Singular.Registry.TxBuilder.Update (updateTokenWithDuties)
import Singular.Registry.TxBuilder.WalletTermination
    ( TerminationProbe (..)
    , probeWalletTermination
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
    cageRefs <-
        Edges.publishCageRefs
            cfg
            (sessCodes s)
            prov
            (submitWithWallet wallet submit)
            address
            tid
    -- The fold burns each registration's application tag, so the open
    -- application's script is published beside the cage's, as a deployment
    -- publishes the script its registry pins.
    applicationRef <-
        Edges.publishRefScript
            prov
            (submitWithWallet wallet submit)
            address
            (scriptFromBytes "application" (ncApplication (sessCodes s)))
    let refs = cageRefs <> [applicationRef]
    say (label <> ": booted registry token 0x" <> T.unpack (hex tidBytes))
    pure (Registry s cfg tid refs signedBoot tidBytes)

{- | The registry's state output, which every booking references and no
booking spends.
-}
stateOutputOf
    :: Registry -> Provider.Session NoWitness IO -> IO TxIn
stateOutputOf reg v = do
    utxos <- Cage.outputsAt v (cageAddrFromCfg (regCfg reg) Testnet)
    case findStateUtxo (cagePolicyIdFromCfg (regCfg reg)) (regTid reg) utxos of
        Just (txIn, _) -> pure txIn
        Nothing -> die "no state UTxO carrying the registry policy token"

{- | Book one registration of this key and land it: the key's token is
delivered to the wallet, with no datum, once the registration is folded. The
request holds the registry's cost, the tip and the carrier the delivered
output needs to meet the ledger's minimum.
-}
bookInsert :: Registry -> ByteString -> IO ConwayTx
bookInsert reg key = do
    let s = regSession reg
        cfg = regCfg reg
        wallet = sessWallet s
        payer = walletAddr wallet
    unsigned <- Cage.withLatest (sessProvider s) $ \v -> do
        stateRef <- stateOutputOf reg v
        pp <- Cage.parameters v
        (lower, upper) <- registrationWindow cfg v
        let delivered =
                mkBasicTxOut
                    payer
                    ( MaryValue
                        (Coin deliveredLovelace)
                        ( MultiAsset
                            ( Map.singleton
                                (policyIdFromPin (cfgActivePolicy cfg))
                                (Map.singleton (AssetName (SBS.toShort key)) 1)
                            )
                        )
                    )
            Coin least = getMinCoinTxOut pp delivered
        bookRegistrationImpl
            cfg
            v
            (regTid reg)
            stateRef
            RegistrationBooking
                { rbKey = key
                , rbRefundAddress = payer
                , rbDestination = serialiseAddr payer
                , rbDatum = Nothing
                , rbDeclaredTip = defaultTip cfg
                , rbCarrier = Coin (max least deliveredLovelace)
                , rbNonce = toInteger (unSlotNo upper)
                , rbLower = lower
                , rbUpper = upper
                , rbApplicationScript = ncApplication (sessCodes s)
                , rbApplicationRedeemer = Nothing
                , rbRequiredSigners = []
                }
            payer
    submitWithWallet wallet (sessWrites s) unsigned
  where
    deliveredLovelace = 2_000_000

{- | Probe the wallet for the custody of this key and, when it is found, book
its termination and land it: the wallet's output that holds the key's one
active token is the custody, its holder's signature is the spending
condition, the whole custody value enters the request and the transaction
mints the request's trie-ready tag alone. The probe is
'probeWalletTermination': it either books or reports that the wallet holds no
custody of the key.
-}
probeRetire :: Registry -> ByteString -> IO TerminationProbe
probeRetire reg key = do
    let s = regSession reg
        wallet = sessWallet s
    probed <-
        Cage.withLatest (sessProvider s) $ \v ->
            probeWalletTermination
                (regCfg reg)
                v
                (regTid reg)
                (walletAddr wallet)
                (Coin addedLovelace)
                key
    case probed of
        Booked unsigned -> Booked <$> submitWithWallet wallet (sessWrites s) unsigned
        NoCustodyToBook why -> pure (NoCustodyToBook why)
  where
    -- What the requester pays in beside the custody so that the request
    -- output meets the ledger's minimum with its datum and its two tags.
    addedLovelace = 2_000_000

{- | Book one termination of this key and land it. A key whose token no wallet
output holds has no custody to spend, and the story fails.
-}
bookRetire :: Registry -> ByteString -> IO ConwayTx
bookRetire reg key =
    probeRetire reg key >>= \case
        Booked tx -> pure tx
        NoCustodyToBook why -> ioError (userError why)

{- | Fold the pending booking and walk the same edge in the mirror.

The mirroring is not bookkeeping. The speculative session inside
`updateTokenWithDuties` starts from the committed trie and is discarded,
so a caller that does not commit each landed fold re-proves the next one
against the BOOT state: the retirement would submit a proof for a root
the chain left behind.
-}
foldAndMirror :: Registry -> ByteString -> Edge -> IO ConwayTx
foldAndMirror reg key op = do
    tx <- foldWith reg
    -- #183: the edge names the leaf bytes the local mirror must
    -- write, exactly as it names the ones the cage walks.
    withTrie (sessTries (regSession reg)) (regTid reg) $ \t ->
        void (walkEdge t key op)
    pure tx

foldWith :: Registry -> IO ConwayTx
foldWith reg = do
    let s = regSession reg
    tx <- Cage.withLatest (sessProvider s) $ \v -> do
        ctx <-
            Edges.registryContextFor
                (regCfg reg)
                (sessCodes s)
                v
                (regRefs reg)
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
            , -- The scenario's own registration economics, stated here and
              -- pinned in the state it boots.
              defaultRegistrationCost = Coin 2_000_000
            , defaultBookingWidth = 10_000
            , cfgApplicationPolicy = appPin
            , cfgActivePolicy = activePin
            , cfgAbsentPolicy = absentPin
            , cfgTerminalPolicy = terminalPin
            , -- The request validator applied to this registry's state hash
              -- and token, by the one shared derivation.
              cfgRequestPolicy = requestPolicyPin stateBytes requestBytes seed
            , cfgConsumerScript = SBS.empty
            , network = Testnet
            }
