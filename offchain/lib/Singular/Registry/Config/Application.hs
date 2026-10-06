{- |
Module      : Singular.Registry.Config.Application
Description : The application a registry pins, derived from its seed
License     : Apache-2.0

A registry's four pins (#157 genesis-policy-pins) are derived, never written down:
the application policy and @witness(kind, registry)@ at kinds 0, 1 and 2,
all for the registry identity the boot seed determines (state policy ‖
the token name the seed derives). Which application the first pin comes
from is the caller's 'Application' choice: @open.open@ as compiled, or
@open_datum.open_datum@ applied to that identity.

'configForApplication' is the derivation: from a seed, the configuration
the boot pins and the codes the bookings and folds run. A command that
joins a registry later derives it again from the seed its state token's
minting transaction spent ("Singular.Registry.StateToken") and never
trusts a pin it did not derive.
-}
module Singular.Registry.Config.Application
    ( RegistryEconomics (..)
    , registryIdentity
    , configForApplication
    ) where

import Data.ByteString (ByteString)
import Data.ByteString.Short qualified as SBS

import Cardano.Ledger.BaseTypes (Network (..))

import Singular.Application.OpenDatum.Script
    ( Application
    , applicationCodes
    )
import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint (NamingCodes (..))
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (Coin)
import Singular.Registry.TxBuilder.Edges (namingPins)
import Singular.Registry.TxBuilder.Internal
    ( computeScriptHash
    , scriptHashBytes
    )
import Singular.Registry.Types (OnChainTxOutRef)

-- | The windows and tip a registry is booted with.
data RegistryEconomics = RegistryEconomics
    { reProcessTime :: Integer
    , reRetractTime :: Integer
    , reTip :: Coin
    }
    deriving stock (Eq, Show)

-- | The registry identity a seed determines: state policy then token name.
registryIdentity
    :: SBS.ShortByteString -> OnChainTxOutRef -> ByteString
registryIdentity stateBytes seed =
    scriptHashBytes (computeScriptHash stateBytes) <> deriveAssetName seed

{- | The configuration a boot from this seed pins, and the codes as that
registry runs them (the application applied when it takes the identity).
-}
configForApplication
    :: Application
    -> NamingCodes
    -- ^ The application and witness codes as the blueprint carries them
    -> SBS.ShortByteString
    -- ^ State validator
    -> SBS.ShortByteString
    -- ^ Request validator
    -> RegistryEconomics
    -> Network
    -> OnChainTxOutRef
    -- ^ The seed the boot consumes
    -> (CageConfig, NamingCodes)
configForApplication app codes stateBytes requestBytes econ net seed =
    let registryId = registryIdentity stateBytes seed
        pinned = applicationCodes app registryId codes
        (appPin, absentPin, activePin, terminalPin) = namingPins pinned registryId
    in  ( CageConfig
            { cageScriptBytes = stateBytes
            , requestScriptBytes = requestBytes
            , cfgScriptHash = computeScriptHash stateBytes
            , cageSeed = seed
            , defaultProcessTime = reProcessTime econ
            , defaultRetractTime = reRetractTime econ
            , defaultTip = reTip econ
            , cfgApplicationPolicy = appPin
            , cfgActivePolicy = activePin
            , cfgAbsentPolicy = absentPin
            , cfgTerminalPolicy = terminalPin
            , cfgConsumerScript = SBS.empty
            , network = net
            }
        , pinned
        )
