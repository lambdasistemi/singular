import Singular.Model.Assets

/-! Pointwise facts about keyed asset sums. -/

namespace Singular

/-! ### Keyed mint sums

`assetPlus` merges two keyed delta lists into their per-asset sums, and
`assetSame` compares two at every asset they name. These lemmas state both
pointwise, which is what a batch of one needs: its claimed and actual mints are
each one request's list merged into the empty one. -/
theorem assetKind_foldl (ds : List (Asset × Int)) (x : Asset) (n : Int) :
    ds.foldl (fun n p => if p.1 == x then n + p.2 else n) n = n + assetKind ds x := by
  induction ds generalizing n with
  | nil => simp [assetKind]
  | cons p ps ih =>
    simp only [assetKind, List.foldl]
    rw [ih, ih (if p.1 == x then 0 + p.2 else 0)]
    split <;> simp [Int.add_assoc]

theorem assetKind_cons (p : Asset × Int) (ps : List (Asset × Int)) (x : Asset) :
    assetKind (p :: ps) x = (if p.1 = x then p.2 else 0) + assetKind ps x := by
  have h := assetKind_foldl ps x (if p.1 == x then 0 + p.2 else 0)
  simp only [assetKind, List.foldl] at h ⊢
  rw [h]
  by_cases hp : p.1 = x <;> simp [hp]

theorem assetKind_eraseDups_map (f : Asset → Int) (x : Asset) :
    ∀ (L : List Asset), assetKind ((L.eraseDups).map fun y => (y, f y)) x = if x ∈ L then f x else 0
  | [] => by simp [assetKind]
  | a :: as => by
    have ih := assetKind_eraseDups_map f x (as.filter fun b => !b == a)
    rw [List.eraseDups_cons, List.map_cons, assetKind_cons, ih]
    by_cases hax : a = x
    · subst hax; simp
    · have : (x ∈ as.filter fun b => !b == a) ↔ x ∈ as := by
        simp [List.mem_filter]; intro _; exact fun h => hax h.symm
      by_cases hx : x ∈ as <;> simp [hax, hx, this, Ne.symm hax]
termination_by L => L.length
decreasing_by
  simp only [List.length_cons]
  exact Nat.lt_succ_of_le (List.length_filter_le _ _)

theorem assetKind_not_mem (ds : List (Asset × Int)) (x : Asset) (h : x ∉ ds.map Prod.fst) :
    assetKind ds x = 0 := by
  induction ds with
  | nil => simp [assetKind]
  | cons p ps ih =>
    rw [assetKind_cons]
    simp at h
    have hp : p.1 ≠ x := fun e => h.1 (e ▸ rfl)
    simp [hp, ih (by simpa using h.2)]

theorem assetKind_plus (a b : List (Asset × Int)) (x : Asset) :
    assetKind (assetPlus a b) x = assetKind a x + assetKind b x := by
  unfold assetPlus
  rw [assetKind_eraseDups_map]
  split
  · rfl
  · rename_i h
    simp at h
    rw [assetKind_not_mem a x (by simpa using h.1), assetKind_not_mem b x (by simpa using h.2)]
    rfl

theorem assetSame_iff (a b : List (Asset × Int)) :
    assetSame a b = true ↔ ∀ x, assetKind a x = assetKind b x := by
  unfold assetSame
  simp only [List.all_eq_true, beq_iff_eq]
  constructor
  · intro h x
    by_cases hx : x ∈ a.map Prod.fst ++ b.map Prod.fst
    · exact h x hx
    · simp at hx
      rw [assetKind_not_mem a x (by simpa using hx.1), assetKind_not_mem b x (by simpa using hx.2)]
  · intro h x _; exact h x

end Singular
