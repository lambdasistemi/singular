import Singular.Driver

/-! Compatibility names for the single active driver. All setup, admission,
 observation and batch execution delegates to Singular.Driver. -/
namespace Singular.M1Driver
abbrev runSetup := Singular.Driver.runSetup
abbrev runSurface := Singular.Driver.runSurface
abbrev scenarioJson := Singular.Driver.scenarioJson
abbrev reachBatchStart := Singular.Driver.reachBatchStart
abbrev runFoldBatch := Singular.Driver.runFoldBatch
abbrev runRejectBatch := Singular.Driver.runRejectBatch
abbrev batchScenarioJson := Singular.Driver.batchScenarioJson
end Singular.M1Driver
