import NoPin.Held.Fixtures
import NoPin.Held.Conditions

/-! Hypothetical #741 public scenarios. All economic observations and expected
value allocations are computed from the model; this is not a ledger history. -/
namespace NoPin.Held.Fixtures
open Singular

/-- Hypothesis fixture under #741, not accepted law; finite occurring role-name table. -/
def hashes : List NoPin.HashEntry :=
  [7, 8, 9].map fun key =>
    ⟨encode (.role .witness registry key), hash (encode (.role .witness registry key))⟩
/-- Hypothesis fixture under #741, not accepted law; generic public input for each discovered case. -/
def goodQuery (surface : Case) : Query :=
  let live := surface == .liveUpdate || surface == .liveRelease || surface == .booking
  { surface, hashes, state := if live then before else two,
    source := if live then .live (holding 7 5) else .pending (pending 7 5),
    pending := pending 7 5, selected := if surface == .consumption then [] else selected,
    signers := [42], key := 7, time := 1000, funding := 20, fee := 1 }

/-- Hypothesis fixture under #741, not accepted law; explicit willing processor, no fee-market claim. -/
def willing (_ : Nat) : Prop := True

end NoPin.Held.Fixtures
