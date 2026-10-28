import OpenDatumApplicationHeld.RefundLifecycle

/-! The application-held open-datum model beside the current one. -/

namespace OpenDatumApplicationHeld.RefundLifecycle
open Singular Lean SingularApplicationHeld

def burnOnlyEffect (release : PublishedRelease) (o : ApplicationObservation) : Bool :=
  if o.actions.all (· == .approvalBurn) then
    o.inputs.all (fun input => input.credential != release.applicationCredential) &&
    o.assets.mint.all (fun entry => entry.1.policy != release.applicationPolicy || SingularApplicationHeld.Assets.mintQty o.assets entry.1 ≤ 0)
  else true

abbrev configurationCreate_inversion_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := actionName q.action = "configurationCreate"

abbrev configurationCreate_inversion_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  (applicationStep m h c decode release q.observation = true ∧ applicationAction m h c decode release q.observation q.action = true) ↔
    (applicationStepConditions h c decode release q.observation = true ∧ applicationActionConditions h c decode release q.observation q.action = true)

abbrev bookRegistration_inversion_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := actionName q.action = "bookRegistration"

abbrev bookRegistration_inversion_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  (applicationStep m h c decode release q.observation = true ∧ applicationAction m h c decode release q.observation q.action = true) ↔
    (applicationStepConditions h c decode release q.observation = true ∧ applicationActionConditions h c decode release q.observation q.action = true)

abbrev bookTermination_inversion_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := actionName q.action = "bookTermination"

abbrev bookTermination_inversion_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  (applicationStep m h c decode release q.observation = true ∧ applicationAction m h c decode release q.observation q.action = true) ↔
    (applicationStepConditions h c decode release q.observation = true ∧ applicationActionConditions h c decode release q.observation q.action = true)

abbrev registrationFold_inversion_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := actionName q.action = "registrationFold"

abbrev registrationFold_inversion_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  (applicationStep m h c decode release q.observation = true ∧ applicationAction m h c decode release q.observation q.action = true) ↔
    (applicationStepConditions h c decode release q.observation = true ∧ applicationActionConditions h c decode release q.observation q.action = true)

abbrev ownerReclaim_inversion_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := actionName q.action = "ownerReclaim"

abbrev ownerReclaim_inversion_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  (applicationStep m h c decode release q.observation = true ∧ applicationAction m h c decode release q.observation q.action = true) ↔
    (applicationStepConditions h c decode release q.observation = true ∧ applicationActionConditions h c decode release q.observation q.action = true)

abbrev expiredCleanup_inversion_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := actionName q.action = "expiredCleanup"

abbrev expiredCleanup_inversion_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  (applicationStep m h c decode release q.observation = true ∧ applicationAction m h c decode release q.observation q.action = true) ↔
    (applicationStepConditions h c decode release q.observation = true ∧ applicationActionConditions h c decode release q.observation q.action = true)

abbrev terminationFold_inversion_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := actionName q.action = "terminationFold"

abbrev terminationFold_inversion_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  (applicationStep m h c decode release q.observation = true ∧ applicationAction m h c decode release q.observation q.action = true) ↔
    (applicationStepConditions h c decode release q.observation = true ∧ applicationActionConditions h c decode release q.observation q.action = true)

abbrev liveUpdate_inversion_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := actionName q.action = "liveUpdate"

abbrev liveUpdate_inversion_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  (applicationStep m h c decode release q.observation = true ∧ applicationAction m h c decode release q.observation q.action = true) ↔
    (applicationStepConditions h c decode release q.observation = true ∧ applicationActionConditions h c decode release q.observation q.action = true)

abbrev approvalBurn_inversion_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := actionName q.action = "approvalBurn"

abbrev approvalBurn_inversion_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  (applicationStep m h c decode release q.observation = true ∧ applicationAction m h c decode release q.observation q.action = true) ↔
    (applicationStepConditions h c decode release q.observation = true ∧ applicationActionConditions h c decode release q.observation q.action = true)

abbrev registration_lifecycle_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := True

abbrev registration_lifecycle_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  applicationStep m h c decode release q.observation = true ↔
    applicationStepConditions h c decode release q.observation = true ∧ registrationEffects h c decode q.observation = true

abbrev termination_burn_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := True

abbrev termination_burn_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  applicationStep m h c decode release q.observation = true ↔
    applicationStepConditions h c decode release q.observation = true ∧ terminationEffects h c q.observation = true

abbrev booking_authority_and_parameters_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := True

abbrev booking_authority_and_parameters_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  applicationStep m h c decode release q.observation = true ↔
    applicationStepConditions h c decode release q.observation = true ∧ bookingEffects h c decode release q.observation = true

abbrev treasury_at_booking_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := True

abbrev treasury_at_booking_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  applicationStep m h c decode release q.observation = true ↔
    applicationStepConditions h c decode release q.observation = true ∧ treasuryEffect decode q.observation = true

abbrev additive_payments_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := True

abbrev additive_payments_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  applicationStep m h c decode release q.observation = true ↔
    applicationStepConditions h c decode release q.observation = true ∧ paymentEffects decode q.observation = true

abbrev folder_protection_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := True

abbrev folder_protection_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  applicationStep m h c decode release q.observation = true ↔
    applicationStepConditions h c decode release q.observation = true ∧ folderProtection h c decode release q.observation = true

abbrev burning_grants_nothing_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := True

abbrev burning_grants_nothing_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  applicationStep m h c decode release q.observation = true ↔
    applicationStepConditions h c decode release q.observation = true ∧ burnOnlyEffect release q.observation = true

abbrev no_stuck_termination_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := TerminationPremises h c t q

abbrev no_stuck_termination_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := terminationAvailable m h c t q


def configurationProtected (release : PublishedRelease) (o : ApplicationObservation) : Bool :=
  o.inputs.all fun input => input.credential != release.applicationCredential ||
    match input.datum with | .configuration _ => false | _ => true

abbrev approval_burn_open_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := q.observation.inputs.all (fun input => input.credential != release.applicationCredential) = true ∧ q.observation.actions = [.approvalBurn] ∧ q.observation.donation = 0 ∧
    q.observation.assets.mint.all (fun entry => entry.1.policy != release.applicationPolicy || SingularApplicationHeld.Assets.mintQty q.observation.assets entry.1 ≤ 0) = true

abbrev approval_burn_open_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := applicationStep m h c decode release q.observation = true

def configurationCreations (registry : TokenId) (actions : List ApplicationAction) : Nat :=
  actions.countP fun action => match action with
    | .configurationCreate created _ _ => created == registry
    | _ => false

abbrev configuration_created_once_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := True

abbrev configuration_created_once_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  applicationStep m h c decode release q.observation = true →
    ∀ registry seed index, ApplicationAction.configurationCreate registry seed index ∈ q.observation.actions →
      configurationCreations registry q.observation.actions = 1 ∧
        SingularApplicationHeld.Assets.mintQty q.observation.assets (configurationAsset h c release registry) = 1

abbrev configuration_immutable_premise (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := True

abbrev configuration_immutable_claim (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop := applicationStep m h c decode release q.observation = true ↔
    applicationStepConditions h c decode release q.observation = true ∧ configurationProtected release q.observation = true

end OpenDatumApplicationHeld.RefundLifecycle
