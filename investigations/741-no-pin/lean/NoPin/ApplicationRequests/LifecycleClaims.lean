import NoPin.ApplicationRequests.Lifecycle

namespace NoPin.ApplicationRequests.Lifecycle
open Singular Lean
/-- Hypothesis under #741, not accepted law. -/
def burnOnlyEffect (release : PublishedRelease) (o : ApplicationObservation) : Bool :=
  if o.actions.all (· == .approvalBurn) then
    o.inputs.all (fun input => input.credential != release.applicationCredential) &&
    o.assets.mint.all (fun entry => entry.1.policy != release.applicationPolicy || NoPin.mintQty o.assets entry.1 ≤ 0)
  else true
/-- Hypothesis under #741, not accepted law. -/
abbrev configurationCreate_inversion_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := actionName q.action = "configurationCreate"
/-- Hypothesis under #741, not accepted law. -/
abbrev configurationCreate_inversion_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  (applicationStep m h c decode release q.observation = true ∧ applicationAction m h c decode release q.observation q.action = true) ↔
    (applicationStepConditions h c decode release q.observation = true ∧ applicationActionConditions h c decode release q.observation q.action = true)
/-- Hypothesis under #741, not accepted law. -/
abbrev bookRegistration_inversion_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := actionName q.action = "bookRegistration"
/-- Hypothesis under #741, not accepted law. -/
abbrev bookRegistration_inversion_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  (applicationStep m h c decode release q.observation = true ∧ applicationAction m h c decode release q.observation q.action = true) ↔
    (applicationStepConditions h c decode release q.observation = true ∧ applicationActionConditions h c decode release q.observation q.action = true)
/-- Hypothesis under #741, not accepted law. -/
abbrev bookTermination_inversion_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := actionName q.action = "bookTermination"
/-- Hypothesis under #741, not accepted law. -/
abbrev bookTermination_inversion_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  (applicationStep m h c decode release q.observation = true ∧ applicationAction m h c decode release q.observation q.action = true) ↔
    (applicationStepConditions h c decode release q.observation = true ∧ applicationActionConditions h c decode release q.observation q.action = true)
/-- Hypothesis under #741, not accepted law. -/
abbrev registrationFold_inversion_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := actionName q.action = "registrationFold"
/-- Hypothesis under #741, not accepted law. -/
abbrev registrationFold_inversion_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  (applicationStep m h c decode release q.observation = true ∧ applicationAction m h c decode release q.observation q.action = true) ↔
    (applicationStepConditions h c decode release q.observation = true ∧ applicationActionConditions h c decode release q.observation q.action = true)
/-- Hypothesis under #741, not accepted law. -/
abbrev ownerReclaim_inversion_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := actionName q.action = "ownerReclaim"
/-- Hypothesis under #741, not accepted law. -/
abbrev ownerReclaim_inversion_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  (applicationStep m h c decode release q.observation = true ∧ applicationAction m h c decode release q.observation q.action = true) ↔
    (applicationStepConditions h c decode release q.observation = true ∧ applicationActionConditions h c decode release q.observation q.action = true)
/-- Hypothesis under #741, not accepted law. -/
abbrev expiredCleanup_inversion_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := actionName q.action = "expiredCleanup"
/-- Hypothesis under #741, not accepted law. -/
abbrev expiredCleanup_inversion_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  (applicationStep m h c decode release q.observation = true ∧ applicationAction m h c decode release q.observation q.action = true) ↔
    (applicationStepConditions h c decode release q.observation = true ∧ applicationActionConditions h c decode release q.observation q.action = true)
/-- Hypothesis under #741, not accepted law. -/
abbrev terminationFold_inversion_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := actionName q.action = "terminationFold"
/-- Hypothesis under #741, not accepted law. -/
abbrev terminationFold_inversion_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  (applicationStep m h c decode release q.observation = true ∧ applicationAction m h c decode release q.observation q.action = true) ↔
    (applicationStepConditions h c decode release q.observation = true ∧ applicationActionConditions h c decode release q.observation q.action = true)
/-- Hypothesis under #741, not accepted law. -/
abbrev liveUpdate_inversion_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := actionName q.action = "liveUpdate"
/-- Hypothesis under #741, not accepted law. -/
abbrev liveUpdate_inversion_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  (applicationStep m h c decode release q.observation = true ∧ applicationAction m h c decode release q.observation q.action = true) ↔
    (applicationStepConditions h c decode release q.observation = true ∧ applicationActionConditions h c decode release q.observation q.action = true)
/-- Hypothesis under #741, not accepted law. -/
abbrev approvalBurn_inversion_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := actionName q.action = "approvalBurn"
/-- Hypothesis under #741, not accepted law. -/
abbrev approvalBurn_inversion_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  (applicationStep m h c decode release q.observation = true ∧ applicationAction m h c decode release q.observation q.action = true) ↔
    (applicationStepConditions h c decode release q.observation = true ∧ applicationActionConditions h c decode release q.observation q.action = true)
/-- Hypothesis under #741, not accepted law. -/
abbrev registration_lifecycle_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := True
/-- Hypothesis under #741, not accepted law. -/
abbrev registration_lifecycle_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  applicationStep m h c decode release q.observation = true ↔
    applicationStepConditions h c decode release q.observation = true ∧ registrationEffects h c decode q.observation = true
/-- Hypothesis under #741, not accepted law. -/
abbrev termination_burn_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := True
/-- Hypothesis under #741, not accepted law. -/
abbrev termination_burn_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  applicationStep m h c decode release q.observation = true ↔
    applicationStepConditions h c decode release q.observation = true ∧ terminationEffects h c q.observation = true
/-- Hypothesis under #741, not accepted law. -/
abbrev booking_authority_and_parameters_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := True
/-- Hypothesis under #741, not accepted law. -/
abbrev booking_authority_and_parameters_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  applicationStep m h c decode release q.observation = true ↔
    applicationStepConditions h c decode release q.observation = true ∧ bookingEffects h c decode release q.observation = true
/-- Hypothesis under #741, not accepted law. -/
abbrev treasury_at_booking_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := True
/-- Hypothesis under #741, not accepted law. -/
abbrev treasury_at_booking_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  applicationStep m h c decode release q.observation = true ↔
    applicationStepConditions h c decode release q.observation = true ∧ treasuryEffect decode q.observation = true
/-- Hypothesis under #741, not accepted law. -/
abbrev additive_payments_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := True
/-- Hypothesis under #741, not accepted law. -/
abbrev additive_payments_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  applicationStep m h c decode release q.observation = true ↔
    applicationStepConditions h c decode release q.observation = true ∧ paymentEffects decode q.observation = true
/-- Hypothesis under #741, not accepted law. -/
abbrev folder_protection_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := True
/-- Hypothesis under #741, not accepted law. -/
abbrev folder_protection_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  applicationStep m h c decode release q.observation = true ↔
    applicationStepConditions h c decode release q.observation = true ∧ folderProtection h c decode release q.observation = true
/-- Hypothesis under #741, not accepted law. -/
abbrev burning_grants_nothing_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := True
/-- Hypothesis under #741, not accepted law. -/
abbrev burning_grants_nothing_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  applicationStep m h c decode release q.observation = true ↔
    applicationStepConditions h c decode release q.observation = true ∧ burnOnlyEffect release q.observation = true
/-- Hypothesis under #741, not accepted law. -/
abbrev no_stuck_termination_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := TerminationPremises h c t q
/-- Hypothesis under #741, not accepted law. -/
abbrev no_stuck_termination_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := terminationAvailable m h c t q

/-- Hypothesis under #741, not accepted law. -/
def configurationProtected (release : PublishedRelease) (o : ApplicationObservation) : Bool :=
  o.inputs.all fun input => input.credential != release.applicationCredential ||
    match input.datum with | .configuration _ => false | _ => true
/-- Hypothesis under #741, not accepted law. -/
abbrev approval_burn_open_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := q.observation.inputs = [] ∧ q.observation.actions = [.approvalBurn] ∧ q.observation.donation = 0 ∧
    q.observation.assets.mint.all (fun entry => entry.1.policy != release.applicationPolicy || NoPin.mintQty q.observation.assets entry.1 ≤ 0) = true
/-- Hypothesis under #741, not accepted law. -/
abbrev approval_burn_open_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := applicationStep m h c decode release q.observation = true
/-- Hypothesis under #741, not accepted law. -/
abbrev configuration_immutable_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := True
/-- Hypothesis under #741, not accepted law. -/
abbrev configuration_immutable_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := applicationStep m h c decode release q.observation = true ↔
    applicationStepConditions h c decode release q.observation = true ∧ configurationProtected release q.observation = true

end NoPin.ApplicationRequests.Lifecycle
