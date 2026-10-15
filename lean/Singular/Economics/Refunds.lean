import Singular.Economics.Observation

/-! Refund obligations and actual lovelace received, grouped by address.
An output is credited once at its own address. No output-purpose annotation
can distinguish a refund from another payment received at that same address. -/

namespace Singular

def refundAmount (request : RegistrationRequest) (retraction : Bool) : Nat :=
  if retraction then request.contents.lovelace
  else request.contents.lovelace - request.declaredTip

def refundOwed (requests : List RegistrationRequest) (retraction : Bool)
    (address : Nat) : Nat :=
  ((requests.filter fun r => r.refundAddress == address).map
    fun r => refundAmount r retraction).sum

/-- One row per address. Distinct consumed request identities are enforced by
the exit judgement; a shared address is owed their sum, never their maximum. -/
def refundObligations (requests : List RegistrationRequest) (retraction : Bool) :
    List (Nat × Nat) :=
  (requests.map (·.refundAddress)).eraseDups.map fun address =>
    (address, refundOwed requests retraction address)

/-- Read every produced output once, at its actual address, without selecting
by its role, expected amount or a purported purpose. Other payments to the same
address count as received lovelace too. This states no processor-take law. -/
def refundPaid (tx : EconomicTransaction) (address : Nat) : Nat :=
  ((tx.outputs.filter fun o => o.output.address == some address).map
    fun o => o.output.lovelace).sum

def refundRefusal (tx : EconomicTransaction) (obligations : List (Nat × Nat))
    (reason : String) : Option String :=
  if obligations.all (fun obligation => decide (obligation.2 ≤ refundPaid tx obligation.1))
  then none else some reason

/-- Lookup follows the admitted member references, not a typed refund claim.
The rejection judgement proves every lookup succeeds and the references are
distinct before these obligations are checked. -/
def rejectedRequests (world : World) (members : List (OutRef × RejectReason)) :
    List RegistrationRequest :=
  members.filterMap fun member =>
    (world.pending.find? fun b => b.request.reference == member.1).map (·.request)

end Singular
