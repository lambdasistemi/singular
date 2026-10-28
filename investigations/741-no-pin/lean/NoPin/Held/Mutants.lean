import NoPin.Held.Instances

/-! Single atomic-guard falsifications of #741 hypotheses, not accepted law. -/
set_option maxRecDepth 8192
set_option maxHeartbeats 2000000
namespace NoPin.Held.Mutants
open Singular Fixtures Instances

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem liveUpdate_inversion_liveUpdate_mutant : ¬ (liveUpdate_inversion_premise (.flip .liveUpdate) testHash encode (goodQuery .liveUpdate) →
    liveUpdate_inversion_claim (.flip .liveUpdate) testHash encode (goodQuery .liveUpdate)) := by
  have relation := liveUpdate_inversion_liveUpdate_candidate liveUpdate_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .liveUpdate) = true :=
    relation.mp (good_positive .liveUpdate)
  have flippedFalse : runWith (.flip .liveUpdate) testHash encode (goodQuery .liveUpdate) = false := by
    have positive := good_positive .liveUpdate
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [liveSpend, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem liveRelease_inversion_liveRelease_mutant : ¬ (liveRelease_inversion_premise (.flip .liveRelease) testHash encode (goodQuery .liveRelease) →
    liveRelease_inversion_claim (.flip .liveRelease) testHash encode (goodQuery .liveRelease)) := by
  have relation := liveRelease_inversion_liveRelease_candidate liveRelease_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .liveRelease) = true :=
    relation.mp (good_positive .liveRelease)
  have flippedFalse : runWith (.flip .liveRelease) testHash encode (goodQuery .liveRelease) = false := by
    have positive := good_positive .liveRelease
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [liveSpend, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem genuine_inversion_ownToken_mutant : ¬ (genuine_inversion_premise (.flip .ownToken) testHash encode (goodQuery .genuine) →
    genuine_inversion_claim (.flip .ownToken) testHash encode (goodQuery .genuine)) := by
  have relation := genuine_inversion_ownToken_candidate genuine_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .genuine) = true :=
    relation.mp (good_positive .genuine)
  have flippedFalse : runWith (.flip .ownToken) testHash encode (goodQuery .genuine) = false := by
    have positive := good_positive .genuine
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [genuine, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem genuine_inversion_quantity_mutant : ¬ (genuine_inversion_premise (.flip .quantity) testHash encode (goodQuery .genuine) →
    genuine_inversion_claim (.flip .quantity) testHash encode (goodQuery .genuine)) := by
  have relation := genuine_inversion_quantity_candidate genuine_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .genuine) = true :=
    relation.mp (good_positive .genuine)
  have flippedFalse : runWith (.flip .quantity) testHash encode (goodQuery .genuine) = false := by
    have positive := good_positive .genuine
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [genuine, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem genuine_inversion_provenance_mutant : ¬ (genuine_inversion_premise (.flip .provenance) testHash encode (goodQuery .genuine) →
    genuine_inversion_claim (.flip .provenance) testHash encode (goodQuery .genuine)) := by
  have relation := genuine_inversion_provenance_candidate genuine_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .genuine) = true :=
    relation.mp (good_positive .genuine)
  have flippedFalse : runWith (.flip .provenance) testHash encode (goodQuery .genuine) = false := by
    have positive := good_positive .genuine
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [genuine, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem genuine_inversion_rootKey_mutant : ¬ (genuine_inversion_premise (.flip .rootKey) testHash encode (goodQuery .genuine) →
    genuine_inversion_claim (.flip .rootKey) testHash encode (goodQuery .genuine)) := by
  have relation := genuine_inversion_rootKey_candidate genuine_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .genuine) = true :=
    relation.mp (good_positive .genuine)
  have flippedFalse : runWith (.flip .rootKey) testHash encode (goodQuery .genuine) = false := by
    have positive := good_positive .genuine
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [genuine, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem genuine_inversion_rootKind_mutant : ¬ (genuine_inversion_premise (.flip .rootKind) testHash encode (goodQuery .genuine) →
    genuine_inversion_claim (.flip .rootKind) testHash encode (goodQuery .genuine)) := by
  have relation := genuine_inversion_rootKind_candidate genuine_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .genuine) = true :=
    relation.mp (good_positive .genuine)
  have flippedFalse : runWith (.flip .rootKind) testHash encode (goodQuery .genuine) = false := by
    have positive := good_positive .genuine
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [genuine, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem genuine_inversion_pendingReference_mutant : ¬ (genuine_inversion_premise (.flip .pendingReference) testHash encode (goodQuery .genuine) →
    genuine_inversion_claim (.flip .pendingReference) testHash encode (goodQuery .genuine)) := by
  have relation := genuine_inversion_pendingReference_candidate genuine_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .genuine) = true :=
    relation.mp (good_positive .genuine)
  have flippedFalse : runWith (.flip .pendingReference) testHash encode (goodQuery .genuine) = false := by
    have positive := good_positive .genuine
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [genuine, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem genuine_inversion_pendingValue_mutant : ¬ (genuine_inversion_premise (.flip .pendingValue) testHash encode (goodQuery .genuine) →
    genuine_inversion_claim (.flip .pendingValue) testHash encode (goodQuery .genuine)) := by
  have relation := genuine_inversion_pendingValue_candidate genuine_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .genuine) = true :=
    relation.mp (good_positive .genuine)
  have flippedFalse : runWith (.flip .pendingValue) testHash encode (goodQuery .genuine) = false := by
    have positive := good_positive .genuine
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [genuine, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem genuine_inversion_pendingContents_mutant : ¬ (genuine_inversion_premise (.flip .pendingContents) testHash encode (goodQuery .genuine) →
    genuine_inversion_claim (.flip .pendingContents) testHash encode (goodQuery .genuine)) := by
  have relation := genuine_inversion_pendingContents_candidate genuine_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .genuine) = true :=
    relation.mp (good_positive .genuine)
  have flippedFalse : runWith (.flip .pendingContents) testHash encode (goodQuery .genuine) = false := by
    have positive := good_positive .genuine
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [genuine, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem genuine_inversion_pendingCustody_mutant : ¬ (genuine_inversion_premise (.flip .pendingCustody) testHash encode (goodQuery .genuine) →
    genuine_inversion_claim (.flip .pendingCustody) testHash encode (goodQuery .genuine)) := by
  have relation := genuine_inversion_pendingCustody_candidate genuine_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .genuine) = true :=
    relation.mp (good_positive .genuine)
  have flippedFalse : runWith (.flip .pendingCustody) testHash encode (goodQuery .genuine) = false := by
    have positive := good_positive .genuine
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [genuine, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem booking_inversion_sourceMember_mutant : ¬ (booking_inversion_premise (.flip .sourceMember) testHash encode (goodQuery .booking) →
    booking_inversion_claim (.flip .sourceMember) testHash encode (goodQuery .booking)) := by
  have relation := booking_inversion_sourceMember_candidate booking_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .booking) = true :=
    relation.mp (good_positive .booking)
  have flippedFalse : runWith (.flip .sourceMember) testHash encode (goodQuery .booking) = false := by
    have positive := good_positive .booking
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [book, applyGuard, Guard.ctorIdx, reduceBEq]
    <;> decide +kernel
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem booking_inversion_bookLive_mutant : ¬ (booking_inversion_premise (.flip .bookLive) testHash encode (goodQuery .booking) →
    booking_inversion_claim (.flip .bookLive) testHash encode (goodQuery .booking)) := by
  have relation := booking_inversion_bookLive_candidate booking_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .booking) = true :=
    relation.mp (good_positive .booking)
  have flippedFalse : runWith (.flip .bookLive) testHash encode (goodQuery .booking) = false := by
    have positive := good_positive .booking
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [book, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem booking_inversion_bookSigner_mutant : ¬ (booking_inversion_premise (.flip .bookSigner) testHash encode (goodQuery .booking) →
    booking_inversion_claim (.flip .bookSigner) testHash encode (goodQuery .booking)) := by
  have relation := booking_inversion_bookSigner_candidate booking_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .booking) = true :=
    relation.mp (good_positive .booking)
  have flippedFalse : runWith (.flip .bookSigner) testHash encode (goodQuery .booking) = false := by
    have positive := good_positive .booking
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [book, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem booking_inversion_bookFamily_mutant : ¬ (booking_inversion_premise (.flip .bookFamily) testHash encode (goodQuery .booking) →
    booking_inversion_claim (.flip .bookFamily) testHash encode (goodQuery .booking)) := by
  have relation := booking_inversion_bookFamily_candidate booking_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .booking) = true :=
    relation.mp (good_positive .booking)
  have flippedFalse : runWith (.flip .bookFamily) testHash encode (goodQuery .booking) = false := by
    have positive := good_positive .booking
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [book, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem booking_inversion_bookControl_mutant : ¬ (booking_inversion_premise (.flip .bookControl) testHash encode (goodQuery .booking) →
    booking_inversion_claim (.flip .bookControl) testHash encode (goodQuery .booking)) := by
  have relation := booking_inversion_bookControl_candidate booking_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .booking) = true :=
    relation.mp (good_positive .booking)
  have flippedFalse : runWith (.flip .bookControl) testHash encode (goodQuery .booking) = false := by
    have positive := good_positive .booking
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [book, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem booking_inversion_bookToken_mutant : ¬ (booking_inversion_premise (.flip .bookToken) testHash encode (goodQuery .booking) →
    booking_inversion_claim (.flip .bookToken) testHash encode (goodQuery .booking)) := by
  have relation := booking_inversion_bookToken_candidate booking_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .booking) = true :=
    relation.mp (good_positive .booking)
  have flippedFalse : runWith (.flip .bookToken) testHash encode (goodQuery .booking) = false := by
    have positive := good_positive .booking
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [book, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem booking_inversion_bookPayload_mutant : ¬ (booking_inversion_premise (.flip .bookPayload) testHash encode (goodQuery .booking) →
    booking_inversion_claim (.flip .bookPayload) testHash encode (goodQuery .booking)) := by
  have relation := booking_inversion_bookPayload_candidate booking_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .booking) = true :=
    relation.mp (good_positive .booking)
  have flippedFalse : runWith (.flip .bookPayload) testHash encode (goodQuery .booking) = false := by
    have positive := good_positive .booking
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [book, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem booking_inversion_bookReference_mutant : ¬ (booking_inversion_premise (.flip .bookReference) testHash encode (goodQuery .booking) →
    booking_inversion_claim (.flip .bookReference) testHash encode (goodQuery .booking)) := by
  have relation := booking_inversion_bookReference_candidate booking_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .booking) = true :=
    relation.mp (good_positive .booking)
  have flippedFalse : runWith (.flip .bookReference) testHash encode (goodQuery .booking) = false := by
    have positive := good_positive .booking
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [book, applyGuard, Guard.ctorIdx, reduceBEq]
    <;> decide +kernel
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem booking_inversion_bookValue_mutant : ¬ (booking_inversion_premise (.flip .bookValue) testHash encode (goodQuery .booking) →
    booking_inversion_claim (.flip .bookValue) testHash encode (goodQuery .booking)) := by
  have relation := booking_inversion_bookValue_candidate booking_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .booking) = true :=
    relation.mp (good_positive .booking)
  have flippedFalse : runWith (.flip .bookValue) testHash encode (goodQuery .booking) = false := by
    have positive := good_positive .booking
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [book, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem booking_inversion_bookDeposit_mutant : ¬ (booking_inversion_premise (.flip .bookDeposit) testHash encode (goodQuery .booking) →
    booking_inversion_claim (.flip .bookDeposit) testHash encode (goodQuery .booking)) := by
  have relation := booking_inversion_bookDeposit_candidate booking_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .booking) = true :=
    relation.mp (good_positive .booking)
  have flippedFalse : runWith (.flip .bookDeposit) testHash encode (goodQuery .booking) = false := by
    have positive := good_positive .booking
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [book, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem booking_inversion_bookRoot_mutant : ¬ (booking_inversion_premise (.flip .bookRoot) testHash encode (goodQuery .booking) →
    booking_inversion_claim (.flip .bookRoot) testHash encode (goodQuery .booking)) := by
  have relation := booking_inversion_bookRoot_candidate booking_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .booking) = true :=
    relation.mp (good_positive .booking)
  have flippedFalse : runWith (.flip .bookRoot) testHash encode (goodQuery .booking) = false := by
    have positive := good_positive .booking
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [book, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem booking_inversion_bookBinding_mutant : ¬ (booking_inversion_premise (.flip .bookBinding) testHash encode (goodQuery .booking) →
    booking_inversion_claim (.flip .bookBinding) testHash encode (goodQuery .booking)) := by
  have relation := booking_inversion_bookBinding_candidate booking_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .booking) = true :=
    relation.mp (good_positive .booking)
  have flippedFalse : runWith (.flip .bookBinding) testHash encode (goodQuery .booking) = false := by
    have positive := good_positive .booking
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [book, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem rebooking_inversion_rebooking_mutant : ¬ (rebooking_inversion_premise (.flip .rebooking) testHash encode (goodQuery .rebooking) →
    rebooking_inversion_claim (.flip .rebooking) testHash encode (goodQuery .rebooking)) := by
  have relation := rebooking_inversion_rebooking_candidate rebooking_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .rebooking) = true :=
    relation.mp (good_positive .rebooking)
  have flippedFalse : runWith (.flip .rebooking) testHash encode (goodQuery .rebooking) = false := by
    have positive := good_positive .rebooking
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [book, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem pendingRelease_inversion_releaseGenuine_mutant : ¬ (pendingRelease_inversion_premise (.flip .releaseGenuine) testHash encode (goodQuery .pendingRelease) →
    pendingRelease_inversion_claim (.flip .releaseGenuine) testHash encode (goodQuery .pendingRelease)) := by
  have relation := pendingRelease_inversion_releaseGenuine_candidate pendingRelease_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .pendingRelease) = true :=
    relation.mp (good_positive .pendingRelease)
  have flippedFalse : runWith (.flip .releaseGenuine) testHash encode (goodQuery .pendingRelease) = false := by
    have positive := good_positive .pendingRelease
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [pendingRelease, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem pendingRelease_inversion_releaseSpent_mutant : ¬ (pendingRelease_inversion_premise (.flip .releaseSpent) testHash encode (goodQuery .pendingRelease) →
    pendingRelease_inversion_claim (.flip .releaseSpent) testHash encode (goodQuery .pendingRelease)) := by
  have relation := pendingRelease_inversion_releaseSpent_candidate pendingRelease_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .pendingRelease) = true :=
    relation.mp (good_positive .pendingRelease)
  have flippedFalse : runWith (.flip .releaseSpent) testHash encode (goodQuery .pendingRelease) = false := by
    have positive := good_positive .pendingRelease
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [pendingRelease, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem pendingRelease_inversion_releaseOnce_mutant : ¬ (pendingRelease_inversion_premise (.flip .releaseOnce) testHash encode (goodQuery .pendingRelease) →
    pendingRelease_inversion_claim (.flip .releaseOnce) testHash encode (goodQuery .pendingRelease)) := by
  have relation := pendingRelease_inversion_releaseOnce_candidate pendingRelease_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .pendingRelease) = true :=
    relation.mp (good_positive .pendingRelease)
  have flippedFalse : runWith (.flip .releaseOnce) testHash encode (goodQuery .pendingRelease) = false := by
    have positive := good_positive .pendingRelease
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [pendingRelease, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem pendingRelease_inversion_releaseBurn_mutant : ¬ (pendingRelease_inversion_premise (.flip .releaseBurn) testHash encode (goodQuery .pendingRelease) →
    pendingRelease_inversion_claim (.flip .releaseBurn) testHash encode (goodQuery .pendingRelease)) := by
  have relation := pendingRelease_inversion_releaseBurn_candidate pendingRelease_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .pendingRelease) = true :=
    relation.mp (good_positive .pendingRelease)
  have flippedFalse : runWith (.flip .releaseBurn) testHash encode (goodQuery .pendingRelease) = false := by
    have positive := good_positive .pendingRelease
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [pendingRelease, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem pendingRelease_inversion_releasePayments_mutant : ¬ (pendingRelease_inversion_premise (.flip .releasePayments) testHash encode (goodQuery .pendingRelease) →
    pendingRelease_inversion_claim (.flip .releasePayments) testHash encode (goodQuery .pendingRelease)) := by
  have relation := pendingRelease_inversion_releasePayments_candidate pendingRelease_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .pendingRelease) = true :=
    relation.mp (good_positive .pendingRelease)
  have flippedFalse : runWith (.flip .releasePayments) testHash encode (goodQuery .pendingRelease) = false := by
    have positive := good_positive .pendingRelease
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [pendingRelease, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem projection_inversion_projectionLive_mutant : ¬ (projection_inversion_premise (.flip .projectionLive) testHash encode (goodQuery .projection) →
    projection_inversion_claim (.flip .projectionLive) testHash encode (goodQuery .projection)) := by
  have relation := projection_inversion_projectionLive_candidate projection_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .projection) = true :=
    relation.mp (good_positive .projection)
  have flippedFalse : runWith (.flip .projectionLive) testHash encode (goodQuery .projection) = false := by
    decide +kernel
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem projection_inversion_projectionPending_mutant : ¬ (projection_inversion_premise (.flip .projectionPending) testHash encode (goodQuery .projection) →
    projection_inversion_claim (.flip .projectionPending) testHash encode (goodQuery .projection)) := by
  have relation := projection_inversion_projectionPending_candidate projection_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .projection) = true :=
    relation.mp (good_positive .projection)
  have flippedFalse : runWith (.flip .projectionPending) testHash encode (goodQuery .projection) = false := by
    decide +kernel
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem coupling_inversion_couplingObservation_mutant : ¬ (coupling_inversion_premise (.flip .couplingObservation) testHash encode (goodQuery .coupling) →
    coupling_inversion_claim (.flip .couplingObservation) testHash encode (goodQuery .coupling)) := by
  have relation := coupling_inversion_couplingObservation_candidate coupling_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .coupling) = true :=
    relation.mp (good_positive .coupling)
  have flippedFalse : runWith (.flip .couplingObservation) testHash encode (goodQuery .coupling) = false := by
    decide +kernel
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem coupling_inversion_couplingFold_mutant : ¬ (coupling_inversion_premise (.flip .couplingFold) testHash encode (goodQuery .coupling) →
    coupling_inversion_claim (.flip .couplingFold) testHash encode (goodQuery .coupling)) := by
  have relation := coupling_inversion_couplingFold_candidate coupling_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .coupling) = true :=
    relation.mp (good_positive .coupling)
  have flippedFalse : runWith (.flip .couplingFold) testHash encode (goodQuery .coupling) = false := by
    have positive := good_positive .coupling
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [couplingCheck, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem coupling_inversion_couplingSelected_mutant : ¬ (coupling_inversion_premise (.flip .couplingSelected) testHash encode (goodQuery .coupling) →
    coupling_inversion_claim (.flip .couplingSelected) testHash encode (goodQuery .coupling)) := by
  have relation := coupling_inversion_couplingSelected_candidate coupling_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .coupling) = true :=
    relation.mp (good_positive .coupling)
  have flippedFalse : runWith (.flip .couplingSelected) testHash encode (goodQuery .coupling) = false := by
    have positive := good_positive .coupling
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [couplingCheck, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem coupling_inversion_couplingTerminal_mutant : ¬ (coupling_inversion_premise (.flip .couplingTerminal) testHash encode (goodQuery .coupling) →
    coupling_inversion_claim (.flip .couplingTerminal) testHash encode (goodQuery .coupling)) := by
  have relation := coupling_inversion_couplingTerminal_candidate coupling_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .coupling) = true :=
    relation.mp (good_positive .coupling)
  have flippedFalse : runWith (.flip .couplingTerminal) testHash encode (goodQuery .coupling) = false := by
    have positive := good_positive .coupling
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [couplingCheck, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem discovery_inversion_discoveryPending_mutant : ¬ (discovery_inversion_premise (.flip .discoveryPending) testHash encode (goodQuery .discovery) →
    discovery_inversion_claim (.flip .discoveryPending) testHash encode (goodQuery .discovery)) := by
  have relation := discovery_inversion_discoveryPending_candidate discovery_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .discovery) = true :=
    relation.mp (good_positive .discovery)
  have flippedFalse : runWith (.flip .discoveryPending) testHash encode (goodQuery .discovery) = false := by
    decide +kernel
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem consumption_inversion_consumptionReference_mutant : ¬ (consumption_inversion_premise (.flip .consumptionReference) testHash encode (goodQuery .consumption) →
    consumption_inversion_claim (.flip .consumptionReference) testHash encode (goodQuery .consumption)) := by
  have relation := consumption_inversion_consumptionReference_candidate consumption_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .consumption) = true :=
    relation.mp (good_positive .consumption)
  have flippedFalse : runWith (.flip .consumptionReference) testHash encode (goodQuery .consumption) = false := by
    decide +kernel
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem economicAvailability_inversion_availabilityAccepted_mutant : ¬ (economicAvailability_inversion_premise (.flip .availabilityAccepted) testHash encode (goodQuery .economicAvailability) →
    economicAvailability_inversion_claim (.flip .availabilityAccepted) testHash encode (goodQuery .economicAvailability)) := by
  have relation := economicAvailability_inversion_availabilityAccepted_candidate economicAvailability_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .economicAvailability) = true :=
    relation.mp (good_positive .economicAvailability)
  have flippedFalse : runWith (.flip .availabilityAccepted) testHash encode (goodQuery .economicAvailability) = false := by
    have positive := good_positive .economicAvailability
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [economicAvailability, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem partition_inversion_partitionInputs_mutant : ¬ (partition_inversion_premise (.flip .partitionInputs) testHash encode (goodQuery .partition) →
    partition_inversion_claim (.flip .partitionInputs) testHash encode (goodQuery .partition)) := by
  have relation := partition_inversion_partitionInputs_candidate partition_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .partition) = true :=
    relation.mp (good_positive .partition)
  have flippedFalse : runWith (.flip .partitionInputs) testHash encode (goodQuery .partition) = false := by
    decide +kernel
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem partition_inversion_partitionOutputs_mutant : ¬ (partition_inversion_premise (.flip .partitionOutputs) testHash encode (goodQuery .partition) →
    partition_inversion_claim (.flip .partitionOutputs) testHash encode (goodQuery .partition)) := by
  have relation := partition_inversion_partitionOutputs_candidate partition_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .partition) = true :=
    relation.mp (good_positive .partition)
  have flippedFalse : runWith (.flip .partitionOutputs) testHash encode (goodQuery .partition) = false := by
    decide +kernel
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem partition_inversion_partitionDistinct_mutant : ¬ (partition_inversion_premise (.flip .partitionDistinct) testHash encode (goodQuery .partition) →
    partition_inversion_claim (.flip .partitionDistinct) testHash encode (goodQuery .partition)) := by
  have relation := partition_inversion_partitionDistinct_candidate partition_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .partition) = true :=
    relation.mp (good_positive .partition)
  have flippedFalse : runWith (.flip .partitionDistinct) testHash encode (goodQuery .partition) = false := by
    decide +kernel
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem partition_inversion_partitionIndices_mutant : ¬ (partition_inversion_premise (.flip .partitionIndices) testHash encode (goodQuery .partition) →
    partition_inversion_claim (.flip .partitionIndices) testHash encode (goodQuery .partition)) := by
  have relation := partition_inversion_partitionIndices_candidate partition_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .partition) = true :=
    relation.mp (good_positive .partition)
  have flippedFalse : runWith (.flip .partitionIndices) testHash encode (goodQuery .partition) = false := by
    decide +kernel
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem partition_inversion_partitionController_mutant : ¬ (partition_inversion_premise (.flip .partitionController) testHash encode (goodQuery .partition) →
    partition_inversion_claim (.flip .partitionController) testHash encode (goodQuery .partition)) := by
  have relation := partition_inversion_partitionController_candidate partition_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .partition) = true :=
    relation.mp (good_positive .partition)
  have flippedFalse : runWith (.flip .partitionController) testHash encode (goodQuery .partition) = false := by
    decide +kernel
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem composed_inversion_composedEconomic_mutant : ¬ (composed_inversion_premise (.flip .composedEconomic) testHash encode (goodQuery .composed) →
    composed_inversion_claim (.flip .composedEconomic) testHash encode (goodQuery .composed)) := by
  have relation := composed_inversion_composedEconomic_candidate composed_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .composed) = true :=
    relation.mp (good_positive .composed)
  have flippedFalse : runWith (.flip .composedEconomic) testHash encode (goodQuery .composed) = false := by
    have positive := good_positive .composed
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [composedWith, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem composed_inversion_composedPartition_mutant : ¬ (composed_inversion_premise (.flip .composedPartition) testHash encode (goodQuery .composed) →
    composed_inversion_claim (.flip .composedPartition) testHash encode (goodQuery .composed)) := by
  have relation := composed_inversion_composedPartition_candidate composed_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .composed) = true :=
    relation.mp (good_positive .composed)
  have flippedFalse : runWith (.flip .composedPartition) testHash encode (goodQuery .composed) = false := by
    have positive := good_positive .composed
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [composedWith, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem composed_inversion_composedBalance_mutant : ¬ (composed_inversion_premise (.flip .composedBalance) testHash encode (goodQuery .composed) →
    composed_inversion_claim (.flip .composedBalance) testHash encode (goodQuery .composed)) := by
  have relation := composed_inversion_composedBalance_candidate composed_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .composed) = true :=
    relation.mp (good_positive .composed)
  have flippedFalse : runWith (.flip .composedBalance) testHash encode (goodQuery .composed) = false := by
    have positive := good_positive .composed
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [composedWith, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem composed_inversion_composedLocal_mutant : ¬ (composed_inversion_premise (.flip .composedLocal) testHash encode (goodQuery .composed) →
    composed_inversion_claim (.flip .composedLocal) testHash encode (goodQuery .composed)) := by
  have relation := composed_inversion_composedLocal_candidate composed_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .composed) = true :=
    relation.mp (good_positive .composed)
  have flippedFalse : runWith (.flip .composedLocal) testHash encode (goodQuery .composed) = false := by
    have positive := good_positive .composed
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [composedWith, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem rejection_inversion_rejectionDecision_mutant : ¬ (rejection_inversion_premise (.flip .rejectionDecision) testHash encode (goodQuery .rejection) →
    rejection_inversion_claim (.flip .rejectionDecision) testHash encode (goodQuery .rejection)) := by
  have relation := rejection_inversion_rejectionDecision_candidate rejection_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .rejection) = true :=
    relation.mp (good_positive .rejection)
  have flippedFalse : runWith (.flip .rejectionDecision) testHash encode (goodQuery .rejection) = false := by
    have positive := good_positive .rejection
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [rejected, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

/-- Executed one-guard violation of the #741 hypothesis, not accepted law. -/
theorem permanent_inversion_permanentDecision_mutant : ¬ (permanent_inversion_premise (.flip .permanentDecision) testHash encode (goodQuery .permanent) →
    permanent_inversion_claim (.flip .permanentDecision) testHash encode (goodQuery .permanent)) := by
  have relation := permanent_inversion_permanentDecision_candidate permanent_inversion_antecedent
  have expectedTrue : expectedWith testHash encode (goodQuery .permanent) = true :=
    relation.mp (good_positive .permanent)
  have flippedFalse : runWith (.flip .permanentDecision) testHash encode (goodQuery .permanent) = false := by
    have positive := good_positive .permanent
    simp [runWith, runQuery, goodQuery, Case.ctorIdx, reduceBEq] at positive ⊢
    simp_all [permanent, applyGuard, Guard.ctorIdx, reduceBEq]
  intro accepted
  have impossible := (accepted rfl).mpr expectedTrue
  rw [flippedFalse] at impossible
  cases impossible

end NoPin.Held.Mutants
