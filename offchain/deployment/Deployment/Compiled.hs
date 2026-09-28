{- |
Module      : Deployment.Compiled
Description : The compiled halves a release ships, bound to one registry
License     : Apache-2.0

In registry mode (#157) the REGISTRY blueprint contributes one minting
validator, @witness(kind, registry)@ (@witness.witness@, moved beside the
cage by #173), and the deployment applies it three times — kinds 0, 1
and 2 — to obtain the absent, active and terminal policies. Together
with the naming application validator's own hash
(@application.application@, from the NAMING blueprint) those are the four
identities the eight-field state datum pins (D-BOOT). Every one of them
is derived here from compiled code; none is a literal.

'loadCompiled' reads @REGISTRY_BLUEPRINT@ for the state, request,
witness and staking validators and @NAMING_BLUEPRINT@ for the naming
application and the retirement custody script;
'bindSeed' and 'bindDeployment' bind the three witness policies to the
registry a seed creates; 'partsOf' is the one derivation the manifest,
the boot configuration and the state datum all take their pins from.
-}
module Deployment.Compiled (
    Compiled (..),
    loadCompiled,
    bindSeed,
    bindDeployment,
    partsOf,
) where

import Data.ByteString.Short qualified as SBS
import Data.Text qualified as T

import Cardano.Ledger.Api.Tx.In (TxIn)
import Deployment.Narration (failWith)
import Deployment.Options (requireEnv)
import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint (
    applyBytesParam,
    applyIntParam,
    extractCompiledCode,
    loadBlueprint,
 )
import Singular.Registry.Deployment (
    CageParts (..),
    Deployment (..),
    parseOutRef,
 )
import Singular.Registry.TxBuilder.Internal (
    computeScriptHash,
    scriptHashBytes,
    txInToRef,
 )

-- | Everything the two blueprints in this release contribute.
data Compiled = Compiled
    { cStateBytes :: SBS.ShortByteString
    , cRequestBytes :: SBS.ShortByteString
    , cAppBytes :: SBS.ShortByteString
    {- ^ The application validator, unapplied: its hash IS the application
    policy the registry pins.
    -}
    , cWitnessBytes :: SBS.ShortByteString
    -- ^ @witness(kind, registry)@, unapplied.
    , cAbsentBytes :: SBS.ShortByteString
    -- ^ @witness(0, registry)@, applied once the seed is known.
    , cActiveBytes :: SBS.ShortByteString
    -- ^ @witness(1, registry)@, applied once the seed is known.
    , cTerminalBytes :: SBS.ShortByteString
    -- ^ @witness(2, registry)@, applied once the seed is known.
    , cCustodyBytes :: SBS.ShortByteString
    , cStakingBytes :: SBS.ShortByteString
    }

-- | Read both blueprints and extract every validator the release needs.
loadCompiled :: IO Compiled
loadCompiled = do
    mpfsPath <- requireEnv "REGISTRY_BLUEPRINT"
    namingPath <- requireEnv "NAMING_BLUEPRINT"
    mbp <- either failWith pure =<< loadBlueprint mpfsPath
    nbp <- either failWith pure =<< loadBlueprint namingPath
    let need what bp title = case extractCompiledCode title bp of
            Just b -> pure b
            Nothing ->
                failWith
                    ( T.unpack title
                        <> " not found in the "
                        <> what
                        <> " blueprint"
                    )
    stateBytes <- need "registry" mbp "state.state"
    requestBytes <- need "registry" mbp "request.request"
    appBytes <- need "naming" nbp "application.application"
    -- #173 I2: the three witness policies moved to the REGISTRY
    -- partition, beside the cage whose fold they co-locate with. The
    -- naming application itself stays where it is.
    witnessBytes <- need "registry" mbp "witness.witness"
    custodyBytes <- need "naming" nbp "retirement_custody.retirement_custody"
    stakingBytes <- need "registry" mbp "staking.staking"
    pure
        Compiled
            { cStateBytes = stateBytes
            , cRequestBytes = requestBytes
            , cAppBytes = appBytes
            , cWitnessBytes = witnessBytes
            , -- Unbound until a seed names the registry; `bindSeed` fills
              -- these in, and nothing may read them before it has.
              cAbsentBytes = witnessBytes
            , cActiveBytes = witnessBytes
            , cTerminalBytes = witnessBytes
            , cCustodyBytes = custodyBytes
            , cStakingBytes = stakingBytes
            }

{- | Bind the three token policies to the registry the seed creates.

The registry identity is the state policy followed by the token name the
seed determines — the same bytes the cage's own pins are computed from, so
the deployment and the validator agree by construction rather than by
transcription.
-}
bindSeed :: Compiled -> TxIn -> Compiled
bindSeed c seedIn =
    let registryId =
            scriptHashBytes (computeScriptHash (cStateBytes c))
                <> deriveAssetName (txInToRef seedIn)
        witnessAt kind =
            applyBytesParam registryId (applyIntParam kind (cWitnessBytes c))
     in c
            { cAbsentBytes = witnessAt 0
            , cActiveBytes = witnessAt 1
            , cTerminalBytes = witnessAt 2
            }

-- | Bind to the registry a manifest records, by its seed.
bindDeployment :: Compiled -> Deployment -> IO Compiled
bindDeployment c dep = bindSeed c <$> either failWith pure (parseOutRef (depSeedOutRef dep))

-- | The hash of compiled bytes, as a policy id in the shape a pin takes.
policyOf :: SBS.ShortByteString -> SBS.ShortByteString
policyOf = SBS.toShort . scriptHashBytes . computeScriptHash

-- | The release's compiled halves, in the shape a manifest consumes.
partsOf :: Compiled -> CageParts
partsOf c =
    CageParts
        { partsStateBytes = cStateBytes c
        , partsRequestBytes = cRequestBytes c
        , partsApplicationPolicy = policyOf (cAppBytes c)
        , partsActivePolicy = policyOf (cActiveBytes c)
        , partsAbsentPolicy = policyOf (cAbsentBytes c)
        , partsTerminalPolicy = policyOf (cTerminalBytes c)
        , -- Registry mode retired the consuming hook: no script is
          -- withdrawn from at a fold, so there is no consumer to carry.
          -- Empty is what the builders refuse a consuming batch on.
          partsConsumerScript = SBS.empty
        }
