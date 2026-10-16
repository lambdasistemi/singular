import Singular.Driver
import Singular.Model.LegacyRejection

namespace Singular.LegacyRejection

/-- The superseded state-spending rejection path still followed by the deployed
validators, never evidence for a statement of the ruled path. -/
def runSurface := Driver.runSurface
theorem runSurface_original : runSurface = Driver.runSurface := rfl

/-- The superseded state-spending rejection path still followed by the deployed
validators, never evidence for a statement of the ruled path. -/
def rejectBatchStep := Driver.rejectBatchStep
theorem rejectBatchStep_original : rejectBatchStep = Driver.rejectBatchStep := rfl

/-- The superseded state-spending rejection path still followed by the deployed
validators, never evidence for a statement of the ruled path. -/
def runRejectBatch := Driver.runRejectBatch
theorem runRejectBatch_original : runRejectBatch = Driver.runRejectBatch := rfl

/-- The superseded state-spending rejection path still followed by the deployed
validators, never evidence for a statement of the ruled path. -/
def judgeSurface := Driver.judgeSurface
theorem judgeSurface_original : judgeSurface = Driver.judgeSurface := rfl

end Singular.LegacyRejection
