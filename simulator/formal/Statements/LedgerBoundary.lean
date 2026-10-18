import Singular.Lemmas.LedgerBoundary

/-! Registry policy guarantees under explicitly named ledger premises. -/

namespace Singular.Statements
open CardanoLedger LedgerBoundary

/-- The two state-bound kinds require a fold; terminal pure burns are the
holder's operation. The clauses are the complete policy decision. -/
theorem witness_decision_cases (world : RegistryWorld) (registry : AssetClass)
    (ctx : RegistryContext) :
    ((witnessDecision world .active registry ctx = true ↔
      foldPresent world registry ctx.tx = true) ∧
    (witnessDecision world .absent registry ctx = true ↔
      foldPresent world registry ctx.tx = true) ∧
    (witnessDecision world .terminal registry ctx = true ↔
      ctx.tx.mint.onlyBurns (world.policyId .terminal registry) = true ∨
      foldPresent world registry ctx.tx = true)) := by
  simp [witnessDecision, Bool.or_eq_true]

/-- A bound active or absent policy cannot move without an accepted state
spend with the exact state-token quantity and fold redeemer. -/
theorem fold_required_for_active_and_absent (world : RegistryWorld)
    (pins : Pins) (registry : AssetClass) (tx : RegistryTx) (kind : TokenKind)
    (runs : world.ledger.RunsScripts)
    (collision : CollisionFreeOn world.hash (ScriptsOccur world registry tx))
    (bound : Bound world pins registry) (accepted : world.ledger.accepts tx)
    (stateBound : kind = .active ∨ kind = .absent)
    (moves : tx.mint.moves (pins.policy kind) = true) :
    ∃ input ∈ tx.inputs,
      input.resolved.address.payment = .script (world.hash .state) ∧
      input.resolved.value.assets.quantity registry = 1 ∧
      tx.redeemerOf (.spend input.reference) = some .fold ∧
      world.stateRule ⟨.spend input.reference, .fold, tx⟩ = true := by
  have movement : tx.mint.moves (world.policyId kind registry) = true := by
    rw [← bound kind]; exact moves
  obtain ⟨redeemer, _, evaluated⟩ := accepted_script world registry tx runs collision accepted
    (.witness kind registry) (Or.inr (Or.inr ⟨kind, rfl⟩))
    (.mint (world.policyId kind registry)) (tx.mint_invoked _ movement)
  have present : foldPresent world registry tx = true := by
    rcases stateBound with rfl | rfl <;> exact evaluated
  exact accepted_state_spend world registry tx runs collision accepted present

/-- Naming is reversible on all byte strings. Reachability supplies the active
count; the ledger's separate size premise rules out oversized minted names. -/
theorem key_names_its_token (world : RegistryWorld) (pins : Pins)
    (registry : AssetClass) (key : Key) (state : RegistryState) (tx : RegistryTx)
    (bound : Bound world pins registry) (reachable : Reachable state)
    (names : world.ledger.KeepsNamesWithinLimit) (accepted : world.ledger.accepts tx) :
    tokenOf world .active registry key = ⟨pins.active, keyName key⟩ ∧
    keyOfName (keyName key) = key ∧
    (∀ name, keyName (keyOfName name) = name) ∧
    kindCount state .active key =
      (if trieGet state.trie key = .known .active then 1 else 0) ∧
    (32 < (keyName key).length →
      tx.mint.quantity (tokenOf world .active registry key) = 0) := by
  have consistent := reachable_consistent state reachable
  refine ⟨?_, keyOfName_keyName key, keyName_keyOfName, ?_, ?_⟩
  · unfold tokenOf
    rw [← bound .active]
    rfl
  · split
    · rename_i active
      exact (consistent.2.1 key).mpr active
    · rename_i inactive
      have upper := consistent.2.2.1 key
      have notOne : kindCount state .active key ≠ 1 :=
        fun one => inactive ((consistent.2.1 key).mp one)
      omega
  · intro large
    exact world.ledger.oversized_quantity_zero names tx accepted _ large

/-- A positive active mint is tied to a single spent state and the admitted
model batch; it starts unknown and, from a reachable state, ends with one token. -/
theorem active_mint_at_unknown_key (world : RegistryWorld) (pins : Pins)
    (registry : AssetClass) (tx : RegistryTx) (key : Key)
    (runs : world.ledger.RunsScripts)
    (collision : CollisionFreeOn world.hash (ScriptsOccur world registry tx))
    (bound : Bound world pins registry) (accepted : world.ledger.accepts tx)
    (folds : StateScriptFolds world registry)
    (positive : 0 < tx.mint.quantity ⟨pins.active, keyName key⟩) :
    ∃ input ∈ tx.inputs, ∃ state batch witness result,
      input.resolved.address.payment = .script (world.hash .state) ∧
      input.resolved.value.assets.quantity registry = 1 ∧
      tx.redeemerOf (.spend input.reference) = some .fold ∧
      world.stateRule ⟨.spend input.reference, .fold, tx⟩ = true ∧
      input.resolved.datum = some (.state state) ∧
      admittedFoldBatch state batch witness = .ok result ∧
      tx.validTo = some witness.validTo ∧
      (∀ kind key, tx.mint.quantity (tokenOf world kind registry key) =
        assetKind result.mint (kind, key)) ∧
      trieGet state.trie key = .unknown ∧
      (Reachable state → kindCount result.state .active key = 1) := by
  have identity : tokenOf world .active registry key = ⟨pins.active, keyName key⟩ := by
    unfold tokenOf
    rw [← bound .active]
    rfl
  have movement := tx.mint.moves_of_quantity_ne_zero ⟨pins.active, keyName key⟩
    (Int.ne_of_gt positive)
  obtain ⟨input, member, credential, quantity, redeemer, evaluated⟩ :=
    fold_required_for_active_and_absent world pins registry tx .active runs collision bound
      accepted (Or.inl rfl) movement
  obtain ⟨state, batch, witness, result, datum, admitted, upper, mint⟩ :=
    folds tx input member credential quantity redeemer evaluated
  have positiveModel : 0 < assetKind result.mint (.active, key) := by
    rw [← mint .active key, identity]
    exact positive
  obtain ⟨unknown, _, count⟩ := admitted_positive_active state batch witness result admitted key positiveModel
  exact ⟨input, member, state, batch, witness, result, credential, quantity, redeemer,
    evaluated, datum, admitted, upper, mint, unknown, count⟩

/-- Arbitrary changes to every staking field preserve each policy's decision. -/
theorem token_policies_read_no_staking (world : RegistryWorld) (kind : TokenKind)
    (registry : AssetClass) (purpose : Purpose) (redeemer : RegistryRedeemer)
    (left right : RegistryTx) (same : left.withoutStaking = right.withoutStaking) :
    witnessDecision world kind registry ⟨purpose, redeemer, left⟩ =
      witnessDecision world kind registry ⟨purpose, redeemer, right⟩ := by
  rw [← witnessDecision_withoutStaking world kind registry purpose redeemer left,
    ← witnessDecision_withoutStaking world kind registry purpose redeemer right, same]

/-- A holder can remove one terminal holding without changing registry facts,
active supply, custody or consistency. This operation is not a fold. -/
theorem terminal_discard_changes_no_registry_state (state : RegistryState)
    (key : Key) (output : Nat) :
    (∀ k, trieGet (discardTerminal state key output).trie k = trieGet state.trie k) ∧
    (discardTerminal state key output).config.root = state.config.root ∧
    (discardTerminal state key output).config = state.config ∧
    (discardTerminal state key output).custody = state.custody ∧
    (∀ k, kindCount (discardTerminal state key output) .active k = kindCount state .active k) ∧
    (Consistent state → Consistent (discardTerminal state key output)) := by
  exact ⟨fun _ => rfl, rfl, rfl, rfl, discard_active_count state key output,
    discard_consistent state key output⟩

/-- The same ledger meets all the premises and accepts both an active mint and
a fold-free terminal burn. The discarded terminal holding is present and sound. -/
theorem ledger_boundary_premises_satisfiable :
    ∃ world : RegistryWorld, ∃ pins registry mintTx burnTx key terminalState output,
      world.ledger.RunsScripts ∧ world.ledger.KeepsNamesWithinLimit ∧
      StateScriptFolds world registry ∧ Bound world pins registry ∧
      CollisionFreeOn world.hash (ScriptsOccur world registry mintTx) ∧
      CollisionFreeOn world.hash (ScriptsOccur world registry burnTx) ∧
      world.ledger.accepts mintTx ∧ world.ledger.accepts burnTx ∧
      mintTx.mint = [(tokenOf world .active registry key, 1)] ∧
      burnTx.mint = [(tokenOf world .terminal registry key, -1)] ∧
      foldPresent world registry burnTx = false ∧
      Consistent terminalState ∧
      (∃ holding ∈ terminalState.held,
        holding.key = key ∧ holding.kind = .terminal ∧ holding.output = output) ∧
      (discardTerminal terminalState key output).held.length + 1 = terminalState.held.length ∧
      (∃ input ∈ burnTx.inputs,
        input.reference.index = output ∧
        input.resolved.value.assets.quantity (tokenOf world .terminal registry key) = 1) ∧
      (∃ input ∈ mintTx.inputs, ∃ state batch witness result,
        input.resolved.address.payment = .script (world.hash .state) ∧
        input.resolved.value.assets.quantity registry = 1 ∧
        mintTx.redeemerOf (.spend input.reference) = some .fold ∧
        world.stateRule ⟨.spend input.reference, .fold, mintTx⟩ = true ∧
        input.resolved.datum = some (.state state) ∧ Reachable state ∧
        admittedFoldBatch state batch witness = .ok result ∧
        kindCount result.state .active key = 1) := by
  refine ⟨Example.world, Example.pins, Example.registry, Example.mintTx, Example.burnTx,
    0, Example.terminalState, 99, Example.runs, Example.names, Example.folds, Example.bound,
    Example.mint_collision, Example.burn_collision, Or.inl rfl, Or.inr rfl, ?_, ?_, ?_,
    Example.terminal_consistent, ?_, ?_, ?_, ?_⟩
  · simp [Example.mintTx, tokenOf, RegistryWorld.policyId, Example.world, Example.hash, keyName]
  · simp [Example.burnTx, tokenOf, RegistryWorld.policyId, Example.world, Example.hash, keyName]
  · decide
  · exact ⟨⟨0, .terminal, 99, none⟩, by simp [Example.terminalState], rfl, rfl, rfl⟩
  · decide
  · refine ⟨Example.burnInput, by simp [Example.burnTx], rfl, ?_⟩
    simp [Example.burnInput, tokenOf, RegistryWorld.policyId, Example.world,
      Example.hash, keyName, CardanoLedger.Assets.quantity]
  · refine ⟨Example.stateInput, by simp [Example.mintTx], Example.initial,
      [Example.request], ⟨1⟩, Example.result, rfl, ?_, ?_, ?_, rfl,
      Example.reachable, Example.admitted, Example.one_active⟩
    · decide
    · decide
    · simp [Example.world]

end Singular.Statements
