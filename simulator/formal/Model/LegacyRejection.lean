import Singular.Model.Admission

namespace Singular.LegacyRejection

/-- The superseded state-spending rejection path still followed by the deployed
validators, never evidence for a statement of the ruled path. -/
def step := admittedExitStep
theorem step_original : step = admittedExitStep := rfl

/-- The superseded state-spending rejection path still followed by the deployed
validators, never evidence for a statement of the ruled path. -/
def transaction := admittedTxOfExit
theorem transaction_original : transaction = admittedTxOfExit := rfl

/-- The superseded state-spending rejection path still followed by the deployed
validators, never evidence for a statement of the ruled path. -/
def observedRefusal := exitRefusal
theorem observedRefusal_original : observedRefusal = exitRefusal := rfl

end Singular.LegacyRejection
