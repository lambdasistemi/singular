import Singular.Model.Booking

/-! Exact registration contents and booking admission. The judgement reads the
presented request output and mint, and never constructs its own evidence. -/

namespace Singular

/-- Compare the whole application tuple as well as its abstract commitment.
No injectivity of applicationTagAssetName and no application signature rule is
assumed. Approval keeps its historical declaration name. -/
def registrationApplicationTagValid (c : Config) (r : RegistrationRequest)
    (tag : Approval) : Bool :=
  decide (tag.policy = c.applicationPolicy ∧ tag.edge = .insertActive ∧
    tag.key = r.key ∧ tag.owner = r.refundAddress ∧ tag.destination = r.destination ∧
    tag.assetName = applicationTagAssetName r.key r.refundAddress r.destination r.nonce)

/-- The declared registration allocations, with the tip independent of held
value. The carrier allocation is not derived from whatever value remains. -/
def registrationDeclaredLovelace (r : RegistrationRequest) : Nat :=
  r.registrationCost + r.declaredTip + r.carrierAda

/-- The non-value shape of a registration, excluding the trie-ready tag whose
provenance receives its own refusal reason. There must be exactly one
application tag and no other asset. -/
def registrationContentsShape (c : Config) (r : RegistrationRequest) : Bool :=
  decide (r.registryId = c.registryId ∧ r.registrationCost = c.registrationCost ∧
    c.minimumTip ≤ r.declaredTip ∧ r.contents.otherAssets = []) &&
  match r.contents.applicationTags with
  | [tag] => registrationApplicationTagValid c r tag
  | _ => false

/-- Exactly the declared cost, tip and carrier allocation, and one of each
bound tag. The carrier is the requester's declaration: this rule does not
establish that it equals or covers the ledger's minimum ada. The configuration
pins only the minimum tip, checked against the request's declaration. -/
def exactContents (c : Config) (r : RegistrationRequest) : Bool :=
  registrationContentsShape c r &&
  decide (r.contents.lovelace = registrationDeclaredLovelace r) &&
  decide (r.contents.trieReadyTags = [r.trieReadyTag c])

/-- Registration admission, with a distinct reason for surplus, forged trie-ready
tags, a moved clock and excessive width. The exact application tag held by the
request must be minted in the same booking. Its authorization rule belongs
to its policy, not to this judgement. -/
def registrationBookingRefusal (c : Config) (b : RegistrationBooking) : Option String :=
  let r := b.request
  if !registrationContentsShape c r || r.contents.lovelace < registrationDeclaredLovelace r then
    some "dirty-request"
  else if registrationDeclaredLovelace r < r.contents.lovelace then
    some "hidden-surplus"
  else if !decide (r.contents.trieReadyTags = [r.trieReadyTag c] ∧ b.trieReadyTagsMinted = [r.trieReadyTag c]) then
    some "forged-trie-ready-tag"
  else if !decide (b.applicationTagsMinted = r.contents.applicationTags) then
    some "dirty-request"
  else if !decide b.interval.valid then
    some "invalid-booking-interval"
  else if r.submittedAt != b.interval.upper then
    some "backdated-booking"
  else if c.bookingWidth < b.interval.width then
    some "booking-too-wide"
  else none

end Singular
