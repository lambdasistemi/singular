import Singular.Model

/-! Lovelace bounds and settling one payment. -/

namespace Singular

/-! ### Settling one payment -/

/-- Summing lovelace never loses the accumulator. -/
theorem le_foldl_lovelace (l : List TxOutput) (acc : Nat) :
    acc ≤ l.foldl (· + ·.lovelace) acc := by
  induction l generalizing acc with
  | nil => simp
  | cons o rest ih => exact Nat.le_trans (Nat.le_add_right _ _) (ih _)

/-- An output's lovelace is part of any sum over a list holding it. -/
theorem lovelace_le_foldl (l : List TxOutput) (acc : Nat) (o : TxOutput) (h : o ∈ l) :
    o.lovelace ≤ l.foldl (· + ·.lovelace) acc := by
  induction l generalizing acc with
  | nil => simp at h
  | cons x rest ih =>
    rcases List.mem_cons.mp h with rfl | h
    · exact Nat.le_trans (Nat.le_add_left _ _) (le_foldl_lovelace rest _)
    · exact ih _ h

/-- A running maximum never falls below where it started. -/
theorem le_foldl_max_lovelace (l : List TxOutput) (acc : Nat) :
    acc ≤ l.foldl (fun most o => max most o.lovelace) acc := by
  induction l generalizing acc with
  | nil => simp
  | cons o rest ih => exact Nat.le_trans (Nat.le_max_left _ _) (ih _)

/-- An output's lovelace is at most the largest over a list holding it. -/
theorem lovelace_le_foldl_max (l : List TxOutput) (acc : Nat) (o : TxOutput) (h : o ∈ l) :
    o.lovelace ≤ l.foldl (fun most o => max most o.lovelace) acc := by
  induction l generalizing acc with
  | nil => simp at h
  | cons x rest ih =>
    rcases List.mem_cons.mp h with rfl | h
    · exact Nat.le_trans (Nat.le_max_right _ _) (le_foldl_max_lovelace rest _)
    · exact ih _ h

/-- An output paying a recipient gives it at least its own lovelace. -/
theorem lovelace_le_receivedBy (recipient : Recipient) (outputs : List TxOutput)
    (o : TxOutput) (h : o ∈ outputs) (pays : paysRecipient recipient o = true) :
    o.lovelace ≤ receivedBy recipient outputs := by
  have mem : o ∈ outputs.filter (paysRecipient recipient) := List.mem_filter.mpr ⟨h, pays⟩
  cases recipient <;> simp only [receivedBy]
  · exact lovelace_le_foldl _ 0 o mem
  · exact lovelace_le_foldl _ 0 o mem
  · exact lovelace_le_foldl_max _ 0 o mem

/-- One payment is settled by any output list holding an output that pays its
recipient at least its floor. -/
theorem settle_one (p : Payment) (outputs : List TxOutput)
    (paid : ∃ o ∈ outputs, paysRecipient p.recipient o = true ∧ p.atLeast ≤ o.lovelace) :
    settle [p] outputs = none := by
  obtain ⟨o, h, pays, enough⟩ := paid
  unfold settle
  rw [List.findSome?_eq_none_iff]
  intro recipient judged
  have named : recipient = p.recipient := by
    simpa [List.eraseDups, List.eraseDupsBy, List.eraseDupsBy.loop] using judged
  subst named
  have reached : (outputs.filter (paysRecipient p.recipient)).isEmpty = false := by
    rw [List.isEmpty_eq_false_iff_exists_mem]
    exact ⟨o, List.mem_filter.mpr ⟨h, pays⟩⟩
  simp [reached, owedTo, Nat.le_trans enough (lovelace_le_receivedBy _ outputs o h pays)]

end Singular
