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
    , codes
    , cfg
    , fundIn
    , applicationPolicy
    , applicationScript
    , payer
    , tokenId
    , keys
    , edges
    , preprodParams
    ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Maybe (fromJust)
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
    , ppMaxTxExUnitsL
    , ppMaxTxSizeL
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

import Singular.Registry.Blueprint (NamingCodes (..), applyBytesParam)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Ledger (ConwayEra, TokenId (..))
import Singular.Registry.TxBuilder.Edges
    ( namingPins
    , registryIdOf
    )
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , computeScriptHash
    , policyIdFromPin
    , scriptFromBytes
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
program = serialiseUPLC (UPLC.Program () plcVersion110 term)
  where
    -- Applied byte parameter, then the actual V3 script context.
    -- Extract txInfoFee and hash fee/100 bytes of the parameter. This
    -- changes real execution cost when the final body acquires its fee.
    term =
        UPLC.LamAbs () (UPLC.DeBruijn 0) $
            UPLC.LamAbs () (UPLC.DeBruijn 0) $
                app (UPLC.LamAbs () (UPLC.DeBruijn 0) (mkConstant () ())) digest
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
            (UPLC.Var () (UPLC.DeBruijn 2))
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
        , requestScriptBytes = program
        , cfgScriptHash = computeScriptHash program
        , cageSeed = seedRef
        , defaultProcessTime = 30_000
        , defaultRetractTime = 30_000
        , defaultTip = Coin 1_000_000
        , cfgApplicationPolicy = SBS.empty
        , cfgActivePolicy = SBS.empty
        , cfgAbsentPolicy = SBS.empty
        , cfgTerminalPolicy = SBS.empty
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
        }

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
byte, 17.5M memory and 10G steps per transaction.
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
        & ppMinFeeRefScriptCostPerByteL .~ fromJust (boundRational 15)
        & ppPricesL
            .~ Prices
                (fromJust (boundRational (577 / 10_000)))
                (fromJust (boundRational (721 / 10_000_000)))
