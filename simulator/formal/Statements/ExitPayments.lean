import Singular.Lemmas
import Singular.Driver
import Singular.Economics

/-! Permissionless folds, deposits, constructed settlement and retraction payment. -/

namespace Singular.Statements

/-- Nobody must sign a fold, at any of the seven edges.

For every state, every request of every edge and every lovelace: a transaction
the model builds requires no signer, and neither the step nor the transaction
changes when the request's approval carries a different signature set. The
empty signer list is therefore a consequence of the law — no refusal and no
edge reads a signature — rather than a default the transaction happens to
carry. -/
theorem fold_requires_no_signer (s : RegistryState) (r : Request) (lovelace : Nat)
    (sigs : List (List Nat)) :
    (∀ tx : Tx, txOf s r lovelace = .ok tx → tx.signers = []) ∧
    step s (withSignatures r sigs) = step s r ∧
    txOf s (withSignatures r sigs) lovelace = txOf s r lovelace := by
  obtain ⟨edge, key, owner, refundAddress, deposit, output, approval, claimed, tip, reference, datum, submittedAt, registryId⟩ := r
  refine ⟨?_, ?_, ?_⟩
  · intro tx h
    cases hs : step s ⟨edge, key, owner, refundAddress, deposit, output, approval, claimed, tip, reference, datum, submittedAt, registryId⟩ with
    | error why => rw [txOf_of_step_error _ _ _ _ hs] at h; exact nomatch h
    | ok t =>
      rw [txOf_of_step_ok _ _ _ _ hs] at h
      injection h with h
      rw [← h]
      rfl
  -- Every field the step and the transaction read is the same field of the
  -- same request: only the signature set moved, and nothing reads it.
  · cases approval <;> rfl
  · cases approval <;> rfl

/-- No exit strands a deposit.

For every exit and every request, some payment the exit owes is at least the
request's deposit: however a request ends, its deposit is owed to somebody. -/
theorem no_exit_strands_the_deposit (exit : Exit) (request : Request)
    (supported : ∀ edge, exit = .fold edge → allowed edge = true) :
    ∃ payment ∈ obligations exit request, request.deposit ≤ payment.atLeast := by
  cases exit with
  | fold edge =>
    have admitted := supported edge rfl
    cases edge <;> simp [allowed, obligations] at admitted ⊢
  | reject => simp [obligations]
  | retract => simp [obligations]

/-- Every transaction an exit builds pays what the exit owes.

For every registry state, every exit, every request and every lovelace: a
transaction the model builds for the exit settles the exit's obligations — the
deposit reaches the cage for an absent insertion, the named destination for a
fold delivering a token, and the owner for a fold delivering nothing, a reject
and a retract, which also returns the tip. -/
theorem built_transaction_settles (state : RegistryState) (exit : Exit) (request : Request)
    (lovelace : Nat) (tx : Tx) (built : txOfExit state exit request lovelace = .ok tx) :
    settle (obligations exit request) tx.outputs = none := by
  cases hstep : exitStep state exit request with
  | error why => simp [txOfExit, hstep] at built
  | ok t =>
    cases exit with
    | reject =>
      simp only [txOfExit, hstep, Except.ok.injEq] at built
      subst built
      apply settle_one
      simp +decide [obligations, ownerOutputs, paysRecipient]
    | retract =>
      simp only [txOfExit, hstep, Except.ok.injEq] at built
      subst built
      apply settle_one
      simp +decide [obligations, ownerOutputs, paysRecipient]
    | fold e =>
      simp only [exitStep] at hstep
      by_cases he : request.edge = e
      · subst he
        cases hs : step state request with
        | error why => simp [hs] at hstep
        | ok s' =>
          obtain ⟨href, happ⟩ := step_eq_ok _ _ _ hs
          simp only [txOfExit, exitStep, beq_self_eq_true, if_true, hs, Except.ok.injEq] at built
          subst built
          have admitted : allowed request.edge = true := by
            by_cases ha : allowed request.edge = true
            · exact ha
            · simp [refusal, ha] at href
          cases hedge : request.edge <;>
            simp [allowed, hedge] at admitted
          all_goals
            simp only [hedge, obligations]
            apply settle_one
            cases hd : request.datum <;> simp +decide [paysRecipient,
              txDestinationOutputs, owedTo, ownerOutputs,
              routedPayment, mintRoutedTo, happ, applyEdge, assetDelta, hedge, delta, route,
              requestDestination, presentsDatum, deliveredDatum, datumFormOf, hd]
      · simp [he] at hstep

/-- What an executed retract pays is exactly what it owes.

For every registry state and every request: the retract exit executes, leaves the
state as it was, mints nothing, and pays exactly its obligations — the deposit and
the tip, to the owner — each recorded at the address `settle` reads for its
recipient. Nothing the state holds enters what a retract pays. -/
theorem retract_pays_exactly_its_obligations (state : RegistryState) (request : Request) :
    exitStep state .retract request =
      .ok { state := state, mint := [], paid := (obligations .retract request).map paymentPaid } := by
  simp [exitStep, emptyResult]


end Singular.Statements
