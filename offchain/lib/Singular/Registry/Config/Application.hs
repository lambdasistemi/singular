{- |
Module      : Singular.Registry.Config.Application
Description : The application a registry pins, derived at boot and re-derived at attach
License     : Apache-2.0

A registry's four pins (#157 D-BOOT) are derived, never written down:
the application policy and @witness(kind, registry)@ at kinds 0, 1 and 2,
all for the registry identity the boot seed determines (state policy ‖
the token name the seed derives). Which application the first pin comes
from is the caller's 'Application' choice: @open.open@ as compiled, or
@open_datum.open_datum@ applied to that identity.

'configForApplication' is the boot side: from a chosen seed, the
configuration the boot pins and the codes the bookings and folds run.
'cageConfigForApplication' is the attach side: from a deployment
record, the same derivation again, refused when the record's application
hash, state hash or active policy differ from what this release derives
for that seed. A command attaching to a registry never trusts a pin it
did not derive.
-}
module Singular.Registry.Config.Application
    ( RegistryEconomics (..)
    , registryIdentity
    , configForApplication
    , cageConfigForApplication
    ) where

import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short qualified as SBS
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import Cardano.Ledger.BaseTypes (Network (..))

import Singular.Application.OpenDatum.Script
    ( Application
    , applicationCodes
    , applicationTitle
    )
import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint (NamingCodes (..))
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Deployment.Attach
    ( CageParts (..)
    , cageConfigFor
    )
import Singular.Registry.Deployment.Manifest
    ( Deployment (..)
    , parseOutRef
    )
import Singular.Registry.Ledger (Coin (..))
import Singular.Registry.TxBuilder.Edges (namingPins)
import Singular.Registry.TxBuilder.Internal
    ( computeScriptHash
    , scriptHashBytes
    , txInToRef
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

{- | Attach to a deployment: derive every pin again from its seed and this
release's codes, and refuse a record whose application hash differs;
'cageConfigFor' then refuses a different state hash or active policy.
The network is the test network, as 'cageConfigFor' fixes it.
-}
cageConfigForApplication
    :: Application
    -> NamingCodes
    -> SBS.ShortByteString
    -> SBS.ShortByteString
    -> Deployment
    -> Either String (CageConfig, NamingCodes)
cageConfigForApplication app codes stateBytes requestBytes dep = do
    seedIn <- parseOutRef (depSeedOutRef dep)
    let econ =
            RegistryEconomics
                { reProcessTime = depProcessTime dep
                , reRetractTime = depRetractTime dep
                , reTip = Coin (depTip dep)
                }
        (derived, pinned) =
            configForApplication
                app
                codes
                stateBytes
                requestBytes
                econ
                Testnet
                (txInToRef seedIn)
        appHex = hexS (cfgApplicationPolicy derived)
    when (appHex /= depApplicationHash dep) $
        Left
            ( "this release derives the "
                <> T.unpack (applicationTitle app)
                <> " application policy 0x"
                <> T.unpack appHex
                <> " for this registry, but the deployment records 0x"
                <> T.unpack (depApplicationHash dep)
            )
    cfg <-
        cageConfigFor
            dep
            CageParts
                { partsStateBytes = stateBytes
                , partsRequestBytes = requestBytes
                , partsApplicationPolicy = cfgApplicationPolicy derived
                , partsActivePolicy = cfgActivePolicy derived
                , partsAbsentPolicy = cfgAbsentPolicy derived
                , partsTerminalPolicy = cfgTerminalPolicy derived
                , partsConsumerScript = cfgConsumerScript derived
                }
    pure (cfg, pinned)
  where
    hexS = TE.decodeUtf8 . B16.encode . SBS.fromShort
