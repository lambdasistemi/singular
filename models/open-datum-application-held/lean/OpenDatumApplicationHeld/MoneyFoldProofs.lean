import OpenDatumApplicationHeld.MoneyBuilderProofs


namespace OpenDatumApplicationHeld.Money.Proofs
open Singular Lean SingularApplicationHeld
set_option maxHeartbeats 2000000
set_option maxRecDepth 8192

theorem builder_credential (h : Hash) (c : Codec) (t : TrieCommit) (r : PublishedRelease)
    (registry : PublicRegistry) (requests : List PendingRequest) (funding : FoldFunding) :
    (buildFold h c t r registry requests funding).after.state.credential = registry.state.credential := rfl

theorem termination_outcome (h : Hash) (c : Codec) (t : TrieCommit) (q : Input)
    (corr : Correspondence q) (p : FoldPremise h c t .terminationFold q)
    (mint : RefundLifecycle.terminationEffects h c
      (applicationFoldView (builtFor h c t .terminationFold q) [q.termination]) = true) :
    FoldOutcome .none h c t .terminationFold q := by
  let built := builtFor h c t .terminationFold q
  have accepted : fold .none h c t q.lifecycle.query.release built = true := by
    simpa only [fold, SingularApplicationHeld.Proofs.applyGuard_none, foldConditions] using p.1
  have effect := SingularApplicationHeld.Proofs.fold_effect h c t q.lifecycle.query.release built accepted
  refine ⟨accepted, effect, rfl, rfl, ?_, ?_⟩
  · cases ht : q.termination with
    | registration output data => simp [Correspondence, ht] at corr
    | termination output registry key =>
      have changes : built.changes = [.terminate output.reference key] := by
        simp [built, builtFor, reduceBEq, Journey.ctorIdx,
          SingularApplicationHeld.Proofs.public_build_changes,
          SingularApplicationHeld.Proofs.publicPlan, ht]
      constructor
      · rw [effect.1]
        simp [targetBatch, changes, targetTrie, ht, PendingRequest.key]
      · simpa [RefundLifecycle.terminationEffects, applicationFoldView, ht,
          PendingRequest.registry, PendingRequest.key, beq_iff_eq] using mint
  · have outputs := OpenDatumApplicationHeld.Money.Proofs.public_build_outputs h c t q.lifecycle.query.release
      q.lifecycle.query.observation.before [q.termination] q.lifecycle.query.funding
    cases ht : q.termination with
    | registration output data => simp [Correspondence, ht] at corr
    | termination output registry key =>
      have stateCredential : built.after.state.credential = built.before.state.credential := rfl
      have different := p.2.2.2.1
      change q.lifecycle.query.funding.processorAddress ≠ q.lifecycle.query.observation.before.state.credential at different
      change paidTo built.outputs q.lifecycle.query.funding.processorAddress = _
      change built.outputs = _ at outputs
      rw [outputs]
      simp [SingularApplicationHeld.Proofs.publicPlan, ht, paidTo,
        builder_credential, Ne.symm different, newAllocation, amountAt, reduceBEq,
        PendingRequest.bid, List.zipIdx_cons, List.zipIdx_nil]

theorem termination_journey (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (q : Input)
    (p : NewPremise h c t decode release .terminationFold q) :
    NewClaim .none h c t decode release .terminationFold q := by
  have accepted : RefundLifecycle.applicationStep .none h c decode release q.lifecycle.observation = true := by
    rw [RefundLifecycle.Proofs.step_eq]
    exact p.2.2.1
  have ef := effects h c decode release q.lifecycle.observation accepted
  refine ⟨accepted, ef.1, ef.2.1, ef.2.2.1, ef.2.2.2.1, ef.2.2.2.2,
    money_effect h c t decode release .terminationFold q p, allocations .terminationFold q p.1,
    ?_, by trivial, by trivial⟩
  have fp : FoldPremise h c t .terminationFold q := p.2.2.2.2.2.2.1
  apply termination_outcome h c t q p.1 fp
  have observation : q.lifecycle.observation =
      applicationFoldView (builtFor h c t .terminationFold q) [q.termination] := fp.2.1
  rw [← observation]
  exact ef.2.1

end OpenDatumApplicationHeld.Money.Proofs
