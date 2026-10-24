import NoPin.ApplicationRequests.MoneyFixtures

/-! Hypothetical counterexample to the frozen registration-fold claim.
This observation is admitted by the statement premises; no booking history or
production exploit is asserted. -/
namespace NoPin.ApplicationRequests.Money.Refutation
open Singular Lean
open NoPin.ApplicationRequests.Fixtures

def data : RegistrationData := { registrationData with holdingAddress := funding.processorAddress }
def request : PendingRequest := .registration
  { registration.output with assets := [(registrationAsset hash code release data, 1)] } data
def decode : DecodeApplication
  | 2007 => some (.registration data)
  | n => NoPin.ApplicationRequests.Fixtures.decode n
def input : Input :=
  let q := Fixtures.input .registrationFold
  let baseline := { q.baseline with registration := { q.baseline.registration with
    request := { q.baseline.registration.request with destination := funding.processorAddress } } }
  let built := buildFold hash code commit release NoPin.ApplicationRequests.Fixtures.registry [request] funding
  let observation := applicationFoldView built [request]
  { q with baseline := baseline, registration := request, lifecycle := { q.lifecycle with observation := observation, action := .registrationFold request.output.reference 1 } }

theorem antecedent : NewPremise hash code commit decode release .registrationFold input := by
  refine ⟨by decide, rfl, by decide, by decide, by decide, by decide, by decide, by trivial⟩
theorem failed_allocation : ¬ FoldOutcome .none hash code commit .registrationFold input := by decide

theorem registration_fold_journey_refutation :
    ¬ (∀ (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
      (release : PublishedRelease) (q : Input),
      NewPremise h c t decode release .registrationFold q →
      NewClaim .none h c t decode release .registrationFold q) := by
  intro alleged
  obtain ⟨_, _, _, _, _, _, _, _, outcome, _, _⟩ :=
    alleged hash code commit decode release input antecedent
  exact failed_allocation outcome

end NoPin.ApplicationRequests.Money.Refutation
