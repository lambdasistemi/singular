import NoPin.Held.Strong

/-! Kernel-checked one-guard violations of the #741 hypotheses, not accepted law.
Each refusal control uses the same violating input with the production selector. -/
set_option maxRecDepth 8192
set_option maxHeartbeats 2000000
namespace NoPin.Held.Mutants
open Singular Fixtures Instances

/-- Executed #741 one-guard violation, not accepted law. -/
theorem pending_paths_refused_liveUpdate_mutant : ¬ (pending_paths_refused_premise (.flip .liveUpdate) hash encode two (pending 7 5) (pending 8 7) [] → pending_paths_refused_claim (.flip .liveUpdate) hash encode two (pending 7 5) (pending 8 7) []) := by decide +kernel

/-- Executed #741 one-guard violation, not accepted law; unauthorized controller is admitted. -/
theorem booking_retains_bookSigner_mutant : ¬ (booking_retains_premise (.flip .bookSigner) hash encode before (holding 7 5) (pending 7 5) noSigner → booking_retains_claim (.flip .bookSigner) hash encode before (holding 7 5) (pending 7 5) noSigner) := by
  have changed : book (.flip .bookSigner) hash encode before (.live (holding 7 5)) (pending 7 5) noSigner = true := by
    have positive : book .none hash encode before (.live (holding 7 5)) (pending 7 5) [42] = true := good_positive .booking
    simp only [book, applyGuard, noSigner] at positive ⊢
    simp_all [reduceBEq, Guard.ctorIdx]
    <;> decide +kernel
  intro accepted
  have claim := accepted changed
  simpa [noSigner] using claim.1

/-- Executed #741 one-guard violation, not accepted law; zero-quantity token becomes genuine. -/
theorem pending_witness_authentication_quantity_mutant : ¬ (pending_witness_authentication_premise (.flip .quantity) hash encode config wrongQuantity → pending_witness_authentication_claim (.flip .quantity) hash encode config wrongQuantity) := by
  have changed : genuine (.flip .quantity) hash encode config (.pending wrongQuantity) = true := by
    have positive := genuine7_executes
    simp only [genuine, applyGuard, wrongQuantity] at positive ⊢
    simp_all [reduceBEq, Guard.ctorIdx, pending, holding, holdingOf]
  intro accepted
  have claim := accepted changed
  have impossible : (0 : Nat) = 1 := claim.2.1
  cases impossible

/-- Executed #741 one-guard violation, not accepted law; a zero burn cannot prove terminal coupling. -/
theorem release_terminal_releaseBurn_mutant : ¬ (release_terminal_premise (.flip .releaseBurn) hash encode config (pending 7 5) noBurn folded → release_terminal_claim (.flip .releaseBurn) hash encode config (pending 7 5) noBurn folded) := by
  have changed : pendingRelease (.flip .releaseBurn) hash encode config (pending 7 5) noBurn = true := by
    have positive := release7_executes
    simp only [pendingRelease, applyGuard, noBurn] at positive ⊢
    simp_all [reduceBEq, Guard.ctorIdx, mintQty, localPayments]
  have coupling : BurnCoupling (pending 7 5).holding.control.registry (pending 7 5).holding.control.key
      (pending 7 5).holding.token noBurn.assets folded := by
    intro impossible
    have zero : mintQty noBurn.assets (pending 7 5).holding.token = 0 := rfl
    rw [zero] at impossible
    cases impossible
  intro accepted
  have claim := accepted ⟨changed, coupling⟩
  have impossible : (0 : Int) = -1 := claim.1
  cases impossible

/-- Executed #741 one-guard violation, not accepted law; omitted physical payment becomes accepted. -/
theorem additive_settlement_releasePayments_mutant : ¬ (additive_settlement_premise (.flip .releasePayments) hash encode config (pending 7 5) noPayment → additive_settlement_claim (.flip .releasePayments) hash encode config (pending 7 5) noPayment) := by
  have changed : pendingRelease (.flip .releasePayments) hash encode config (pending 7 5) noPayment = true := by
    simp only [pendingRelease, applyGuard, noPayment, reduceBEq, Bool.false_eq_true, ite_false,
      ite_true, genuine7_executes]
    have spent : localTx.spent.contains (pending 7 5) = true := by
      change [pending 7 5, pending 8 7].contains (pending 7 5) = true
      simp
    rw [spent]
    decide +kernel
  intro accepted
  have claim := accepted changed
  have impossible : ¬ additive_settlement_claim (.flip .releasePayments) hash encode config (pending 7 5) noPayment := by decide +kernel
  exact impossible claim

/-- Executed #741 one-guard violation, not accepted law; root acceptance alone cannot close composition. -/
theorem composed_available_composedLocal_mutant : ¬ (composed_available_premise (.flip .composedLocal) hash encode two Fixtures.registry selected 1000 20 1 willing → composed_available_claim (.flip .composedLocal) hash encode two Fixtures.registry selected 1000 20 1 willing) := by
  have changed : composedWith (.flip .composedLocal) hash encode Fixtures.registry selected folded physical = false := by
    have positive := composition_executes
    simp only [composed, composedWith, applyGuard] at positive ⊢
    simp_all [reduceBEq, Guard.ctorIdx]
    <;> decide +kernel
  intro accepted
  have claim := accepted composed_available_antecedent
  have impossible : composedWith (.flip .composedLocal) hash encode Fixtures.registry selected folded physical = true := claim.1
  rw [changed] at impossible
  cases impossible
end NoPin.Held.Mutants
