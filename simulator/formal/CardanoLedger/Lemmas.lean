import CardanoLedger.Premises

/-! Facts about the transaction projections and explicit ledger premises. -/

namespace CardanoLedger

theorem bytes_beq (a b : Bytes) : List.beq a b = true ↔ a = b := beq_iff_eq (a := a) (b := b)

instance : LawfulBEq Credential where
  eq_of_beq {a b} h := by cases a <;> cases b <;> simp_all [BEq.beq, instBEqCredential.beq, bytes_beq]
  rfl {a} := by cases a <;> simp [BEq.beq, instBEqCredential.beq, bytes_beq]

instance : LawfulBEq OutputRef where
  eq_of_beq {a b} h := by cases a; cases b; simp_all [BEq.beq, instBEqOutputRef.beq, bytes_beq]
  rfl {a} := by cases a; simp [BEq.beq, instBEqOutputRef.beq, bytes_beq]

theorem reference_beq (a b : OutputRef) : instBEqOutputRef.beq a b = true ↔ a = b := beq_iff_eq (a := a) (b := b)
theorem credential_beq (a b : Credential) : instBEqCredential.beq a b = true ↔ a = b := beq_iff_eq (a := a) (b := b)

instance : LawfulBEq Purpose where
  eq_of_beq {a b} h := by cases a <;> cases b <;> simp_all [BEq.beq, instBEqPurpose.beq, bytes_beq, reference_beq, credential_beq]
  rfl {a} := by cases a <;> simp [BEq.beq, instBEqPurpose.beq, bytes_beq, reference_beq, credential_beq]

theorem member_eraseDups {α : Type} [BEq α] [LawfulBEq α] (x : α)
    (xs : List α) : x ∈ xs.eraseDups ↔ x ∈ xs := by
  cases xs with
  | nil => simp
  | cons a rest =>
    rw [List.eraseDups_cons, List.mem_cons, member_eraseDups x (rest.filter fun b => !b == a)]
    simp only [List.mem_filter, Bool.not_eq_true, beq_eq_false_iff_ne, List.mem_cons]
    grind
termination_by xs.length
decreasing_by
  simp only [List.length_cons]
  exact Nat.lt_succ_of_le (List.length_filter_le _ _)

theorem Tx.mint_invoked (tx : Tx D R S) (policy : PolicyId)
    (moves : tx.mint.moves policy = true) :
    (Purpose.mint policy, policy) ∈ tx.invocations := by
  have member : policy ∈ tx.mint.map (fun entry => entry.1.policy) := by
    obtain ⟨entry, member, condition⟩ := List.any_eq_true.mp moves
    simp only [Bool.and_eq_true] at condition
    have same := condition.1
    exact List.mem_map.mpr ⟨entry, member, by simpa using same⟩
  simp only [Tx.invocations, List.mem_append]
  exact Or.inl (Or.inl (Or.inr (List.mem_map.mpr
    ⟨policy, List.mem_filter.mpr ⟨(member_eraseDups _ _).mpr member, moves⟩, rfl⟩)))

theorem Tx.spend_invoked (tx : Tx D R S) (input : Input D) (hash : ScriptHash)
    (member : input ∈ tx.inputs) (credential : input.resolved.address.payment = .script hash) :
    (Purpose.spend input.reference, hash) ∈ tx.invocations := by
  simp only [Tx.invocations, List.mem_append]
  exact Or.inl (Or.inl (Or.inl (List.mem_filterMap.mpr
    ⟨input, member, by simp [credential, Credential.scriptHash]⟩)))

theorem Tx.redeemerOf_withoutStaking (tx : Tx D R S) (purpose : Purpose)
    (notStaking : purpose.isStaking = false) :
    tx.withoutStaking.redeemerOf purpose = tx.redeemerOf purpose := by
  simp only [Tx.redeemerOf, Tx.withoutStaking, List.find?_filter]
  congr 2
  funext entry
  by_cases same : entry.1 = purpose <;> simp [beq_iff_eq, same, notStaking]

theorem Assets.quantity_eq_zero_of_no_entries (assets : Assets) (asset : AssetClass)
    (zero : ∀ entry ∈ assets, entry.1 = asset → entry.2 = 0) :
    assets.quantity asset = 0 := by
  induction assets with
  | nil => rfl
  | cons entry rest ih =>
    have head : (if entry.1 = asset then entry.2 else 0) = 0 := by
      split
      · exact zero entry (by simp) ‹_›
      · rfl
    simp only [Assets.quantity, List.map_cons, List.sum_cons]
    rw [head, show (rest.map fun entry => if entry.1 = asset then entry.2 else 0).sum = 0 from
      ih (fun entry member => zero entry (by simp [member]))]
    rfl

theorem Assets.moves_of_quantity_ne_zero (assets : Assets) (asset : AssetClass)
    (nonzero : assets.quantity asset ≠ 0) : assets.moves asset.policy = true := by
  cases absent : assets.moves asset.policy with
  | true => rfl
  | false =>
    exfalso
    apply nonzero
    apply Assets.quantity_eq_zero_of_no_entries
    intro entry member same
    have noMovement := List.any_eq_false.mp absent entry member
    simpa [same] using noMovement

theorem Ledger.oversized_quantity_zero (ledger : Ledger D R S)
    (names : ledger.KeepsNamesWithinLimit) (tx : Tx D R S)
    (accepted : ledger.accepts tx) (asset : AssetClass) (large : 32 < asset.name.length) :
    tx.mint.quantity asset = 0 := by
  apply Assets.quantity_eq_zero_of_no_entries
  intro entry member same
  by_cases nonzero : entry.2 = 0
  · exact nonzero
  · have valid := (names tx accepted).1 entry member nonzero
    rw [same] at valid
    exact False.elim ((Nat.not_le_of_gt large) valid)

end CardanoLedger
