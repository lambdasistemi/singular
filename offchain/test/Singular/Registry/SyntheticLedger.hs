{- | Explicit synthetic ledger cost material. This is an installed Plutus
default model, in the language's ledger order, never a live recording.
-}
module Singular.Registry.SyntheticLedger
    ( withSyntheticCosts
    , withCostCoefficients
    , unitProgram
    ) where

import Cardano.Ledger.Alonzo.Scripts (mkCostModel, mkCostModels)
import Cardano.Ledger.Api.PParams (ppCostModelsL)
import Cardano.Ledger.Core (PParams)
import Cardano.Ledger.Plutus (ExUnits (..), Language (PlutusV3))
import Data.ByteString.Short qualified as SBS
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Lens.Micro ((&), (.~))
import PlutusCore.Evaluation.Machine.ExBudgetingDefaults
    ( defaultCostModelParamsForTesting
    )
import PlutusCore.MkPlc (mkConstant)
import PlutusCore.Version (plcVersion110)
import PlutusLedgerApi.Common (showParamName)
import PlutusLedgerApi.V3 qualified as PLC
import Singular.Registry.Ledger (ConwayEra)
import UntypedPlutusCore qualified as UPLC

withSyntheticCosts :: PParams ConwayEra -> PParams ConwayEra
withSyntheticCosts = withModel (\_ value -> value)

{- | Vary real startup and hash cost coefficients, rather than
returning invented execution units to the builder. All other coefficients
remain the installed synthetic defaults.
-}
withCostCoefficients
    :: ExUnits -> Integer -> PParams ConwayEra -> PParams ConwayEra
withCostCoefficients (ExUnits memory cpu) slope = withModel $ \name value ->
    case name of
        "cekStartupCost-exBudgetMemory" -> fromIntegral memory
        "cekStartupCost-exBudgetCPU" -> fromIntegral cpu
        "sha2_256-cpu-arguments-slope" -> value + fromInteger slope
        _ -> value

withModel
    :: (Text -> Int64 -> Int64) -> PParams ConwayEra -> PParams ConwayEra
withModel change params =
    let defaults =
            fromMaybe
                (error "synthetic Plutus defaults are absent")
                defaultCostModelParamsForTesting
        ordered =
            [ let name = showParamName parameter
                  value =
                    fromMaybe
                        (error ("synthetic Plutus parameter missing: " <> show name))
                        (Map.lookup name defaults)
              in  change name value
            | parameter <- [minBound .. maxBound :: PLC.ParamName]
            ]
        model =
            either
                (error . ("synthetic Plutus model invalid: " <>) . show)
                id
                (mkCostModel PlutusV3 ordered)
    in  params & ppCostModelsL .~ mkCostModels (Map.singleton PlutusV3 model)

-- | Synthetic V3 witnesses must return unit after their actual parameters.
unitProgram :: Int -> SBS.ShortByteString
unitProgram parameters =
    PLC.serialiseUPLC $
        UPLC.Program () plcVersion110 $
            iterate (UPLC.LamAbs () (UPLC.DeBruijn 0)) (mkConstant () ())
                !! parameters
