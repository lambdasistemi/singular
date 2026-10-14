import Singular.Lemmas.Assets
import Singular.Driver
import Singular.Economics

/-! Transaction references, value conservation and serialization. -/

namespace Singular.Statements

/-- A referenced output survives the raw update when the transaction's spent
and reference inputs are disjoint. Without that premise spending wins; this is
a state update, not a transaction admission rule. -/
theorem reference_inputs_not_consumed (u : Utxo) (identity : Nat) (tx : Tx)
    (ref : OutRef) (output : TxOutput) (input : TxInput)
    (hu : (ref, output) ∈ u) (hi : input ∈ tx.referenceInputs)
    (href : input.ref = some ref) (hd : disjointInputs tx = true) :
    (ref, output) ∈ applyTx u identity tx := by
  have hn := List.all_eq_true.mp hd input hi
  simp only [href] at hn
  apply List.mem_append_left
  exact List.mem_filter.mpr ⟨hu, hn⟩

/-- A spent reference cannot be read by a later transaction: with a fresh
creating identity, the raw update has removed it. The later transaction's
spending inputs are present so the refusal specifically names the reference. -/
theorem spent_reference_refused (u : Utxo) (identity : Nat) (tx later : Tx)
    (ref : OutRef) (input : TxInput)
    (hspent : inputNames tx.inputs ref = true) (hfresh : ref.tx ≠ identity)
    (hi : input ∈ later.referenceInputs) (href : input.ref = some ref)
    (hp : later.inputs.all (inputPresent (applyTx u identity tx)) = true) :
    inputsPresent (applyTx u identity tx) later = some "reference-input-missing" := by
  have habsent : ∀ output, (ref, output) ∉ applyTx u identity tx := by
    intro output hmem
    rcases List.mem_append.mp hmem with hmem | hmem
    · have hkeep := (List.mem_filter.mp hmem).2
      simp [hspent] at hkeep
    · obtain ⟨⟨other, index⟩, _, heq⟩ := List.mem_map.mp hmem
      have hid := congrArg (fun p : OutRef × TxOutput => p.1.tx) heq
      exact hfresh hid.symm
  have hmissing : inputPresent (applyTx u identity tx) input = false := by
    simp only [inputPresent, href]
    apply Bool.eq_false_iff.mpr
    intro hany
    obtain ⟨⟨found, output⟩, hmem, heq⟩ := List.any_eq_true.mp hany
    have heq' : found = ref := of_decide_eq_true heq
    subst found
    exact habsent output hmem
  have hnotall : later.referenceInputs.all (inputPresent (applyTx u identity tx)) = false := by
    apply Bool.eq_false_iff.mpr
    intro hall
    have := List.all_eq_true.mp hall input hi
    simp [hmissing] at this
  simp [inputsPresent, hp, hnotall]

/-- The disjointness premise is necessary: this concrete overlapping input
is spent by the raw update, whatever value its output carries. -/
theorem overlapping_reference_is_spent (output : TxOutput) :
    let input : TxInput :=
      { role := .request, datum := .none, stateTokens := 0
      , approvals := 0, lovelace := 0, ref := some ⟨1, 0⟩ }
    let tx : Tx :=
      { inputs := [input], referenceInputs := [input], outputs := []
      , mint := [], signers := [], refunds := [] }
    disjointInputs tx = false ∧ applyTx [(⟨1, 0⟩, output)] 2 tx = [] := by
  simp [disjointInputs, inputNames, applyTx]

/-- The balance judgement conserves lovelace including explicit fee and
donation, all native assets after mint, and every state-token identity present
on either side. Only the unspent set supplies spending values. -/
theorem balanced_transaction_creates_no_value (u : Utxo) (tx : Tx)
    (h : balanced u tx = true) :
    outputLovelace (spentOutputs u tx) = outputLovelace tx.outputs + tx.donation + tx.fee ∧
    (∀ asset, assetKind (outputAssets (spentOutputs u tx) ++ tx.mint) asset =
      assetKind (outputAssets tx.outputs) asset) ∧
    (∀ token ∈ stateTokenSupport (spentOutputs u tx) tx.outputs,
      stateTokenValue (spentOutputs u tx) token = stateTokenValue tx.outputs token) := by
  simp only [balanced, Bool.and_eq_true, beq_iff_eq] at h
  exact ⟨h.1.1, (assetSame_iff _ _).mp h.1.2,
    fun token ht => by simpa using List.all_eq_true.mp h.2 token ht⟩

/-- Zero donation contributes no field to the list actually serialized by
the transaction encoder. Positive donations remain explicit. -/
theorem zero_donation_omits_field (c : Config) (tx : Tx) (h : tx.donation = 0) :
    ∀ value, ("donation", value) ∉ Driver.txFields c tx := by
  intro value
  simp [Driver.txFields, h]

end Singular.Statements
