import Singular.Lemmas.LedgerBoundary.Mint
import Singular.Lemmas.LedgerBoundary.Names
import Singular.Lemmas.LedgerBoundary.Policies
import Singular.Lemmas.LedgerBoundary.Discard

/-! A finite observed ledger exercising the premises together. It does not
model a real chain's validation rules beyond the premises stated here. -/

namespace Singular.LedgerBoundary.Example
open CardanoLedger

def registry : AssetClass := ⟨[9], [9]⟩

/-- Deliberately not globally injective: witnesses of other registries collide.
Only the scripts occurring in these two transactions need collision freedom. -/
def hash : RegistryScript → ScriptHash
  | .state => [0]
  | .witness .active _ => [1]
  | .witness .absent _ => [2]
  | .witness .terminal _ => [3]
  | .other _ => [4]

def config : Config :=
  { root := rootOf [], minimumTip := 0, processTime := 10, retractTime := 10
    applicationPolicy := 7, activePolicy := 1, absentPolicy := 2, terminalPolicy := 3 }

def initial : RegistryState :=
  { config := { config with root := rootOf [] }, trie := [], custody := [], held := [] }

def approval : Singular.Approval :=
  { policy := config.applicationPolicy, edge := .insertActive, key := 0, owner := 42,
    destination := 99, assetName := approvalAssetName .insertActive 0 42 99 }

def request : Request :=
  { edge := .insertActive, key := 0, owner := 42, output := 99
    approval := some approval
    claimed := [(.active, 1)] }

def result : Result := applyEdge initial request

def stateInput : CardanoLedger.Input RegistryDatum :=
  { reference := ⟨[10], 0⟩
    resolved := { address := ⟨.script (hash .state), none⟩
                  value := ⟨10, [(registry, 1)]⟩, datum := some (.state initial) } }

def mintTx : RegistryTx :=
  { inputs := [stateInput], referenceInputs := []
    outputs := [
      { stateInput.resolved with datum := some (.state result.state) },
      { address := ⟨.key [42], none⟩, value := ⟨0, [(⟨[1], []⟩, 1)]⟩, datum := none }]
    mint := [(⟨[1], []⟩, 1)], withdrawals := [], certificates := []
    redeemers := [(.spend stateInput.reference, .fold), (.mint [1], .other 0)]
    scripts := [.state, .witness .active registry], signatories := []
    validFrom := some 0, validTo := some 1 }

def terminalState : RegistryState :=
  { config := { config with root := rootOf [(0, .known .terminal)] }
    trie := [(0, .known .terminal)], custody := []
    held := [{ key := 0, kind := .terminal, output := 99 }] }

def burnInput : CardanoLedger.Input RegistryDatum :=
  { reference := ⟨[11], 99⟩
    resolved := { address := ⟨.key [42], none⟩
                  value := ⟨10, [(⟨[3], []⟩, 1)]⟩, datum := none } }

def burnTx : RegistryTx :=
  { inputs := [burnInput], referenceInputs := []
    outputs := [{ address := ⟨.key [42], none⟩, value := ⟨10, []⟩, datum := none }]
    mint := [(⟨[3], []⟩, -1)], withdrawals := [], certificates := []
    redeemers := [(.mint [3], .other 0)]
    scripts := [.witness .terminal registry], signatories := [[42]]
    validFrom := some 0, validTo := some 1 }

def world : RegistryWorld :=
  { hash, stateRule := fun ctx => decide
      (ctx.tx = mintTx ∧ ctx.purpose = .spend stateInput.reference ∧ ctx.redeemer = .fold)
    otherRule := fun _ _ => false
    accepts := fun tx => tx = mintTx ∨ tx = burnTx }

def pins : Pins := ⟨[2], [1], [3]⟩

theorem bound : Bound world pins registry := by
  intro kind; cases kind <;> rfl

theorem reachable : Reachable initial := Reachable.initial config

theorem admitted : admittedFoldBatch initial [request] ⟨1⟩ = .ok result := by rfl

theorem one_active : kindCount result.state .active 0 = 1 := by decide

theorem names : world.ledger.KeepsNamesWithinLimit := by
  intro tx accepted
  rcases accepted with rfl | rfl <;>
    simp [mintTx, burnTx, stateInput, registry, AssetName.valid]

theorem collisions (tx : RegistryTx)
    (scripts : ∀ script ∈ tx.scripts, script = .state ∨ ∃ kind, script = .witness kind registry) :
    CollisionFreeOn world.hash (ScriptsOccur world registry tx) := by
  have allowed : ∀ script, ScriptsOccur world registry tx script →
      script = .state ∨ ∃ kind, script = .witness kind registry := by
    intro script occurs
    rcases occurs with supplied | state | witness
    · exact scripts script supplied
    · exact Or.inl state
    · exact Or.inr witness
  intro a ha b hb equal
  rcases allowed a ha with rfl | ⟨ka, rfl⟩ <;>
    rcases allowed b hb with rfl | ⟨kb, rfl⟩
  · rfl
  · cases kb <;> simp [world, hash] at equal
  · cases ka <;> simp [world, hash] at equal
  · cases ka <;> cases kb <;> simp_all [world, hash]

theorem mint_collision : CollisionFreeOn world.hash (ScriptsOccur world registry mintTx) := by
  apply collisions
  intro script member
  simp only [mintTx, List.mem_cons, List.not_mem_nil, or_false] at member
  rcases member with rfl | rfl
  · exact Or.inl rfl
  · exact Or.inr ⟨.active, rfl⟩

theorem burn_collision : CollisionFreeOn world.hash (ScriptsOccur world registry burnTx) := by
  apply collisions
  intro script member
  simp only [burnTx, List.mem_cons, List.not_mem_nil, or_false] at member
  subst script
  exact Or.inr ⟨.terminal, rfl⟩

theorem runs : world.ledger.RunsScripts := by
  intro tx accepted purpose scriptHash invoked
  rcases accepted with rfl | rfl
  · have extent : mintTx.invocations = [(.spend stateInput.reference, [0]), (.mint [1], [1])] := by decide
    rw [extent] at invoked
    simp only [List.mem_cons, List.not_mem_nil, or_false, Prod.mk.injEq] at invoked
    rcases invoked with ⟨rfl, rfl⟩ | ⟨rfl, rfl⟩
    · exact ⟨.fold, .state, by decide, by simp [mintTx], rfl,
        by simp [RegistryWorld.ledger, world]⟩
    · exact ⟨.other 0, .witness .active registry, by decide, by simp [mintTx], rfl, by decide⟩
  · have extent : burnTx.invocations = [(.mint [3], [3])] := by decide
    rw [extent] at invoked
    simp only [List.mem_cons, List.not_mem_nil, or_false, Prod.mk.injEq] at invoked
    obtain ⟨rfl, rfl⟩ := invoked
    exact ⟨.other 0, .witness .terminal registry, by decide, by simp [burnTx], rfl, by decide⟩

theorem folds : StateScriptFolds world registry := by
  intro tx input member credential quantity redeemer evaluated
  have facts : tx = mintTx ∧ Purpose.spend input.reference = .spend stateInput.reference ∧
      RegistryRedeemer.fold = .fold := of_decide_eq_true evaluated
  obtain ⟨rfl, _, _⟩ := facts
  have same : input = stateInput := by simpa [mintTx] using member
  subst input
  refine ⟨initial, [request], ⟨1⟩, result, rfl, admitted, rfl, ?_⟩
  intro kind key
  have keyZero : keyName key = [] ↔ key = 0 := by
    constructor
    · intro empty
      have inverse := keyOfName_keyName key
      rw [empty] at inverse
      exact inverse.symm
    · intro zero; subst key; simp [keyName]
  have reversed : (0 = key) = (key = 0) := propext eq_comm
  cases kind <;>
    simp [CardanoLedger.Assets.quantity, tokenOf, RegistryWorld.policyId, world, hash,
      mintTx, result, applyEdge, request, assetDelta, delta, assetKind,
      AssetClass.mk.injEq, keyZero, reversed]

theorem terminal_consistent : Consistent terminalState := by
  simp [Consistent, terminalState, kindCount, custodyCount, trieGet]
  constructor <;> intro key <;> split <;> simp_all

end Singular.LedgerBoundary.Example
