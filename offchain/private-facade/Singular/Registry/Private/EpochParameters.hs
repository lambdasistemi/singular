{- | Koios epoch-parameter shape, from the independently acquired ledger
parameters. The shared Wire decoder remains the sole client decoder; native
controls compare its result with these original ledger parameters.
-}
module Singular.Registry.Private.EpochParameters (epochParameters) where

import Cardano.Ledger.Api.PParams qualified as P
import Cardano.Ledger.BaseTypes (EpochInterval (..), ProtVer (..))
import Cardano.Ledger.Coin (CompactForm (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.PParams qualified as C
import Cardano.Ledger.Core (PParams)
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..), Prices (..))
import Data.Aeson (Value, object, (.=))
import Lens.Micro ((^.))

epochParameters :: PParams ConwayEra -> Value
epochParameters parameters =
    object
        [ "protocol_major" .= major
        , "protocol_minor" .= minor
        , "min_fee_a" .= feePerByte
        , "min_fee_b" .= (parameters ^. P.ppTxFeeFixedL)
        , "max_block_size" .= (parameters ^. P.ppMaxBBSizeL)
        , "max_tx_size" .= (parameters ^. P.ppMaxTxSizeL)
        , "max_bh_size" .= (parameters ^. P.ppMaxBHSizeL)
        , "key_deposit" .= (parameters ^. P.ppKeyDepositL)
        , "pool_deposit" .= (parameters ^. P.ppPoolDepositL)
        , "max_epoch" .= eMax
        , "optimal_pool_count" .= (parameters ^. P.ppNOptL)
        , "influence" .= (parameters ^. P.ppA0L)
        , "monetary_expand_rate" .= (parameters ^. P.ppRhoL)
        , "treasury_growth_rate" .= (parameters ^. P.ppTauL)
        , "min_pool_cost" .= (parameters ^. P.ppMinPoolCostL)
        , "cost_models" .= (parameters ^. P.ppCostModelsL)
        , "price_mem" .= memoryPrice
        , "price_step" .= stepPrice
        , "max_tx_ex_mem" .= transactionMemory
        , "max_tx_ex_steps" .= transactionSteps
        , "max_block_ex_mem" .= blockMemory
        , "max_block_ex_steps" .= blockSteps
        , "max_val_size" .= (parameters ^. P.ppMaxValSizeL)
        , "collateral_percent" .= (parameters ^. P.ppCollateralPercentageL)
        , "max_collateral_inputs" .= (parameters ^. P.ppMaxCollateralInputsL)
        , "coins_per_utxo_size" .= utxoPerByte
        , "pvt_motion_no_confidence" .= C.pvtMotionNoConfidence pool
        , "pvt_committee_normal" .= C.pvtCommitteeNormal pool
        , "pvt_committee_no_confidence" .= C.pvtCommitteeNoConfidence pool
        , "pvt_hard_fork_initiation" .= C.pvtHardForkInitiation pool
        , "pvtpp_security_group" .= C.pvtPPSecurityGroup pool
        , "dvt_motion_no_confidence" .= C.dvtMotionNoConfidence representative
        , "dvt_committee_normal" .= C.dvtCommitteeNormal representative
        , "dvt_committee_no_confidence"
            .= C.dvtCommitteeNoConfidence representative
        , "dvt_update_to_constitution"
            .= C.dvtUpdateToConstitution representative
        , "dvt_hard_fork_initiation" .= C.dvtHardForkInitiation representative
        , "dvt_p_p_network_group" .= C.dvtPPNetworkGroup representative
        , "dvt_p_p_economic_group" .= C.dvtPPEconomicGroup representative
        , "dvt_p_p_technical_group" .= C.dvtPPTechnicalGroup representative
        , "dvt_p_p_gov_group" .= C.dvtPPGovGroup representative
        , "dvt_treasury_withdrawal" .= C.dvtTreasuryWithdrawal representative
        , "committee_min_size" .= (parameters ^. C.ppCommitteeMinSizeL)
        , "committee_max_term_length" .= committeeTerm
        , "gov_action_lifetime" .= lifetime
        , "gov_action_deposit" .= (parameters ^. C.ppGovActionDepositL)
        , "drep_deposit" .= (parameters ^. C.ppDRepDepositL)
        , "drep_activity" .= activity
        , "min_fee_ref_script_cost_per_byte"
            .= (parameters ^. C.ppMinFeeRefScriptCostPerByteL)
        ]
  where
    ProtVer major minor = parameters ^. P.ppProtocolVersionL
    P.CoinPerByte (CompactCoin feePerByte) = parameters ^. P.ppTxFeePerByteL
    P.CoinPerByte (CompactCoin utxoPerByte) = parameters ^. P.ppCoinsPerUTxOByteL
    EpochInterval eMax = parameters ^. P.ppEMaxL
    EpochInterval committeeTerm = parameters ^. C.ppCommitteeMaxTermLengthL
    EpochInterval lifetime = parameters ^. C.ppGovActionLifetimeL
    EpochInterval activity = parameters ^. C.ppDRepActivityL
    Prices memoryPrice stepPrice = parameters ^. P.ppPricesL
    ExUnits transactionMemory transactionSteps = parameters ^. P.ppMaxTxExUnitsL
    ExUnits blockMemory blockSteps = parameters ^. P.ppMaxBlockExUnitsL
    pool = parameters ^. C.ppPoolVotingThresholdsL
    representative = parameters ^. C.ppDRepVotingThresholdsL
