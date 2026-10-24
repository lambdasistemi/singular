import NoPin.ApplicationRequests.MoneyEvidence

/-! Hypothetical #741 update comparison, not accepted law. The old consumer
executes its own accepted update; the new side executes the replacement law.
Logical control/deposit correspondence is explicit, with no byte-codec claim. -/
namespace NoPin.ApplicationRequests.Money
open Singular Lean

/-- Hypothesis under #741, not accepted law; observed old output effects, not a repeated judgement. -/
abbrev OldUpdateVisible (world after : OpenDatumApplication.World) (reference : Nat)
    (successor : OpenDatumApplication.Successor) : Prop :=
  ∃ before output, OpenDatumApplication.outputAt world reference = some before ∧
    output ∈ after.outputs ∧ output.envelope.control = before.envelope.control ∧
    output.assets = before.assets ∧ output.envelope = successor.envelope ∧
    before.envelope.control.deposit ≤ output.lovelace
/-- Hypothesis under #741, not accepted law; both actual admissions and the protected-deposit correspondence. -/
abbrev UpdatePremise (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input) (world : OpenDatumApplication.World) (reference : Nat)
    (successor : OpenDatumApplication.Successor) (signers : List Nat) : Prop :=
  NewPremise h c t decode release .update q ∧
  (oldUpdate .none world reference [successor] signers).isOk = true ∧
  ∃ before, OpenDatumApplication.outputAt world reference = some before ∧
    before.envelope.control.deposit = q.deposit
/-- Hypothesis under #741, not accepted law; each model produces its own preserved control and assets. -/
abbrev UpdateClaim (m : Mutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input) (world : OpenDatumApplication.World) (reference : Nat)
    (successor : OpenDatumApplication.Successor) (signers : List Nat) : Prop :=
  NewClaim m h c t decode release .update q ∧
  ∃ after, oldUpdate .none world reference [successor] signers = .ok after ∧
    OldUpdateVisible world after reference successor

namespace Statements
/-- Hypothesis under #741, not accepted law. Status: PROVED.
Both update models preserve protected control, assets and deposit while delivering the proposed payload. -/
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
end Statements

namespace Fixtures
/-- Hypothesis under #741, not accepted law; actual old result, not a typed result state. -/
def oldUpdatedWorld : OpenDatumApplication.World :=
  (oldUpdate .none oldApplicationWorld 0 [oldSuccessor] [42]).toOption.getD oldApplicationWorld
end Fixtures

namespace Evidence
open NoPin.ApplicationRequests.Fixtures
/-- Hypothesis under #741, not accepted law; both producers admit the complete instance. -/
theorem update_both_models_antecedent : UpdatePremise hash code commit decode release (Fixtures.input .update)
    Fixtures.oldApplicationWorld 0 Fixtures.oldSuccessor [42] := by
  exact ⟨update_journey_antecedent, by rfl, Fixtures.oldLive, by rfl, by rfl⟩
/-- Hypothesis under #741, not accepted law; each output comes from its own producer. -/
theorem update_both_models_positive : UpdateClaim .none hash code commit decode release (Fixtures.input .update)
    Fixtures.oldApplicationWorld 0 Fixtures.oldSuccessor [42] := by
  refine ⟨update_journey_positive, Fixtures.oldUpdatedWorld, by rfl, Fixtures.oldLive,
    { Fixtures.oldLive with ref := 1, envelope := Fixtures.oldSuccessor.envelope },
    by rfl, ?_, by rfl, by rfl, by rfl, by decide⟩
  change _ ∈ (Fixtures.oldApplicationWorld.outputs.erase Fixtures.oldLive) ++ [_]
  exact List.mem_append_right _ List.mem_cons_self
/-- Hypothesis under #741, not accepted law; one current update guard falsifies the complete comparison. -/
theorem update_both_models_mutant : ¬ (UpdatePremise hash code commit decode release (Fixtures.input .update)
    Fixtures.oldApplicationWorld 0 Fixtures.oldSuccessor [42] →
    UpdateClaim (.application .updateControl) hash code commit decode release (Fixtures.input .update)
      Fixtures.oldApplicationWorld 0 Fixtures.oldSuccessor [42]) := by
  intro result
  have bad := (result update_both_models_antecedent).1.1
  have refused : RefundApplication.applicationStep (.flip .updateControl) hash code decode release
      (Fixtures.input .update).lifecycle.observation = false := by decide
  have impossible : (false : Bool) = true := refused.symm.trans bad
  cases impossible
end Evidence
end NoPin.ApplicationRequests.Money
