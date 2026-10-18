import Singular.Model.LedgerBoundary

/-! Script execution under the occurrence-scoped hash premise, and policy views. -/

namespace Singular.LedgerBoundary
open CardanoLedger

instance : LawfulBEq RegistryRedeemer where
  eq_of_beq {a b} h := by
    cases a <;> cases b <;> simp_all [BEq.beq, instBEqRegistryRedeemer.beq]
  rfl {a} := by cases a <;> simp [BEq.beq, instBEqRegistryRedeemer.beq]

theorem accepted_script (world : RegistryWorld) (registry : AssetClass) (tx : RegistryTx)
    (runs : world.ledger.RunsScripts)
    (collision : CollisionFreeOn world.hash (ScriptsOccur world registry tx))
    (accepted : world.ledger.accepts tx) (script : RegistryScript)
    (occurs : ScriptsOccur world registry tx script) (purpose : Purpose)
    (invoked : (purpose, world.hash script) ∈ tx.invocations) :
    ∃ redeemer, tx.redeemerOf purpose = some redeemer ∧
      world.ledger.evaluate script ⟨purpose, redeemer, tx⟩ = true := by
  obtain ⟨redeemer, supplied, found, member, hash, evaluated⟩ := runs tx accepted purpose _ invoked
  have same : supplied = script := collision supplied (Or.inl member) script occurs hash
  subst supplied
  exact ⟨redeemer, found, evaluated⟩

theorem accepted_state_spend (world : RegistryWorld) (registry : AssetClass) (tx : RegistryTx)
    (runs : world.ledger.RunsScripts)
    (collision : CollisionFreeOn world.hash (ScriptsOccur world registry tx))
    (accepted : world.ledger.accepts tx) (present : foldPresent world registry tx = true) :
    ∃ input ∈ tx.inputs,
      input.resolved.address.payment = .script (world.hash .state) ∧
      input.resolved.value.assets.quantity registry = 1 ∧
      tx.redeemerOf (.spend input.reference) = some .fold ∧
      world.stateRule ⟨.spend input.reference, .fold, tx⟩ = true := by
  obtain ⟨input, member, condition⟩ := List.any_eq_true.mp present
  simp only [Bool.and_eq_true, beq_iff_eq] at condition
  obtain ⟨⟨credential, quantity⟩, redeemer⟩ := condition
  obtain ⟨r, found, evaluated⟩ := accepted_script world registry tx runs collision accepted
    .state (Or.inr (Or.inl rfl)) (.spend input.reference)
    (tx.spend_invoked input _ member credential)
  rw [redeemer] at found
  cases found
  exact ⟨input, member, credential, quantity, redeemer, evaluated⟩

theorem foldPresent_withoutStaking (world : RegistryWorld) (registry : AssetClass) (tx : RegistryTx) :
    foldPresent world registry tx.withoutStaking = foldPresent world registry tx := by
  simp only [foldPresent, Tx.withoutStaking, List.any_map]
  apply congrArg (fun predicate => tx.inputs.any predicate)
  funext input
  simp only [Function.comp_def, Input.withoutStaking, Output.withoutStaking]
  have same := tx.redeemerOf_withoutStaking (.spend input.reference) rfl
  simpa only [Tx.withoutStaking] using congrArg
    (fun r => input.resolved.address.payment == .script (world.hash .state) &&
      input.resolved.value.assets.quantity registry == 1 && r == some .fold) same

theorem witnessDecision_withoutStaking (world : RegistryWorld) (kind : TokenKind)
    (registry : AssetClass) (purpose : Purpose) (redeemer : RegistryRedeemer) (tx : RegistryTx) :
    witnessDecision world kind registry ⟨purpose, redeemer, tx.withoutStaking⟩ =
      witnessDecision world kind registry ⟨purpose, redeemer, tx⟩ := by
  cases kind <;> simp only [witnessDecision, foldPresent_withoutStaking]
  rfl

end Singular.LedgerBoundary
