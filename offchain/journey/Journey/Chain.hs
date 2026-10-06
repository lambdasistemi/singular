{- |
Module      : Journey.Chain
Description : The journey's wallet, registry configuration and chain reads
License     : Apache-2.0

Shared plumbing, the same code path as the end-to-end suite: the funding
wallet and its key, the registry configuration for one boot seed, the
token a boot minted, signed submission that waits for confirmation, and
'readChainState' — the state datum read straight from the chain, the
only comparison target every verification in the journey uses.
-}
module Journey.Chain
    ( cageCfg
    , extractTokenId
    , readChainState
    ) where

import Data.ByteString (ByteString)
import Data.ByteString.Short (fromShort)
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Lens.Micro ((^.))

import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body (mintTxBodyL)
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Mary.Value (MultiAsset (..))
import Cardano.Tx.Ledger (ConwayTx)

import Journey.Narration (failWith)
import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint (NamingCodes)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger
    ( AssetName (..)
    , Coin (..)
    , TokenId (..)
    )
import Singular.Registry.LedgerProvider qualified as Provider
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.TxBuilder.Edges qualified as Edges
import Singular.Registry.TxBuilder.Internal
    ( cageAddrFromCfg
    , cagePolicyIdFromCfg
    , computeScriptHash
    , extractCageDatum
    , findStateUtxo
    , scriptHashBytes
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainTokenState (..)
    , OnChainTxOutRef
    )

{- | Build a 'CageConfig' from state and request script bytes
plus the boot seed 'OnChainTxOutRef', exactly as the end-to-end
suite does. The state validator takes no parameters: its raw
bytes are hashed as they are, so the configuration's state
hash is the blueprint code's own hash.
-}
cageCfg
    :: SBS.ShortByteString
    -> SBS.ShortByteString
    -> NamingCodes
    -> OnChainTxOutRef
    -> CageConfig
cageCfg stateBytes requestBytes codes seed =
    let appliedStateBytes = stateBytes
        stateHash = computeScriptHash appliedStateBytes
        registryId = scriptHashBytes stateHash <> deriveAssetName seed
        (appPin, absentPin, activePin, terminalPin) =
            Edges.namingPins codes registryId
    in  CageConfig
            { cageScriptBytes = appliedStateBytes
            , requestScriptBytes = requestBytes
            , cfgScriptHash = stateHash
            , cageSeed = seed
            , defaultProcessTime = 30_000
            , defaultRetractTime = 30_000
            , defaultTip = Coin 1_000_000
            , -- #157 genesis-policy-pins: the four pins for THIS registry identity,
              -- derived from the registry blueprint's own compiled code
              -- (`loadRegistryCodesFromEnv`) — the open application
              -- validator's own hash, and `witness(kind, registry)` at kinds
              -- 0, 1 and 2. The journey
              -- folds a real tree edge, so it needs all four (A-014).
              cfgApplicationPolicy = appPin
            , cfgActivePolicy = activePin
            , cfgAbsentPolicy = absentPin
            , cfgTerminalPolicy = terminalPin
            , cfgConsumerScript = SBS.empty
            , network = Testnet
            }

{- | Extract the 'TokenId' from a boot transaction's mint
field, with the raw asset-name bytes for narration.
-}
extractTokenId :: CageConfig -> ConwayTx -> IO (TokenId, ByteString)
extractTokenId cfg tx =
    let MultiAsset ma =
            tx ^. bodyTxL . mintTxBodyL
        assets =
            Map.toList
                (ma Map.! cagePolicyIdFromCfg cfg)
    in  case assets of
            [(AssetName an, _)] ->
                pure (TokenId (AssetName an), fromShort an)
            _ ->
                failWith $
                    "boot: unexpected mint assets: "
                        <> show (length assets)

{- | Read the current state datum for a token straight from
the chain: the state UTxO at the cage address. This is the
only comparison target for every verification below.
-}
readChainState
    :: CageConfig
    -> (Provider.Network, Provider.LedgerProvider NoWitness IO)
    -> TokenId
    -> IO OnChainTokenState
readChainState cfg prov tid = do
    stateUtxos <-
        Cage.withLatest prov (`Cage.outputsAt` cageAddrFromCfg cfg Testnet)
    case findStateUtxo (cagePolicyIdFromCfg cfg) tid stateUtxos of
        Nothing ->
            failWith "verify: no state UTxO carrying the policy token"
        Just (_, out) -> case extractCageDatum out of
            Just (StateDatum s) -> pure s
            _ ->
                failWith
                    "verify: state UTxO datum is not a StateDatum"
