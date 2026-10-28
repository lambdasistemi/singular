import OpenDatumApplicationHeld.MoneyClaims


namespace OpenDatumApplicationHeld.Money
open Singular Lean SingularApplicationHeld


abbrev OldUpdateVisible (world after : OpenDatumApplication.World) (reference : Nat)
    (successor : OpenDatumApplication.Successor) : Prop :=
  ∃ before output, OpenDatumApplication.outputAt world reference = some before ∧
    output ∈ after.outputs ∧ output.envelope.control = before.envelope.control ∧
    output.assets = before.assets ∧ output.envelope = successor.envelope ∧
    before.envelope.control.deposit ≤ output.lovelace

abbrev UpdatePremise (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input) (world : OpenDatumApplication.World) (reference : Nat)
    (successor : OpenDatumApplication.Successor) (signers : List Nat) : Prop :=
  NewPremise h c t decode release .update q ∧
  (oldUpdate .none world reference [successor] signers).isOk = true ∧
  ∃ before, OpenDatumApplication.outputAt world reference = some before ∧
    before.envelope.control.deposit = q.deposit

abbrev UpdateClaim (m : Mutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input) (world : OpenDatumApplication.World) (reference : Nat)
    (successor : OpenDatumApplication.Successor) (signers : List Nat) : Prop :=
  NewClaim m h c t decode release .update q ∧
  ∃ after, oldUpdate .none world reference [successor] signers = .ok after ∧
    OldUpdateVisible world after reference successor


end OpenDatumApplicationHeld.Money
