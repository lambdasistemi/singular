import Singular.Model.Termination

/-! A termination booking transfers the genuine singular tag from application
custody. Tag presence and tuple binding do not execute the application's rule. -/

namespace Singular

/-- Approval's historical owner field is canonically zero for a termination.
It encodes the absence of a refund address, not an owner or a signature rule. -/
def terminationApplicationTagValid (c : Config) (r : TerminationRequest)
    (tag : Approval) : Bool :=
  decide (tag.policy = c.applicationPolicy ∧ tag.edge = .updateTerminal ∧
    tag.key = r.key ∧ tag.owner = 0 ∧ tag.destination = r.destination ∧
    tag.assetName = approvalAssetName .updateTerminal r.key 0 r.destination)

def terminationDeclaredLovelace (r : TerminationRequest) : Nat :=
  r.declaredTip + r.carrierAda

def terminationContentsShape (c : Config) (r : TerminationRequest) : Bool :=
  decide (c.minimumTip ≤ r.declaredTip ∧ r.contents.otherAssets = [] ∧
    r.refundAddress = none ∧ r.submittedAt = none)

def terminationApplicationTagsValid (c : Config) (r : TerminationRequest) : Bool :=
  match r.contents.applicationTags with
  | [tag] => terminationApplicationTagValid c r tag
  | _ => false

/-- Exact declared contents, with one singular tag and both bound request
tags. Carrier ada remains a declaration, with no ledger minimum guarantee. -/
def terminationExactContents (c : Config) (r : TerminationRequest) : Bool :=
  terminationContentsShape c r && terminationApplicationTagsValid c r &&
  decide (r.registryId = c.registryId ∧ r.singularTags = [c.singularTag r.key] ∧
    r.contents.lovelace = terminationDeclaredLovelace r ∧
    r.contents.syntaxTags = [c.syntaxTag])

/-- The actual custody holdings of this key in the registry component. -/
def terminationCustody (registry : RegistryState) (key : Key) : List Holding :=
  registry.held.filter fun h => h.key == key && h.kind == .active

/-- Refuse malformed contents, forged tags and absent custody separately.
The supplied custody input must be exactly the one held singular tag. A tag
already carried by a pending request is no longer in these holdings. Neither
the old fee pin nor any clock participates in the judgement. -/
def terminationBookingRefusal (registry : RegistryState) (b : TerminationBooking) : Option String :=
  let c := registry.config
  let r := b.request
  if !terminationContentsShape c r || r.contents.lovelace < terminationDeclaredLovelace r then
    some "dirty-request"
  else if terminationDeclaredLovelace r < r.contents.lovelace then
    some "hidden-surplus"
  else if !decide (r.registryId = c.registryId ∧ r.singularTags = [c.singularTag r.key]) then
    some "forged-singular-tag"
  else if !terminationApplicationTagsValid c r ||
      !decide (b.applicationTagsMinted = r.contents.applicationTags) then
    some "forged-application-tag"
  else if !decide (r.contents.syntaxTags = [c.syntaxTag] ∧ b.syntaxTagsMinted = [c.syntaxTag]) then
    some "forged-syntax-tag"
  else if !decide (trieGet registry.trie r.key = .known .active) ||
      (terminationCustody registry r.key).isEmpty then
    some "singular-tag-not-in-custody"
  else if !decide (b.custodyInputs = terminationCustody registry r.key ∧ b.custodyInputs.length = 1) then
    some "forged-singular-tag"
  else none

end Singular
