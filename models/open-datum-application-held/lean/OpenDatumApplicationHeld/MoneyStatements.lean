import OpenDatumApplicationHeld.MoneyHoldingClaims
import OpenDatumApplicationHeld.MoneyUpdateClaims

namespace OpenDatumApplicationHeld.Money.Statements
open Singular Lean SingularApplicationHeld

theorem create_journey (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : NewPremise h c t decode release .create q) :
    NewClaim .none h c t decode release .create q := by sorry

theorem registration_booking_journey (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : NewPremise h c t decode release .registrationBooking q) :
    NewClaim .none h c t decode release .registrationBooking q := by sorry

theorem update_journey (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : NewPremise h c t decode release .update q) :
    NewClaim .none h c t decode release .update q := by sorry

theorem termination_booking_journey (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : NewPremise h c t decode release .terminationBooking q) :
    NewClaim .none h c t decode release .terminationBooking q := by sorry

theorem termination_fold_journey (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : NewPremise h c t decode release .terminationFold q) :
    NewClaim .none h c t decode release .terminationFold q := by sorry

theorem reclaim_journey (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : NewPremise h c t decode release .reclaim q) :
    NewClaim .none h c t decode release .reclaim q := by sorry

theorem cleanup_journey (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (_premises : NewPremise h c t decode release .cleanup q) :
    NewClaim .none h c t decode release .cleanup q := by sorry

theorem accepted_economic_allocations (q : Input) (_premises : OldPremise q) :
    OldClaim .none q := by sorry

theorem journey_allocations (journey : Journey) (q : Input) (_premises : Correspondence q) :
    AllDifferences .none journey q := by sorry

theorem accepted_update_authority (world : OpenDatumApplication.World) (ref : Nat)
    (successors : List OpenDatumApplication.Successor) (signers : List Nat)
    (_premises : OldUpdatePremise world ref signers) :
    OldUpdateClaim .none world ref successors signers := by sorry

theorem update_both_models (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input) (world : OpenDatumApplication.World) (reference : Nat)
    (successor : OpenDatumApplication.Successor) (signers : List Nat)
    (_premises : UpdatePremise h c t decode release q world reference successor signers) :
    UpdateClaim .none h c t decode release q world reference successor signers := by sorry

theorem registration_fold_journey_holding_separated (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (release : PublishedRelease) (q : Input)
    (_premises : NewPremise h c t decode release .registrationFold q) :
    HoldingSeparatedClaim .none h c t decode release q := by sorry

end OpenDatumApplicationHeld.Money.Statements
