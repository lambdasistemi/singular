import OpenDatumApplicationHeld.MoneyFixtures


namespace OpenDatumApplicationHeld.Money.Refutation
open Singular Lean SingularApplicationHeld
open OpenDatumApplicationHeld.Fixtures

def data : RegistrationData := { registrationData with holdingAddress := ⟨funding.processorAddress, none⟩ }
def request : PendingRequest := .registration
  { registration.output with assets := [(registrationAsset hash code release data, 1)] } data
def decode : DecodeApplication
  | 2007 => some (.registration data)
  | n => OpenDatumApplicationHeld.Fixtures.decode n
def input : Input :=
  let q := Fixtures.input .registrationFold
  let baseline := { q.baseline with registration := { q.baseline.registration with
    request := { q.baseline.registration.request with destination := funding.processorAddress } } }
  let built := buildFold hash code commit release OpenDatumApplicationHeld.Fixtures.registry [request] funding
  let observation := applicationFoldView built [request]
  { q with baseline := baseline, registration := request, lifecycle := { q.lifecycle with observation := observation, action := .registrationFold request.output.reference 1 } }

theorem antecedent : NewPremise hash code commit decode release .registrationFold input := by
  refine ⟨by decide, rfl, by decide, by decide, by decide, by decide, by decide, by trivial⟩
theorem failed_allocation : ¬ FoldOutcome .none hash code commit .registrationFold input := by decide


end OpenDatumApplicationHeld.Money.Refutation
