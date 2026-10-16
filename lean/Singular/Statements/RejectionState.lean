import Singular.Lemmas.RejectionState

/-! Reference-read rejection preserves the registry and its token supplies.
The premises concern observed transactions and reachable worlds, never builders. -/

namespace Singular.Statements

/-- Every accepted rejection keeps the complete registry and termination pool,
including the world singular supply. Its observed mint is empty for state and
singular assets, and neither its consumed nor produced outputs carry them.
Request tags are deliberately burned and are not part of this unchanged supply. -/
theorem rejection_leaves_registry_untouched (world after : World)
    (reachable : WorldReachable world) (u : EconomicUtxo) (r : Rejection)
    (accepted : rejectionAccepted world u r = .ok after) :
    after.registry = world.registry ∧ after.terminations = world.terminations ∧
    (∀ key, worldSingularSupply after key = worldSingularSupply world key) ∧
    r.transaction.stateMint = [] ∧ r.transaction.singularMint = [] ∧
    r.transaction.transaction.mint = [] ∧
    (∀ output ∈ economicSpent u r.transaction,
      output.output.stateTokens = 0 ∧ output.output.assets = [] ∧ output.singularTags = [] ∧
      output.contents.otherAssets = []) ∧
    (∀ output ∈ r.transaction.outputs,
      output.output.stateTokens = 0 ∧ output.output.assets = [] ∧ output.singularTags = [] ∧
      output.contents.otherAssets = []) := by
  have effect := rejectionAccepted_effect accepted
  have checks := rejectionAccepted_checks accepted
  obtain ⟨interval, validity, nonempty, members, inputs, grounds, burns, supply⟩ := checks.2.2.2
  simp only [rejectionSupplyUnchanged, Bool.and_eq_true, List.isEmpty_iff] at supply
  subst after
  refine ⟨rfl, rfl, fun _ => rfl, supply.1.1.1.2, supply.1.1.2, supply.1.1.1.1, ?_, ?_⟩
  · intro output present
    have h := List.all_eq_true.mp supply.1.2 output present
    simp only [Bool.and_eq_true, List.isEmpty_iff, beq_iff_eq] at h
    exact ⟨h.1.1.1, h.1.1.2, h.1.2, h.2⟩
  · intro output present
    have h := List.all_eq_true.mp supply.2 output present
    simp only [Bool.and_eq_true, List.isEmpty_iff, beq_iff_eq] at h
    exact ⟨h.1.1.1, h.1.1.2, h.1.2, h.2⟩

/-- The accepted transaction names an actually present reference carrying this
registry's exact state token and inline current root. That same observed output
survives the ledger update; its reference is absent from the spending inputs. -/
theorem rejection_requires_referenced_state (world after : World)
    (reachable : WorldReachable world) (u : EconomicUtxo) (r : Rejection)
    (accepted : rejectionAccepted world u r = .ok after) :
    inputsContainReference r.transaction.transaction.referenceInputs r.stateReference = true ∧
    inputsContainReference r.transaction.transaction.inputs r.stateReference = false ∧
    ∃ output, (r.stateReference, output) ∈ u ∧
      output.output.stateTokens = 1 ∧ output.output.role = .state ∧
      output.output.stateToken = some world.registry.config.stateToken ∧
      output.output.datum = .inline ∧ output.output.config = some world.registry.config ∧
      world.registry.config.root = rootOf world.registry.trie ∧
      (r.stateReference, output) ∈ applyEconomicTransaction u r.transaction := by
  have checks := rejectionAccepted_checks accepted
  obtain ⟨referenced, output, lookup, tokenCount, role, token, datum, config, root⟩ :=
    rejectionState_facts checks.2.1
  have unspent := rejection_state_not_spent accepted
  have present := economicLookup_mem lookup
  refine ⟨referenced, unspent, output, present, tokenCount, role, token, datum, config, root, ?_⟩
  apply List.mem_append_left
  exact List.mem_filter.mpr ⟨present, by simp [unspent]⟩

/-- A previously admitted fold has exactly the same registry judgement after
rejection. Every one of its needed unspent outputs survives when its other
inputs are disjoint; the state reference survives without a disjointness premise.
This retains the existing fold judgement, not a future economic fold admission. -/
theorem rejection_cannot_invalidate_fold (world after : World)
    (reachable : WorldReachable world) (u : EconomicUtxo) (r : Rejection)
    (accepted : rejectionAccepted world u r = .ok after)
    (requests : List Request) (witness : FoldWitness) (result : Result)
    (foldValid : admittedFoldBatch world.registry requests witness = .ok result)
    (needed : List (OutRef × EconomicOutput))
    (present : ∀ entry ∈ needed, entry ∈ u)
    (otherInputsDisjoint : ∀ entry ∈ needed, entry.1 ≠ r.stateReference →
      inputsContainReference r.transaction.transaction.inputs entry.1 = false) :
    admittedFoldBatch after.registry requests witness = .ok result ∧
    ∀ entry ∈ needed, entry ∈ applyEconomicTransaction u r.transaction := by
  have effect := rejectionAccepted_effect accepted
  constructor
  · simpa [effect, rejectionEffect] using foldValid
  · intro entry member
    apply List.mem_append_left
    refine List.mem_filter.mpr ⟨present entry member, ?_⟩
    by_cases state : entry.1 = r.stateReference
    · simp [state, rejection_state_not_spent accepted]
    · simp [otherInputsDisjoint entry member state]

/-- The exact spending-reference multiset equals the members, and both lists
are duplicate-free. Thus each admitted member is consumed once by this one
transaction; no unrelated spending input is silently included. -/
theorem rejection_batch_members_distinct (world after : World)
    (reachable : WorldReachable world) (u : EconomicUtxo) (r : Rejection)
    (accepted : rejectionAccepted world u r = .ok after) :
    (r.members.map Prod.fst).Nodup ∧
    (r.transaction.transaction.inputs.map (·.ref)).Nodup ∧
    (r.transaction.transaction.inputs.map (·.ref)).Perm (r.members.map fun m => some m.1) := by
  have checks := rejectionAccepted_checks accepted
  have inputs := rejectionInputs_facts checks.1
  obtain ⟨interval, validity, nonempty, members, same, rest⟩ := checks.2.2.2
  exact ⟨inputs.2.2.1, inputs.2.1, same⟩

/-- A sweep admitted from an authoritative unspent observation leaves both
pending pools and the entire registry unchanged. It provides no exit for a
tagged request and makes no ledger-balance or other-script acceptance claim. -/
theorem sweep_leaves_pool_untouched (world after : World)
    (reachable : WorldReachable world) (u : EconomicUtxo) (tx : EconomicTransaction)
    (accepted : sweepAccepted world u tx = .ok after) : after = world := by
  unfold sweepAccepted at accepted
  simp only [bind, Except.bind] at accepted
  repeat (split at accepted <;> try contradiction)
  all_goals cases accepted; rfl

end Singular.Statements
