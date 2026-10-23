{- |
Module      : Singular.Registry.Witness
Description : The witness token of a key, and the outputs that hold it
License     : Apache-2.0

A key that is active in a registry has a witness token: an asset of the
registry's active witness policy, named by the key's bytes. A command given
the registry and a key asks the provider who holds that asset instead of
reading every output at the application address, where the application's
holding rule counts an output a holding only if it holds that token.

'witnessAsset' is the one place a registry's configuration, a witness kind
and a key become the asset to look up. Every reader of a key's witness asks
it, so a change of how the asset is derived is a change of one function.
-}
module Singular.Registry.Witness
    ( WitnessKind (..)
    , WitnessFound (..)
    , witnessAsset
    , holdsAsset
    , findWitness
    ) where

import Data.ByteString (ByteString)
import Data.ByteString.Short qualified as SBS
import Data.List (sortOn)
import Data.Map.Strict qualified as Map

import Cardano.Ledger.Api.Tx.Out (TxOut, valueTxOutL)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    )
import Lens.Micro ((^.))

import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Evidence (Evidenced (..))
import Singular.Registry.Ledger (ConwayEra)
import Singular.Registry.LedgerProvider
    ( Asset
    , OutputQuery (..)
    , Outputs
    , ReadFailure
    , Session (..)
    )
import Singular.Registry.TxBuilder.Internal (policyIdFromPin)

-- | Which of the registry's witness policies a token belongs to.
data WitnessKind
    = -- | The token a registration mints and a termination burns
      ActiveWitness
    deriving stock (Eq, Show, Enum, Bounded)

-- | What the provider said holds a key's witness.
data WitnessFound = WitnessFound
    { foundAsset :: Asset
    -- ^ The asset that was asked for
    , foundHolders :: Outputs
    -- ^ The live outputs whose own value holds it, by output reference
    }
    deriving stock (Eq, Show)

{- | The asset to look up for a key's witness of one kind in this registry:
that kind's witness policy, with the key's bytes as the asset name.
-}
witnessAsset :: CageConfig -> WitnessKind -> ByteString -> Asset
witnessAsset cfg kind key =
    (policyIdFromPin pin, AssetName (SBS.toShort key))
  where
    pin = case kind of
        ActiveWitness -> cfgActivePolicy cfg

-- | Whether an output's own value holds at least one unit of the asset.
holdsAsset :: Asset -> TxOut ConwayEra -> Bool
holdsAsset (policy, name) out =
    maybe
        False
        ((> 0) . Map.findWithDefault 0 name)
        (Map.lookup policy assets)
  where
    MaryValue _ (MultiAsset assets) = out ^. valueTxOutL

{- | Ask the provider who holds the key's witness. The provider's answer is
unverified, so an output is kept only when its own value holds the asset; the
holders come back in the order of their output references.
-}
findWitness
    :: (Monad m)
    => Session w m
    -> CageConfig
    -> WitnessKind
    -> ByteString
    -> m (Either ReadFailure WitnessFound)
findWitness session cfg kind key = do
    answer <- outputs session (HoldingAsset asset)
    pure
        ( WitnessFound asset
            . sortOn fst
            . filter (holdsAsset asset . snd)
            . value
            <$> answer
        )
  where
    asset = witnessAsset cfg kind key
