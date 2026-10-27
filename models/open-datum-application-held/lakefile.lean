import Lake
open Lake DSL

package «open-datum-application-held» where
  srcDir := "lean"

require «open-datum» from "../../applications/open-datum"

require singular from "../.."
require «singular-application-held» from "../singular-application-held"

@[default_target]
lean_lib OpenDatumApplicationHeld where

@[default_target]
lean_lib MoneyStatementEvidence where
  roots := #[`OpenDatumApplicationHeld.MoneyHoldingEvidence, `OpenDatumApplicationHeld.MoneyUpdateEvidence,
    `OpenDatumApplicationHeld.ConfigurationOnceEvidence]
