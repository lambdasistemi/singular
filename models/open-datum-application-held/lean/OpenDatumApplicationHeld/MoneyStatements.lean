import OpenDatumApplicationHeld.MoneyHoldingProofs
import OpenDatumApplicationHeld.MoneyUpdateClaims

namespace OpenDatumApplicationHeld.Money.Statements
open Singular Lean SingularApplicationHeld

theorem create_journey (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : NewPremise h c t decode release .create q) :
    NewClaim .none h c t decode release .create q := by
  exact Proofs.simple_journey h c t decode release .create q _premises (by decide) (by decide)

theorem registration_booking_journey (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : NewPremise h c t decode release .registrationBooking q) :
    NewClaim .none h c t decode release .registrationBooking q := by
  exact Proofs.simple_journey h c t decode release .registrationBooking q _premises (by decide) (by decide)

theorem update_journey (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : NewPremise h c t decode release .update q) :
    NewClaim .none h c t decode release .update q := by
  exact Proofs.simple_journey h c t decode release .update q _premises (by decide) (by decide)

theorem termination_booking_journey (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : NewPremise h c t decode release .terminationBooking q) :
    NewClaim .none h c t decode release .terminationBooking q := by
  exact Proofs.simple_journey h c t decode release .terminationBooking q _premises (by decide) (by decide)

theorem termination_fold_journey (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : NewPremise h c t decode release .terminationFold q) :
    NewClaim .none h c t decode release .terminationFold q := by
  exact Proofs.termination_journey h c t decode release q _premises

theorem reclaim_journey (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : NewPremise h c t decode release .reclaim q) :
    NewClaim .none h c t decode release .reclaim q := by
  exact Proofs.simple_journey h c t decode release .reclaim q _premises (by decide) (by decide)

theorem cleanup_journey (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : NewPremise h c t decode release .cleanup q) :
    NewClaim .none h c t decode release .cleanup q := by
  exact Proofs.simple_journey h c t decode release .cleanup q _premises (by decide) (by decide)

theorem accepted_economic_allocations (q : Input) (_premises : OldPremise q) :
    OldClaim .none q := by
  exact Proofs.old_allocations q _premises

theorem journey_allocations (journey : Journey) (q : Input) (_premises : Correspondence q) :
    AllDifferences .none journey q := by
  exact Proofs.allocations journey q _premises

theorem accepted_update_authority (world : OpenDatumApplication.World) (ref : Nat)
    (successors : List OpenDatumApplication.Successor) (signers : List Nat)
    (_premises : OldUpdatePremise world ref signers) :
    OldUpdateClaim .none world ref successors signers := by
  exact Proofs.old_unsigned world ref successors signers _premises

theorem update_both_models (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input) (world : OpenDatumApplication.World) (reference : Nat)
    (successor : OpenDatumApplication.Successor) (signers : List Nat)
    (_premises : UpdatePremise h c t decode release q world reference successor signers) :
    UpdateClaim .none h c t decode release q world reference successor signers := by
  have current := Proofs.simple_journey h c t decode release .update q _premises.1 (by decide) (by decide)
  have oldAccepted := _premises.2.1
  cases result : oldUpdate .none world reference [successor] signers with
  | error why => simp [result, Except.isOk, Except.toBool] at oldAccepted
  | ok after =>
    have accepted : OpenDatumApplication.updateStep OpenDatumApplication.Law.standard
        world reference [successor] signers = .ok after := by
      simpa [oldUpdate, amountAt, OpenDatumApplication.Law.standard] using result
    obtain ⟨before, selected, found, signed, carrying, address, control, assets, deposit, effect⟩ :=
      (OpenDatumApplication.Statements.update_inversion world after reference [successor] signers).mp accepted
    have member : selected ∈ ([successor].filter fun x =>
        OpenDatumApplication.carriesKey x.assets before.envelope.control.key) := by
      rw [carrying]
      simp
    have same := List.mem_singleton.mp (List.mem_filter.mp member).1
    subst selected
    refine ⟨current, after, result, before,
      ⟨world.nextRef, successor.address, successor.lovelace, successor.assets, successor.envelope⟩,
      found, ?_, control, assets, rfl, deposit⟩
    rw [effect]
    exact List.mem_append_right _ List.mem_cons_self

theorem registration_fold_journey_holding_separated (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (release : PublishedRelease) (q : Input)
    (_premises : NewPremise h c t decode release .registrationFold q) :
    HoldingSeparatedClaim .none h c t decode release q := by
  exact Proofs.registration_holding_journey h c t decode release q _premises

end OpenDatumApplicationHeld.Money.Statements
