import NoPin.ApplicationRequests.MoneyFoldProofs

/-! Hypothetical journey statements; frozen types, with finite evidence kept separate. -/
namespace NoPin.ApplicationRequests.Money.Statements
open Singular Lean

/-- Hypothesis under #741, not accepted law. Status: PROVED.
create journey: independent phase, custody, value and recipient obligations. -/
theorem create_journey (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : NewPremise h c t decode release .create q) :
    NewClaim .none h c t decode release .create q := by
  exact Proofs.simple_journey h c t decode release .create q _premises (by decide) (by decide)

/-- Hypothesis under #741, not accepted law. Status: PROVED.
registration booking journey: independent phase, custody, value and recipient obligations. -/
theorem registration_booking_journey (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : NewPremise h c t decode release .registrationBooking q) :
    NewClaim .none h c t decode release .registrationBooking q := by
  exact Proofs.simple_journey h c t decode release .registrationBooking q _premises (by decide) (by decide)

/-- Hypothesis under #741, not accepted law. Status: REFUTED.
registration fold journey: independent phase, custody, value and recipient obligations. -/
theorem registration_fold_journey (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : NewPremise h c t decode release .registrationFold q) :
    NewClaim .none h c t decode release .registrationFold q := by sorry

/-- Hypothesis under #741, not accepted law. Status: PROVED.
update journey: independent phase, custody, value and recipient obligations. -/
theorem update_journey (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : NewPremise h c t decode release .update q) :
    NewClaim .none h c t decode release .update q := by
  exact Proofs.simple_journey h c t decode release .update q _premises (by decide) (by decide)

/-- Hypothesis under #741, not accepted law. Status: PROVED.
termination booking journey: independent phase, custody, value and recipient obligations. -/
theorem termination_booking_journey (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : NewPremise h c t decode release .terminationBooking q) :
    NewClaim .none h c t decode release .terminationBooking q := by
  exact Proofs.simple_journey h c t decode release .terminationBooking q _premises (by decide) (by decide)

/-- Hypothesis under #741, not accepted law. Status: PROVED.
termination fold journey: independent phase, custody, value and recipient obligations. -/
theorem termination_fold_journey (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : NewPremise h c t decode release .terminationFold q) :
    NewClaim .none h c t decode release .terminationFold q := by
  exact Proofs.termination_journey h c t decode release q _premises

/-- Hypothesis under #741, not accepted law. Status: PROVED.
reclaim journey: independent phase, custody, value and recipient obligations. -/
theorem reclaim_journey (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : NewPremise h c t decode release .reclaim q) :
    NewClaim .none h c t decode release .reclaim q := by
  exact Proofs.simple_journey h c t decode release .reclaim q _premises (by decide) (by decide)

/-- Hypothesis under #741, not accepted law. Status: PROVED.
cleanup journey: independent phase, custody, value and recipient obligations. -/
theorem cleanup_journey (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : NewPremise h c t decode release .cleanup q) :
    NewClaim .none h c t decode release .cleanup q := by
  exact Proofs.simple_journey h c t decode release .cleanup q _premises (by decide) (by decide)

/-- Hypothesis under #741, not accepted law. Status: PROVED.
The old amounts are read through the accepted fold and refund producers. -/
theorem accepted_economic_allocations (q : Input) (_premises : OldPremise q) :
    OldClaim .none q := by
  exact Proofs.old_allocations q _premises

/-- Hypothesis under #741, not accepted law. Status: PROVED.
Every party/stage cell is equal or has the exact recorded economic change. -/
theorem journey_allocations (journey : Journey) (q : Input) (_premises : Correspondence q) :
    AllDifferences .none journey q := by
  exact Proofs.allocations journey q _premises

/-- Hypothesis under #741, not accepted law. Status: PROVED.
The retained consumer requires the controller for an update. -/
theorem accepted_update_authority (world : OpenDatumApplication.World) (ref : Nat)
    (successors : List OpenDatumApplication.Successor) (signers : List Nat)
    (_premises : OldUpdatePremise world ref signers) :
    OldUpdateClaim .none world ref successors signers := by
  exact Proofs.old_unsigned world ref successors signers _premises

end NoPin.ApplicationRequests.Money.Statements
