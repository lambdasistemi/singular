import NoPin.Held.Good
import NoPin.Held.Statements

/-! Executed finite instances under #741, not accepted law. General statements
retain sorry; these propositions mirror their compiled types. -/
set_option maxRecDepth 8192
set_option maxHeartbeats 2000000
namespace NoPin.Held.Instances
open Singular Fixtures

/-- Hypothesis instance under #741, not accepted law; explicit finite hash observation. -/
abbrev testHash : Hash := NoPin.lookupHash hashes

/-- Hypothesis instance under #741, not accepted law; liveUpdate case premise. -/
abbrev liveUpdate_inversion_premise (_m : Mutation) (_hash : Hash) (_code : Codec) (q : Query) : Prop := q.surface = .liveUpdate
/-- Hypothesis instance under #741, not accepted law; full liveUpdate conditions. -/
abbrev liveUpdate_inversion_claim (m : Mutation) (hash : Hash) (code : Codec) (q : Query) : Prop :=
  runWith m hash code q = true ↔ expectedWith hash code q = true
/-- Executed antecedent of the #741 hypothesis, not accepted law. -/
theorem liveUpdate_inversion_antecedent : liveUpdate_inversion_premise .none testHash encode (goodQuery .liveUpdate) := by rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem liveUpdate_inversion_liveUpdate_candidate : liveUpdate_inversion_premise .none testHash encode (goodQuery .liveUpdate) → liveUpdate_inversion_claim .none testHash encode (goodQuery .liveUpdate) := by
  intro _
  rfl

/-- Hypothesis instance under #741, not accepted law; liveRelease case premise. -/
abbrev liveRelease_inversion_premise (_m : Mutation) (_hash : Hash) (_code : Codec) (q : Query) : Prop := q.surface = .liveRelease
/-- Hypothesis instance under #741, not accepted law; full liveRelease conditions. -/
abbrev liveRelease_inversion_claim (m : Mutation) (hash : Hash) (code : Codec) (q : Query) : Prop :=
  runWith m hash code q = true ↔ expectedWith hash code q = true
/-- Executed antecedent of the #741 hypothesis, not accepted law. -/
theorem liveRelease_inversion_antecedent : liveRelease_inversion_premise .none testHash encode (goodQuery .liveRelease) := by rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem liveRelease_inversion_liveRelease_candidate : liveRelease_inversion_premise .none testHash encode (goodQuery .liveRelease) → liveRelease_inversion_claim .none testHash encode (goodQuery .liveRelease) := by
  intro _
  rfl

/-- Hypothesis instance under #741, not accepted law; genuine case premise. -/
abbrev genuine_inversion_premise (_m : Mutation) (_hash : Hash) (_code : Codec) (q : Query) : Prop := q.surface = .genuine
/-- Hypothesis instance under #741, not accepted law; full genuine conditions. -/
abbrev genuine_inversion_claim (m : Mutation) (hash : Hash) (code : Codec) (q : Query) : Prop :=
  runWith m hash code q = true ↔ expectedWith hash code q = true
/-- Executed antecedent of the #741 hypothesis, not accepted law. -/
theorem genuine_inversion_antecedent : genuine_inversion_premise .none testHash encode (goodQuery .genuine) := by rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem genuine_inversion_ownToken_candidate : genuine_inversion_premise .none testHash encode (goodQuery .genuine) → genuine_inversion_claim .none testHash encode (goodQuery .genuine) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem genuine_inversion_quantity_candidate : genuine_inversion_premise .none testHash encode (goodQuery .genuine) → genuine_inversion_claim .none testHash encode (goodQuery .genuine) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem genuine_inversion_provenance_candidate : genuine_inversion_premise .none testHash encode (goodQuery .genuine) → genuine_inversion_claim .none testHash encode (goodQuery .genuine) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem genuine_inversion_rootKey_candidate : genuine_inversion_premise .none testHash encode (goodQuery .genuine) → genuine_inversion_claim .none testHash encode (goodQuery .genuine) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem genuine_inversion_rootKind_candidate : genuine_inversion_premise .none testHash encode (goodQuery .genuine) → genuine_inversion_claim .none testHash encode (goodQuery .genuine) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem genuine_inversion_pendingReference_candidate : genuine_inversion_premise .none testHash encode (goodQuery .genuine) → genuine_inversion_claim .none testHash encode (goodQuery .genuine) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem genuine_inversion_pendingValue_candidate : genuine_inversion_premise .none testHash encode (goodQuery .genuine) → genuine_inversion_claim .none testHash encode (goodQuery .genuine) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem genuine_inversion_pendingContents_candidate : genuine_inversion_premise .none testHash encode (goodQuery .genuine) → genuine_inversion_claim .none testHash encode (goodQuery .genuine) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem genuine_inversion_pendingCustody_candidate : genuine_inversion_premise .none testHash encode (goodQuery .genuine) → genuine_inversion_claim .none testHash encode (goodQuery .genuine) := by
  intro _
  rfl

/-- Hypothesis instance under #741, not accepted law; booking case premise. -/
abbrev booking_inversion_premise (_m : Mutation) (_hash : Hash) (_code : Codec) (q : Query) : Prop := q.surface = .booking
/-- Hypothesis instance under #741, not accepted law; full booking conditions. -/
abbrev booking_inversion_claim (m : Mutation) (hash : Hash) (code : Codec) (q : Query) : Prop :=
  runWith m hash code q = true ↔ expectedWith hash code q = true
/-- Executed antecedent of the #741 hypothesis, not accepted law. -/
theorem booking_inversion_antecedent : booking_inversion_premise .none testHash encode (goodQuery .booking) := by rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem booking_inversion_sourceMember_candidate : booking_inversion_premise .none testHash encode (goodQuery .booking) → booking_inversion_claim .none testHash encode (goodQuery .booking) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem booking_inversion_bookLive_candidate : booking_inversion_premise .none testHash encode (goodQuery .booking) → booking_inversion_claim .none testHash encode (goodQuery .booking) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem booking_inversion_bookSigner_candidate : booking_inversion_premise .none testHash encode (goodQuery .booking) → booking_inversion_claim .none testHash encode (goodQuery .booking) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem booking_inversion_bookFamily_candidate : booking_inversion_premise .none testHash encode (goodQuery .booking) → booking_inversion_claim .none testHash encode (goodQuery .booking) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem booking_inversion_bookControl_candidate : booking_inversion_premise .none testHash encode (goodQuery .booking) → booking_inversion_claim .none testHash encode (goodQuery .booking) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem booking_inversion_bookToken_candidate : booking_inversion_premise .none testHash encode (goodQuery .booking) → booking_inversion_claim .none testHash encode (goodQuery .booking) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem booking_inversion_bookPayload_candidate : booking_inversion_premise .none testHash encode (goodQuery .booking) → booking_inversion_claim .none testHash encode (goodQuery .booking) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem booking_inversion_bookReference_candidate : booking_inversion_premise .none testHash encode (goodQuery .booking) → booking_inversion_claim .none testHash encode (goodQuery .booking) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem booking_inversion_bookValue_candidate : booking_inversion_premise .none testHash encode (goodQuery .booking) → booking_inversion_claim .none testHash encode (goodQuery .booking) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem booking_inversion_bookDeposit_candidate : booking_inversion_premise .none testHash encode (goodQuery .booking) → booking_inversion_claim .none testHash encode (goodQuery .booking) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem booking_inversion_bookRoot_candidate : booking_inversion_premise .none testHash encode (goodQuery .booking) → booking_inversion_claim .none testHash encode (goodQuery .booking) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem booking_inversion_bookBinding_candidate : booking_inversion_premise .none testHash encode (goodQuery .booking) → booking_inversion_claim .none testHash encode (goodQuery .booking) := by
  intro _
  rfl

/-- Hypothesis instance under #741, not accepted law; rebooking case premise. -/
abbrev rebooking_inversion_premise (_m : Mutation) (_hash : Hash) (_code : Codec) (q : Query) : Prop := q.surface = .rebooking
/-- Hypothesis instance under #741, not accepted law; full rebooking conditions. -/
abbrev rebooking_inversion_claim (m : Mutation) (hash : Hash) (code : Codec) (q : Query) : Prop :=
  runWith m hash code q = true ↔ expectedWith hash code q = true
/-- Executed antecedent of the #741 hypothesis, not accepted law. -/
theorem rebooking_inversion_antecedent : rebooking_inversion_premise .none testHash encode (goodQuery .rebooking) := by rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem rebooking_inversion_rebooking_candidate : rebooking_inversion_premise .none testHash encode (goodQuery .rebooking) → rebooking_inversion_claim .none testHash encode (goodQuery .rebooking) := by
  intro _
  rfl

/-- Hypothesis instance under #741, not accepted law; pendingRelease case premise. -/
abbrev pendingRelease_inversion_premise (_m : Mutation) (_hash : Hash) (_code : Codec) (q : Query) : Prop := q.surface = .pendingRelease
/-- Hypothesis instance under #741, not accepted law; full pendingRelease conditions. -/
abbrev pendingRelease_inversion_claim (m : Mutation) (hash : Hash) (code : Codec) (q : Query) : Prop :=
  runWith m hash code q = true ↔ expectedWith hash code q = true
/-- Executed antecedent of the #741 hypothesis, not accepted law. -/
theorem pendingRelease_inversion_antecedent : pendingRelease_inversion_premise .none testHash encode (goodQuery .pendingRelease) := by rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem pendingRelease_inversion_releaseGenuine_candidate : pendingRelease_inversion_premise .none testHash encode (goodQuery .pendingRelease) → pendingRelease_inversion_claim .none testHash encode (goodQuery .pendingRelease) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem pendingRelease_inversion_releaseSpent_candidate : pendingRelease_inversion_premise .none testHash encode (goodQuery .pendingRelease) → pendingRelease_inversion_claim .none testHash encode (goodQuery .pendingRelease) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem pendingRelease_inversion_releaseOnce_candidate : pendingRelease_inversion_premise .none testHash encode (goodQuery .pendingRelease) → pendingRelease_inversion_claim .none testHash encode (goodQuery .pendingRelease) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem pendingRelease_inversion_releaseBurn_candidate : pendingRelease_inversion_premise .none testHash encode (goodQuery .pendingRelease) → pendingRelease_inversion_claim .none testHash encode (goodQuery .pendingRelease) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem pendingRelease_inversion_releasePayments_candidate : pendingRelease_inversion_premise .none testHash encode (goodQuery .pendingRelease) → pendingRelease_inversion_claim .none testHash encode (goodQuery .pendingRelease) := by
  intro _
  rfl

/-- Hypothesis instance under #741, not accepted law; projection case premise. -/
abbrev projection_inversion_premise (_m : Mutation) (_hash : Hash) (_code : Codec) (q : Query) : Prop := q.surface = .projection
/-- Hypothesis instance under #741, not accepted law; full projection conditions. -/
abbrev projection_inversion_claim (m : Mutation) (hash : Hash) (code : Codec) (q : Query) : Prop :=
  runWith m hash code q = true ↔ expectedWith hash code q = true
/-- Executed antecedent of the #741 hypothesis, not accepted law. -/
theorem projection_inversion_antecedent : projection_inversion_premise .none testHash encode (goodQuery .projection) := by rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem projection_inversion_projectionLive_candidate : projection_inversion_premise .none testHash encode (goodQuery .projection) → projection_inversion_claim .none testHash encode (goodQuery .projection) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem projection_inversion_projectionPending_candidate : projection_inversion_premise .none testHash encode (goodQuery .projection) → projection_inversion_claim .none testHash encode (goodQuery .projection) := by
  intro _
  rfl

/-- Hypothesis instance under #741, not accepted law; coupling case premise. -/
abbrev coupling_inversion_premise (_m : Mutation) (_hash : Hash) (_code : Codec) (q : Query) : Prop := q.surface = .coupling
/-- Hypothesis instance under #741, not accepted law; full coupling conditions. -/
abbrev coupling_inversion_claim (m : Mutation) (hash : Hash) (code : Codec) (q : Query) : Prop :=
  runWith m hash code q = true ↔ expectedWith hash code q = true
/-- Executed antecedent of the #741 hypothesis, not accepted law. -/
theorem coupling_inversion_antecedent : coupling_inversion_premise .none testHash encode (goodQuery .coupling) := by rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem coupling_inversion_couplingObservation_candidate : coupling_inversion_premise .none testHash encode (goodQuery .coupling) → coupling_inversion_claim .none testHash encode (goodQuery .coupling) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem coupling_inversion_couplingFold_candidate : coupling_inversion_premise .none testHash encode (goodQuery .coupling) → coupling_inversion_claim .none testHash encode (goodQuery .coupling) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem coupling_inversion_couplingSelected_candidate : coupling_inversion_premise .none testHash encode (goodQuery .coupling) → coupling_inversion_claim .none testHash encode (goodQuery .coupling) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem coupling_inversion_couplingTerminal_candidate : coupling_inversion_premise .none testHash encode (goodQuery .coupling) → coupling_inversion_claim .none testHash encode (goodQuery .coupling) := by
  intro _
  rfl

/-- Hypothesis instance under #741, not accepted law; discovery case premise. -/
abbrev discovery_inversion_premise (_m : Mutation) (_hash : Hash) (_code : Codec) (q : Query) : Prop := q.surface = .discovery
/-- Hypothesis instance under #741, not accepted law; full discovery conditions. -/
abbrev discovery_inversion_claim (m : Mutation) (hash : Hash) (code : Codec) (q : Query) : Prop :=
  runWith m hash code q = true ↔ expectedWith hash code q = true
/-- Executed antecedent of the #741 hypothesis, not accepted law. -/
theorem discovery_inversion_antecedent : discovery_inversion_premise .none testHash encode (goodQuery .discovery) := by rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem discovery_inversion_discoveryPending_candidate : discovery_inversion_premise .none testHash encode (goodQuery .discovery) → discovery_inversion_claim .none testHash encode (goodQuery .discovery) := by
  intro _
  rfl

/-- Hypothesis instance under #741, not accepted law; consumption case premise. -/
abbrev consumption_inversion_premise (_m : Mutation) (_hash : Hash) (_code : Codec) (q : Query) : Prop := q.surface = .consumption
/-- Hypothesis instance under #741, not accepted law; full consumption conditions. -/
abbrev consumption_inversion_claim (m : Mutation) (hash : Hash) (code : Codec) (q : Query) : Prop :=
  runWith m hash code q = true ↔ expectedWith hash code q = true
/-- Executed antecedent of the #741 hypothesis, not accepted law. -/
theorem consumption_inversion_antecedent : consumption_inversion_premise .none testHash encode (goodQuery .consumption) := by rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem consumption_inversion_consumptionReference_candidate : consumption_inversion_premise .none testHash encode (goodQuery .consumption) → consumption_inversion_claim .none testHash encode (goodQuery .consumption) := by
  intro _
  have rhs : expectedWith testHash encode (goodQuery .consumption) = true := by
    change (([.pending (pending 8 7), .pending (pending 7 5)] : List LockedOutput).contains
      (.pending (pending 7 5)) && true) = true
    simp
  exact ⟨fun _ => rhs, fun _ => good_positive .consumption⟩

/-- Hypothesis instance under #741, not accepted law; economicAvailability case premise. -/
abbrev economicAvailability_inversion_premise (_m : Mutation) (_hash : Hash) (_code : Codec) (q : Query) : Prop := q.surface = .economicAvailability
/-- Hypothesis instance under #741, not accepted law; full economicAvailability conditions. -/
abbrev economicAvailability_inversion_claim (m : Mutation) (hash : Hash) (code : Codec) (q : Query) : Prop :=
  runWith m hash code q = true ↔ expectedWith hash code q = true
/-- Executed antecedent of the #741 hypothesis, not accepted law. -/
theorem economicAvailability_inversion_antecedent : economicAvailability_inversion_premise .none testHash encode (goodQuery .economicAvailability) := by rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem economicAvailability_inversion_availabilityAccepted_candidate : economicAvailability_inversion_premise .none testHash encode (goodQuery .economicAvailability) → economicAvailability_inversion_claim .none testHash encode (goodQuery .economicAvailability) := by
  intro _
  rfl

/-- Hypothesis instance under #741, not accepted law; partition case premise. -/
abbrev partition_inversion_premise (_m : Mutation) (_hash : Hash) (_code : Codec) (q : Query) : Prop := q.surface = .partition
/-- Hypothesis instance under #741, not accepted law; full partition conditions. -/
abbrev partition_inversion_claim (m : Mutation) (hash : Hash) (code : Codec) (q : Query) : Prop :=
  runWith m hash code q = true ↔ expectedWith hash code q = true
/-- Executed antecedent of the #741 hypothesis, not accepted law. -/
theorem partition_inversion_antecedent : partition_inversion_premise .none testHash encode (goodQuery .partition) := by rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem partition_inversion_partitionInputs_candidate : partition_inversion_premise .none testHash encode (goodQuery .partition) → partition_inversion_claim .none testHash encode (goodQuery .partition) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem partition_inversion_partitionOutputs_candidate : partition_inversion_premise .none testHash encode (goodQuery .partition) → partition_inversion_claim .none testHash encode (goodQuery .partition) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem partition_inversion_partitionDistinct_candidate : partition_inversion_premise .none testHash encode (goodQuery .partition) → partition_inversion_claim .none testHash encode (goodQuery .partition) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem partition_inversion_partitionIndices_candidate : partition_inversion_premise .none testHash encode (goodQuery .partition) → partition_inversion_claim .none testHash encode (goodQuery .partition) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem partition_inversion_partitionController_candidate : partition_inversion_premise .none testHash encode (goodQuery .partition) → partition_inversion_claim .none testHash encode (goodQuery .partition) := by
  intro _
  rfl

/-- Hypothesis instance under #741, not accepted law; composed case premise. -/
abbrev composed_inversion_premise (_m : Mutation) (_hash : Hash) (_code : Codec) (q : Query) : Prop := q.surface = .composed
/-- Hypothesis instance under #741, not accepted law; full composed conditions. -/
abbrev composed_inversion_claim (m : Mutation) (hash : Hash) (code : Codec) (q : Query) : Prop :=
  runWith m hash code q = true ↔ expectedWith hash code q = true
/-- Executed antecedent of the #741 hypothesis, not accepted law. -/
theorem composed_inversion_antecedent : composed_inversion_premise .none testHash encode (goodQuery .composed) := by rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem composed_inversion_composedEconomic_candidate : composed_inversion_premise .none testHash encode (goodQuery .composed) → composed_inversion_claim .none testHash encode (goodQuery .composed) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem composed_inversion_composedPartition_candidate : composed_inversion_premise .none testHash encode (goodQuery .composed) → composed_inversion_claim .none testHash encode (goodQuery .composed) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem composed_inversion_composedBalance_candidate : composed_inversion_premise .none testHash encode (goodQuery .composed) → composed_inversion_claim .none testHash encode (goodQuery .composed) := by
  intro _
  rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem composed_inversion_composedLocal_candidate : composed_inversion_premise .none testHash encode (goodQuery .composed) → composed_inversion_claim .none testHash encode (goodQuery .composed) := by
  intro _
  rfl

/-- Hypothesis instance under #741, not accepted law; rejection case premise. -/
abbrev rejection_inversion_premise (_m : Mutation) (_hash : Hash) (_code : Codec) (q : Query) : Prop := q.surface = .rejection
/-- Hypothesis instance under #741, not accepted law; full rejection conditions. -/
abbrev rejection_inversion_claim (m : Mutation) (hash : Hash) (code : Codec) (q : Query) : Prop :=
  runWith m hash code q = true ↔ expectedWith hash code q = true
/-- Executed antecedent of the #741 hypothesis, not accepted law. -/
theorem rejection_inversion_antecedent : rejection_inversion_premise .none testHash encode (goodQuery .rejection) := by rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem rejection_inversion_rejectionDecision_candidate : rejection_inversion_premise .none testHash encode (goodQuery .rejection) → rejection_inversion_claim .none testHash encode (goodQuery .rejection) := by
  intro _
  rfl

/-- Hypothesis instance under #741, not accepted law; permanent case premise. -/
abbrev permanent_inversion_premise (_m : Mutation) (_hash : Hash) (_code : Codec) (q : Query) : Prop := q.surface = .permanent
/-- Hypothesis instance under #741, not accepted law; full permanent conditions. -/
abbrev permanent_inversion_claim (m : Mutation) (hash : Hash) (code : Codec) (q : Query) : Prop :=
  runWith m hash code q = true ↔ expectedWith hash code q = true
/-- Executed antecedent of the #741 hypothesis, not accepted law. -/
theorem permanent_inversion_antecedent : permanent_inversion_premise .none testHash encode (goodQuery .permanent) := by rfl

/-- Executed candidate instance of the #741 hypothesis, not accepted law. -/
theorem permanent_inversion_permanentDecision_candidate : permanent_inversion_premise .none testHash encode (goodQuery .permanent) → permanent_inversion_claim .none testHash encode (goodQuery .permanent) := by
  intro _
  rfl

end NoPin.Held.Instances
