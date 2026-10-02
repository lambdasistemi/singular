{- |
Module      : InsertActive.Steps
Description : Boot the open registry, book and fold, and read the wallet
License     : Apache-2.0

The steps the story is made of, each an executed chain action or a read
of what the chain now holds:

* 'bootStory' publishes the state validator as a reference output
  BEFORE choosing a seed, boots the registry under the parameterless open
  application and the three witness policies, reads the boot state datum
  and publishes the reference outputs every fold resolves through;
* 'book' submits one certified @insertActive@ booking that names the
  wallet as its destination;
* 'foldOnce' folds the pending booking and commits the same leaf to the
  local trie mirror;
* 'activeHeldAt' reads, from the wallet's own outputs, the quantity held
  under the ACTIVE policy for one key.

Nothing here decides whether a run passed. The accepting and refusing
controls are in "InsertActive.Controls"; the observation is assembled in
"InsertActive.Observation".
-}
module InsertActive.Steps
    ( Story (..)
    , storyKey
    , walletDestination
    , bootStory
    , book
    , foldOnce
    , activeHeldAt
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
import Cardano.Ledger.Core (valueTxOutL)
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (TxId (..), TxIn)
import Cardano.Node.Client.E2E.Setup (genesisAddr)
import Cardano.Tx.Ledger (ConwayTx)

import InsertActive.Narration (die, hex, say)
import InsertActive.Options (StoryInputs (..))
import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint
    ( NamingCodes
    , loadRegistryCodesFromEnv
    )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger
    ( AssetName (..)
    , Coin (..)
    , ConwayEra
    , TokenId (..)
    )
import Singular.Registry.Node
    ( Capabilities (..)
    , SubmitResult (..)
    , funderSignKey
    , signTx
    , signedTx
    , submitSigned
    )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.Trie (Trie (..), TrieManager (..))
import Singular.Registry.Trie.PureManager (mkPureTrieManager)
import Singular.Registry.TxBuilder.Boot (bootTokenImpl)
import Singular.Registry.TxBuilder.Edges qualified as Edges
import Singular.Registry.TxBuilder.Internal
    ( cageAddrFromCfg
    , cagePolicyIdFromCfg
    , computeScriptHash
    , extractCageDatum
    , findStateUtxo
    , leafActive
    , policyIdFromPin
    , scriptFromBytes
    , scriptHashBytes
    , txInToRef
    )
import Singular.Registry.TxBuilder.Update (updateTokenWithDuties)
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainTokenState (..)
    , OnChainTxOutRef
    , edgeInsertActive
    )

-- | One booted registry and everything a fold in it needs.
data Story = Story
    { storyProvider :: Cage.Provider IO
    , storyWrites :: Capabilities
    -- ^ The signed-only write and the confirmation
    , storyTries :: TrieManager IO
    , storyCodes :: NamingCodes
    , storyConfig :: CageConfig
    , storyToken :: TokenId
    , storyTokenBytes :: ByteString
    -- ^ The registry token's raw name, for narration and the observation
    , storyBootState :: OnChainTokenState
    -- ^ The eight-field state datum the boot left on chain
    , storyRefs :: [(TxIn, TxOut ConwayEra)]
    -- ^ The published reference outputs every fold resolves through
    }

-- | The key the documented run books.
storyKey :: ByteString
storyKey = "insert-active-demo"

{- | The open story names a WALLET. 'Edges.edgeDestinationOf' would send
an @insertActive@ to the APPLICATION's script address, which is right
for naming and wrong here: @open.ak@ is a minting policy with no
spending arm, so a token routed there is locked forever.
-}
walletDestination :: (ByteString, ByteString)
walletDestination = (serialiseAddr genesisAddr, "")

{- | Boot the open registry in this node session and narrate its two
policies and its token.
-}
bootStory :: Capabilities -> StoryInputs -> IO Story
bootStory caps inputs = do
    let prov = capReads caps
        stateBytes = inputStateBytes inputs
    tm <- mkPureTrieManager
    _ <- Cage.withView prov (pure . Cage.viewProtocolParams)
    -- #177 A-003: publish the state validator as a reference output
    -- BEFORE the seed is chosen. The publication spends the wallet's
    -- largest ada-only output, which a seed picked first could be, and
    -- boot would then look for a UTxO the publication had spent.
    _ <-
        Edges.publishRefScript
            prov
            (submitWithGenesis caps)
            genesisAddr
            (scriptFromBytes "state" stateBytes)
    utxos <- Cage.withView prov (`Cage.viewUTxOsAt` genesisAddr)
    -- #177 A-003: never seed from the reference publication. Boot
    -- REFERENCES that output, and a transaction may not both spend and
    -- reference the same one.
    seedRef <- case filter (\(_, o) -> o ^. referenceScriptTxOutL == SNothing) utxos of
        [] ->
            die
                "the genesis wallet has no spendable UTxO to seed the registry with"
        ((txIn, _) : _) -> pure (txInToRef txIn)

    codes <- loadRegistryCodesFromEnv
    let cfg = cageCfg stateBytes (inputRequestBytes inputs) codes seedRef
    say
        ( "open application policy "
            <> T.unpack (hex (SBS.fromShort (cfgApplicationPolicy cfg)))
            <> " (parameters: "
            <> show (inputOpenParams inputs)
            <> ")"
        )
    say
        ( "active witness policy   "
            <> T.unpack (hex (SBS.fromShort (cfgActivePolicy cfg)))
        )

    unsignedBoot <-
        Cage.withView prov (\v -> bootTokenImpl cfg v genesisAddr)
    signedBoot <- submitWithGenesis caps unsignedBoot
    (tid, tidBytes) <- extractTokenId cfg signedBoot
    createTrie tm tid
    stateUtxos <-
        Cage.withView prov (`Cage.viewUTxOsAt` cageAddrFromCfg cfg Testnet)
    bootState <- case findStateUtxo (cagePolicyIdFromCfg cfg) tid stateUtxos of
        Just (_, out) -> case extractCageDatum out of
            Just (StateDatum s) -> pure s
            _ -> die "boot: the state UTxO carries no eight-field state datum"
        Nothing -> die "boot: no state UTxO carrying the registry policy token"
    say ("booted registry token 0x" <> T.unpack (hex tidBytes))

    refs <-
        Edges.publishCageRefs
            cfg
            codes
            prov
            (submitWithGenesis caps)
            genesisAddr
            tid
    pure
        Story
            { storyProvider = prov
            , storyWrites = caps
            , storyTries = tm
            , storyCodes = codes
            , storyConfig = cfg
            , storyToken = tid
            , storyTokenBytes = tidBytes
            , storyBootState = bootState
            , storyRefs = refs
            }

-- | Book one certified @insertActive@ of this key, delivering to the wallet.
book :: Story -> ByteString -> IO ()
book story key =
    void $
        Edges.bookEdgeTo
            (storyConfig story)
            (storyCodes story)
            (storyProvider story)
            (submitWithGenesis (storyWrites story))
            genesisAddr
            (storyToken story)
            key
            edgeInsertActive
            walletDestination

{- | Fold the pending booking and commit the key's active leaf to the
local mirror.

The mirroring is not bookkeeping. The speculative session inside
`updateTokenWithDuties` starts from the committed trie and is discarded,
so a caller that does not commit each landed fold re-proves the next one
against the BOOT state: fold 2 submits an empty proof and fails.
-}
foldOnce :: Story -> ByteString -> IO ConwayTx
foldOnce story key = do
    let tm = storyTries story
        tid = storyToken story
    tx <- Cage.withView (storyProvider story) $ \v -> do
        ctx <-
            Edges.registryContextFor
                (storyConfig story)
                (storyCodes story)
                v
                (storyRefs story)
        updateTokenWithDuties
            (storyConfig story)
            v
            tm
            tid
            genesisAddr
            ctx
    signed <- submitWithGenesis (storyWrites story) tx
    withTrie tm tid $ \t -> do
        _ <- insert t key leafActive
        pure ()
    pure signed

-- | Exactly the quantity held under the ACTIVE policy at this key.
activeHeldAt :: Story -> ByteString -> IO Integer
activeHeldAt story key = do
    walletUtxos <-
        Cage.withView (storyProvider story) (`Cage.viewUTxOsAt` genesisAddr)
    let policy = policyIdFromPin (cfgActivePolicy (storyConfig story))
    pure $
        sum
            [ q
            | (_, out) <- walletUtxos
            , let MaryValue _ (MultiAsset ma) = out ^. valueTxOutL
            , (p, names) <- Map.toList ma
            , p == policy
            , (AssetName n, q) <- Map.toList names
            , SBS.fromShort n == key
            ]

-- | Sign with the devnet genesis key, submit, wait.
submitWithGenesis :: Capabilities -> ConwayTx -> IO ConwayTx
submitWithGenesis caps unsigned = do
    let signed = signTx funderSignKey unsigned
    result <- submitSigned (capSubmit caps) signed
    case result of
        Submitted _ -> pure ()
        Rejected reason -> die ("tx rejected: " <> show reason)
    capConfirm caps (signedTx signed)
    pure (signedTx signed)

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
