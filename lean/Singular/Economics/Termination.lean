import Singular.Model.Termination

/-! A termination booking transfers the genuine singular tag from application
custody. Tag presence and tuple binding do not execute the application's rule. -/

namespace Singular

def terminationDeclaredLovelace (r : TerminationRequest) : Nat :=
  r.declaredTip + r.carrierAda

def terminationContentsShape (c : Config) (r : TerminationRequest) : Bool :=
  decide (c.minimumTip ≤ r.declaredTip ∧ r.contents.otherAssets = [] ∧
    r.refundAddress = none ∧ r.submittedAt = none ∧ r.contents.applicationTags = [])

/-- Exact declared contents, with one singular tag and its bound trie-ready
tag. Carrier ada remains a declaration, with no ledger minimum guarantee. -/
def terminationExactContents (c : Config) (r : TerminationRequest) : Bool :=
  terminationContentsShape c r &&
  decide (r.registryId = c.registryId ∧ r.singularTags = [c.singularTag r.key] ∧
    r.contents.lovelace = terminationDeclaredLovelace r ∧
    r.contents.trieReadyTags = [r.trieReadyTag c])

/-- The actual custody holdings of this key in the registry component. -/
def terminationCustody (registry : RegistryState) (key : Key) : List Holding :=
  registry.held.filter fun h => h.key == key && h.kind == .active

/-- Refuse malformed contents, forged tags and absent custody separately.
The supplied custody input must be exactly the one held singular tag. A tag
already carried by a pending request is no longer in these holdings. The one
minimum tip is checked through the contents; no clock participates. -/
def terminationBookingRefusal (registry : RegistryState) (b : TerminationBooking) : Option String :=
  let c := registry.config
  let r := b.request
  if !terminationContentsShape c r || r.contents.lovelace < terminationDeclaredLovelace r then
    some "dirty-request"
  else if terminationDeclaredLovelace r < r.contents.lovelace then
    some "hidden-surplus"
  else if !decide (r.registryId = c.registryId ∧ r.singularTags = [c.singularTag r.key]) then
    some "forged-singular-tag"
  else if !decide (r.contents.trieReadyTags = [r.trieReadyTag c] ∧ b.trieReadyTagsMinted = [r.trieReadyTag c]) then
    some "forged-trie-ready-tag"
  else if !decide (trieGet registry.trie r.key = .known .active) ||
      (terminationCustody registry r.key).isEmpty then
    some "singular-tag-not-in-custody"
  else if !decide (b.custodyInputs = terminationCustody registry r.key ∧ b.custodyInputs.length = 1) then
    some "forged-singular-tag"
  else none

end Singular
