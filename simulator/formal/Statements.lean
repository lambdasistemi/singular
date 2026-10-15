import Singular.Statements.Preservation
import Singular.Statements.Inversions
import Singular.Statements.Batch
import Singular.Statements.RegistrationTransaction
import Singular.Statements.TerminationTransaction
import Singular.Statements.ExitPayments
import Singular.Statements.Admission
import Singular.Statements.Delivery
import Singular.Statements.Accounting
import Singular.Statements.Booking
import Singular.Statements.Payments
import Singular.Statements.Rejection
import Singular.Statements.RejectionState
import Singular.Statements.RejectionProtection
import Singular.Statements.Termination
import Singular.Statements.Refunds
import Singular.Lemmas
import Singular.Driver
import Singular.Economics

/-! The public statement surface of the registry-mode model.

The facade exports transaction accounting, payment, rejection, fold properties
and inversions from the child modules. Reachable-state premises guard
the supply laws; accounting and admission facts state their own premises over
arbitrary transactions, requests and evidence. -/

namespace Singular
namespace Statements

end Statements
end Singular
