{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.TxBuilder.BookingFixture
Description : One registry, one payer and two keys, for the booking rows
License     : Apache-2.0

The registry the booking rows share: toy PlutusV3 programs applied the way
the real pins are, the naming pins those programs give, a payer and the
seven edges. Every expected value a row compares against is derived from
these, never read from a builder's output.
-}
module Singular.Registry.TxBuilder.BookingFixture
    ( program
    , requestProgram
    , codes
    , cfg
    , fundIn
    , applicationPolicy
    , applicationScript
    , requestPin
    , payer
    , tokenId
    , keys
    , edges
    , preprodParams
    , RetainedRegistry (..)
    , retainedBlueprintFile
    , loadRetained
    ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Maybe (fromJust, fromMaybe)
import Data.Text qualified as T
import Lens.Micro ((&), (.~))
import PlutusCore.Default (DefaultFun (..))
import PlutusCore.MkPlc (mkConstant)
import PlutusCore.Version (plcVersion110)
import PlutusLedgerApi.V3 (serialiseUPLC)
import UntypedPlutusCore qualified as UPLC
import UntypedPlutusCore.DeBruijn ()

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Alonzo.Scripts (Prices (..))
import Cardano.Ledger.Api.PParams
    ( CoinPerByte (..)
    , PParams
    , emptyPParams
    , ppCoinsPerUTxOByteL
    , ppCollateralPercentageL
    , ppMaxCollateralInputsL
    , ppMaxTxExUnitsL
    , ppMaxTxSizeL
    , ppMaxValSizeL
    , ppPricesL
    , ppTxFeeFixedL
    , ppTxFeePerByteL
    )
import Cardano.Ledger.BaseTypes (Network (Testnet), boundRational)
import Cardano.Ledger.Coin (Coin (..), CompactForm (CompactCoin))
import Cardano.Ledger.Conway.PParams (ppMinFeeRefScriptCostPerByteL)
import Cardano.Ledger.Core (Script)
import Cardano.Ledger.Mary.Value (AssetName (..), PolicyID)
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.TxIn (TxIn)

import Singular.Registry.Application (ApplicationPin (..))
import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint
    ( Blueprint
    , NamingCodes (..)
    , applyBytesParam
    , extractCompiledCode
    , loadBlueprint
    )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Config.Application
    ( RegistryEconomics (..)
    , configForApplication
    )
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Ledger (ConwayEra, TokenId (..))
import Singular.Registry.TxBuilder.Edges
    ( namingPins
    , registryIdOf
    )
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , computeScriptHash
    , onChainTokenId
    , policyIdFromPin
    , requestPolicyHash
    , scriptFromBytes
    , scriptHashBytes
    , txInToRef
    )
import Singular.Registry.Types
    ( Edge
    , OnChainTxOutRef
    )

-- ---------------------------------------------------------
-- Fixtures: one registry, one payer, two keys
-- ---------------------------------------------------------

{- | A well-formed PlutusV3 program: the registry scripts are
parameterized by applying one argument after another, so the fixture
takes a byte parameter and the V3 context. It returns unit after a
fee-dependent hash; these are synthetic application witnesses, not
implementations of registry admission.
-}
program :: SBS.ShortByteString
program = toyProgram 1

{- | The same toy program for a script that takes two parameters before the
context, as the request validator does (state policy, registry token): the
registration booking runs it as a mint, so it must be a function of the
context once both parameters are applied.
-}
requestProgram :: SBS.ShortByteString
requestProgram = toyProgram 2

{- | A toy program that takes the given number of parameters, then the
actual V3 script context. It extracts txInfoFee and hashes fee/100 bytes of
the first parameter, which must be a byte string. This changes real
execution cost when the final body acquires its fee.
-}
toyProgram :: Int -> SBS.ShortByteString
toyProgram parameters =
    serialiseUPLC (UPLC.Program () plcVersion110 term)
  where
    term =
        lambdas (parameters + 1) $
            app (UPLC.LamAbs () (UPLC.DeBruijn 0) (mkConstant () ())) digest
    lambdas n t = iterate (UPLC.LamAbs () (UPLC.DeBruijn 0)) t !! n
    app = UPLC.Apply ()
    builtin = UPLC.Builtin ()
    headOf = app (UPLC.Force () (builtin HeadList))
    tailOf = app (UPLC.Force () (builtin TailList))
    fields =
        app (UPLC.Force () (UPLC.Force () (builtin SndPair)))
            . app (builtin UnConstrData)
    info = headOf (fields (UPLC.Var () (UPLC.DeBruijn 1)))
    fee =
        app
            (builtin UnIData)
            (headOf (tailOf (tailOf (tailOf (fields info)))))
    count =
        app (app (builtin DivideInteger) fee) (mkConstant () (100 :: Integer))
    bytes =
        app
            ( app
                (app (builtin SliceByteString) (mkConstant () (0 :: Integer)))
                count
            )
            ( app
                (builtin UnBData)
                (UPLC.Var () (UPLC.DeBruijn (fromIntegral (parameters + 1))))
            )
    digest = app (builtin Sha2_256) bytes

codes :: NamingCodes
codes =
    NamingCodes
        { ncApplication = applyBytesParam (BS.replicate 9_000 0x61) program
        , ncWitness = applyBytesParam "t240-witness" program
        }

{- | The registry before its pins: the pins derive from its identity,
the state script hash and the boot seed. The pins are filled in
separately — with strict record fields the config and its own pins
would otherwise force each other.
-}
unpinned :: CageConfig
unpinned =
    CageConfig
        { cageScriptBytes = program
        , requestScriptBytes = requestProgram
        , cfgScriptHash = computeScriptHash program
        , cageSeed = seedRef
        , defaultProcessTime = 30_000
        , defaultRetractTime = 30_000
        , defaultTip = Coin 1_000_000
        , defaultRegistrationCost = Coin 2_000_000
        , defaultBookingWidth = 10_000
        , cfgApplicationPolicy = SBS.empty
        , cfgActivePolicy = SBS.empty
        , cfgAbsentPolicy = SBS.empty
        , cfgTerminalPolicy = SBS.empty
        , cfgRequestPolicy = SBS.empty
        , cfgConsumerScript = SBS.empty
        , network = Testnet
        }

seedRef :: OnChainTxOutRef
seedRef =
    txInToRef $
        either
            (error . ("BookEdgeSpec fixture: " <>))
            id
            (parseOutRef (T.pack (replicate 64 '1' <> "#0")))

fundIn :: TxIn
fundIn =
    either
        (error . ("BookEdgeSpec fixture: " <>))
        id
        (parseOutRef (T.pack (replicate 64 '3' <> "#0")))

{- | The registry with the four pins its naming partition derives. The
design pins the application hash, and the rows below assert against the
same hash — evaluated from the pins, never from builder output.
-}
cfg :: CageConfig
cfg =
    unpinned
        { cfgApplicationPolicy = applicationPin
        , cfgAbsentPolicy = absentPin
        , cfgActivePolicy = activePin
        , cfgTerminalPolicy = terminalPin
        , cfgRequestPolicy = requestPin
        }

{- | The request policy this registry pins: the request program applied to
the state hash and the registry token, by the one shared derivation.
-}
requestPin :: SBS.ShortByteString
requestPin =
    SBS.toShort $
        scriptHashBytes $
            requestPolicyHash
                (cfgScriptHash unpinned)
                requestProgram
                (onChainTokenId tokenId)

applicationPin
    , absentPin
    , activePin
    , terminalPin
        :: SBS.ShortByteString
(applicationPin, absentPin, activePin, terminalPin) =
    namingPins codes (registryIdOf unpinned)

{- | The policy the naming application certifies approvals under: the
hash of the applied application script (DM-1 @baAsset@'s policy).
-}
applicationPolicy :: PolicyID
applicationPolicy = policyIdFromPin applicationPin

-- | The naming application script, the design's @baScript@.
applicationScript :: Script ConwayEra
applicationScript = scriptFromBytes "naming-application" (ncApplication codes)

payer :: Addr
payer = addrFromKeyHashBytes Testnet (BS.replicate 28 0x5a)

tokenId :: TokenId
tokenId = TokenId (AssetName "t240-registry")

keys :: [ByteString]
keys = ["t240-key-a", "t240-key-b"]

-- | The seven admissible edges, by the name the model gives each.
edges :: [(Edge, String)]
edges =
    zip
        [0 ..]
        [ "insertAbsent"
        , "insertActive"
        , "updateActive"
        , "updateTerminal"
        , "deleteAbsent"
        , "deleteActive"
        , "witnessTerminal"
        ]

-- ---------------------------------------------------------
-- The public preprod parameters the judgements run under
-- ---------------------------------------------------------

{- | The fee, collateral, price and reference-script parameters the public
preprod node reports (protocol parameters file sha256 @66eb0791…@, read
2026-09-30): fee 155381 + 44 per byte, 4310 per UTxO byte, collateral 150%,
prices 0.0577 per memory and 0.0000721 per step, 15 per reference-script
byte, 17.5M memory and 10G steps per transaction. The same file reports the
largest value an output may hold, 5000 bytes, and at most 3 collateral inputs,
which the final-body rules of the ledger read.
-}
preprodParams :: PParams ConwayEra
preprodParams =
    emptyPParams
        & ppMaxTxSizeL .~ 16_384
        & ppTxFeePerByteL .~ CoinPerByte (CompactCoin 44)
        & ppTxFeeFixedL .~ Coin 155_381
        & ppCoinsPerUTxOByteL .~ CoinPerByte (CompactCoin 4_310)
        & ppCollateralPercentageL .~ 150
        & ppMaxTxExUnitsL .~ ExUnits 17_500_000 10_000_000_000
        & ppMaxValSizeL .~ 5_000
        & ppMaxCollateralInputsL .~ 3
        & ppMinFeeRefScriptCostPerByteL .~ fromJust (boundRational 15)
        & ppPricesL
            .~ Prices
                (fromJust (boundRational (577 / 10_000)))
                (fromJust (boundRational (721 / 10_000_000)))

-- ---------------------------------------------------------
-- The retained compiled bytes
-- ---------------------------------------------------------

{- | The registry the retained blueprint describes: the actual compiled
validators of the accepted identity, and the configuration, boot state and
pins the library derives from them. Nothing here is a toy program.
-}
data RetainedRegistry = RetainedRegistry
    { rrFile :: ByteString
    -- ^ The retained blueprint file, byte for byte
    , rrBlueprint :: Blueprint
    , rrStateCode :: SBS.ShortByteString
    , rrRequestCode :: SBS.ShortByteString
    , rrOpenCode :: SBS.ShortByteString
    , rrWitnessCode :: SBS.ShortByteString
    , rrCodes :: NamingCodes
    -- ^ The generic open policy and the witness policy, as pinned
    , rrConfig :: CageConfig
    -- ^ The configuration the boot from the fixture seed pins
    , rrToken :: TokenId
    -- ^ The registry token that seed determines
    }

{- | A byte-identical copy of the retained store output
@hnmfy1ikl30mdm5spxacyymgrmix9qdb-open-datum-deployment-blueprint@, sha256
@8f02ed0d7d701243011626571785c66ca4543fe60a2daae787cb5110bedade3c@.
-}
retainedBlueprintFile :: FilePath
retainedBlueprintFile =
    "test/fixtures/blueprint/open-datum-deployment-blueprint.json"

-- | Read the retained blueprint and derive the registry from its bytes.
loadRetained :: IO RetainedRegistry
loadRetained = do
    bytes <- BS.readFile retainedBlueprintFile
    blueprint <-
        loadBlueprint retainedBlueprintFile
            >>= either (fail . ("the retained blueprint: " <>)) pure
    let code title =
            fromMaybe
                (error ("the retained blueprint has no code for " <> title))
                (extractCompiledCode (T.pack title) blueprint)
        stateCode = code "state.state"
        requestCode = code "request.request"
        openCode = code "open.open"
        witnessCode = code "witness.witness"
        retainedCodes = NamingCodes{ncApplication = openCode, ncWitness = witnessCode}
        economics =
            RegistryEconomics
                { reProcessTime = 30_000
                , reRetractTime = 30_000
                , reTip = Coin 1_000_000
                , reRegistrationCost = Coin 2_000_000
                , reBookingWidth = 10_000
                }
        (config, pinned) =
            configForApplication
                (PinAsCompiled "open.open")
                retainedCodes
                stateCode
                requestCode
                economics
                Testnet
                seedRef
    pure
        RetainedRegistry
            { rrFile = bytes
            , rrBlueprint = blueprint
            , rrStateCode = stateCode
            , rrRequestCode = requestCode
            , rrOpenCode = openCode
            , rrWitnessCode = witnessCode
            , rrCodes = pinned
            , rrConfig = config
            , rrToken = TokenId (AssetName (SBS.toShort (deriveAssetName seedRef)))
            }
