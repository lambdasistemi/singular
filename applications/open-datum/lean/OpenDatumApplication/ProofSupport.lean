import OpenDatumApplication.Model
import OpenDatumApplication.Driver
import Singular.Lemmas

/-! # Proof support for the open-datum statements

General lemmas the statements in `OpenDatumApplication.Statements` are proved
from. None of them is a product claim: they restate what the unchanged root
registry and the application law already compute, in the form the proofs need.
Registry lemmas are about the root definitions and change nothing there. -/

namespace OpenDatumApplication.ProofSupport

open Singular
open OpenDatumApplication

/-! ## Sums along one asset -/

/-- `assetKind` is the sum of the entries naming the asset. -/
theorem assetKind_eq_sum (ds : List (Asset × Int)) (x : Asset) :
    assetKind ds x = ((ds.filter (·.1 == x)).map (·.2)).sum := by
  suffices h : ∀ (n : Int), ds.foldl (fun n p => if p.1 == x then n + p.2 else n) n =
      n + ((ds.filter (·.1 == x)).map (·.2)).sum by
    simpa [assetKind] using h 0
  induction ds with
  | nil => intro n; simp
  | cons d ds ih =>
    intro n
    by_cases hd : (d.1 == x) = true
    · simp only [List.foldl_cons, hd, if_true, List.filter_cons, List.map_cons, List.sum_cons]
      rw [ih]
      omega
    · simp only [List.foldl_cons, hd, if_false, List.filter_cons, Bool.false_eq_true]
      exact ih n

theorem mem_eraseDups {α} [BEq α] [LawfulBEq α] (x : α) : ∀ l : List α,
    x ∈ l.eraseDups ↔ x ∈ l
  | [] => by simp
  | a :: as => by
    have ih := mem_eraseDups x (as.filter fun b => !b == a)
    rw [List.eraseDups_cons]
    simp only [List.mem_cons]
    constructor
    · rintro (h | h)
      · exact Or.inl h
      · exact Or.inr (List.mem_filter.1 (ih.1 h)).1
    · rintro (h | h)
      · exact Or.inl h
      · by_cases hx : x = a
        · exact Or.inl hx
        · exact Or.inr (ih.2 (List.mem_filter.2 ⟨h, by simpa using hx⟩))
termination_by l => l.length
decreasing_by
  all_goals
    have := List.length_filter_le (fun b => !b == a) as
    simp only [List.length_cons]
    omega

theorem nodup_eraseDups {α} [BEq α] [LawfulBEq α] : ∀ l : List α, l.eraseDups.Nodup
  | [] => by simp
  | a :: as => by
    have ih := nodup_eraseDups (as.filter fun b => !b == a)
    rw [List.eraseDups_cons]
    refine List.nodup_cons.2 ⟨?_, ih⟩
    intro h
    have := (List.mem_filter.1 ((mem_eraseDups _ _).1 h)).2
    simp at this
termination_by l => l.length
decreasing_by
  all_goals
    have := List.length_filter_le (fun b => !b == a) as
    simp only [List.length_cons]
    omega

/-- The per-asset sum of a merge is the sum of the per-asset sums. -/
theorem assetKind_assetPlus (a b : List (Asset × Int)) (x : Asset) :
    assetKind (assetPlus a b) x = assetKind a x + assetKind b x := by
  have hzero : ∀ ds : List (Asset × Int), x ∉ ds.map Prod.fst → assetKind ds x = 0 := by
    intro ds hx
    rw [assetKind_eq_sum]
    have : ds.filter (·.1 == x) = [] := by
      rw [List.filter_eq_nil_iff]
      intro p hp hpx
      exact hx (List.mem_map.2 ⟨p, hp, by simpa using hpx⟩)
    simp [this]
  have hsum : ∀ (D : List Asset), D.Nodup →
      assetKind (D.map fun y => (y, assetKind a y + assetKind b y)) x =
        if x ∈ D then assetKind a x + assetKind b x else 0 := by
    intro D hD
    induction D with
    | nil => simp [assetKind]
    | cons y ys ih =>
      obtain ⟨hy, hys⟩ := List.nodup_cons.1 hD
      rw [assetKind_eq_sum] at ih ⊢
      by_cases hyx : y = x
      · subst hyx
        have hnot : ¬ y ∈ ys := hy
        simp only [List.map_cons, List.filter_cons, beq_self_eq_true, if_true, List.sum_cons]
        rw [ih hys, if_neg hnot, if_pos (List.mem_cons_self ..)]
        simp
      · have hne : (y == x) = false := by simpa using hyx
        simp only [List.map_cons, List.filter_cons, hne, Bool.false_eq_true, if_false]
        rw [ih hys]
        by_cases hx : x ∈ ys
        · rw [if_pos hx, if_pos (List.mem_cons_of_mem _ hx)]
        · have hx' : ¬ x ∈ y :: ys := by
            intro h
            rcases List.mem_cons.1 h with h | h
            · exact hyx h.symm
            · exact hx h
          rw [if_neg hx, if_neg hx']
  rw [assetPlus, hsum _ (nodup_eraseDups _)]
  by_cases hx : x ∈ a.map Prod.fst ++ b.map Prod.fst
  · rw [if_pos ((mem_eraseDups _ _).2 hx)]
  · rw [if_neg (fun h => hx ((mem_eraseDups _ _).1 h))]
    have ha : x ∉ a.map Prod.fst := fun h => hx (List.mem_append.2 (Or.inl h))
    have hb : x ∉ b.map Prod.fst := fun h => hx (List.mem_append.2 (Or.inr h))
    rw [hzero a ha, hzero b hb]
    rfl

/-- Two lists that agree at every asset are `assetSame`. -/
theorem assetSame_of_eq (a b : List (Asset × Int)) (h : ∀ x, assetKind a x = assetKind b x) :
    assetSame a b = true := by
  simp only [assetSame, List.all_eq_true]
  intro x _
  simp [h x]

/-- The actual mint of a batch, summed from an accumulator. -/
theorem assetKind_foldl_delta (bs : List Request) (acc : List (Asset × Int)) (x : Asset) :
    assetKind (bs.foldl (fun acc b => assetPlus acc (assetDelta b)) acc) x =
      assetKind acc x + assetKind (actualMint bs) x := by
  induction bs generalizing acc with
  | nil => simp [actualMint, assetKind]
  | cons b bs ih =>
    simp only [List.foldl_cons, actualMint] at ih ⊢
    rw [ih, ih (assetPlus [] (assetDelta b)), assetKind_assetPlus, assetKind_assetPlus]
    simp [assetKind]
    omega

theorem assetKind_actualMint_cons (b : Request) (bs : List Request) (x : Asset) :
    assetKind (actualMint (b :: bs)) x = assetKind (assetDelta b) x + assetKind (actualMint bs) x := by
  have h := assetKind_foldl_delta bs (assetPlus [] (assetDelta b)) x
  simp only [actualMint, List.foldl_cons] at h ⊢
  rw [h, assetKind_assetPlus]
  simp [assetKind]

/-! ## Settlement -/

/-- A settled payment list gives every recipient at least its summed floors. -/
theorem settle_none_le (ps : List Payment) (outs : List TxOutput) (h : settle ps outs = none) :
    ∀ rcp, owedTo rcp ps ≤ receivedBy rcp outs := by
  intro rcp
  by_cases hr : rcp ∈ ps.map (·.recipient)
  · have hm : rcp ∈ (ps.map (·.recipient)).eraseDups := (mem_eraseDups _ _).2 hr
    unfold settle at h
    have := List.findSome?_eq_none_iff.1 h rcp hm
    dsimp only at this
    by_cases hle : owedTo rcp ps ≤ receivedBy rcp outs
    · exact hle
    · exfalso
      revert this
      split <;> (try split) <;> simp_all
  · have : ps.filter (·.recipient == rcp) = [] := by
      rw [List.filter_eq_nil_iff]
      intro p hp hpr
      exact hr (List.mem_map.2 ⟨p, hp, by simpa using hpr⟩)
    simp [owedTo, this]


/-! ## Registry folds of the application's two edges -/

/-- One step of a nonempty sequential fold. -/
theorem foldActions_cons_ok (s : RegistryState) (b : Request) (bs : List Request) (t : Result)
    (h : foldActions s (b :: bs) = .ok t) :
    ∃ m r, step s b = .ok m ∧ foldActions m.state bs = .ok r ∧ t = combineResults m r := by
  unfold foldActions at h
  simp only [bind, Except.bind, pure, Except.pure] at h
  cases hs : step s b with
  | error e => rw [hs] at h; exact Except.noConfusion rfl rfl (heq_of_eq h)
  | ok m =>
    rw [hs] at h
    dsimp only at h
    cases hr : foldActions m.state bs with
    | error e => rw [hr] at h; exact Except.noConfusion rfl rfl (heq_of_eq h)
    | ok r =>
      rw [hr] at h
      dsimp only at h
      have hEq : combineResults m r = t := by injection h
      exact ⟨m, r, rfl, hr, hEq.symm⟩

theorem foldActions_nil_ok (s : RegistryState) (t : Result) (h : foldActions s [] = .ok t) :
    t = emptyResult s := by
  unfold foldActions at h
  injection h with h
  exact h.symm

/-- An accepted step of an insertion or a termination: every other key keeps
its leaf, the application policy is kept, and the key moves from unknown to
active or from active to terminal, minting plus or minus one active token. -/
theorem step_app_edge (s : RegistryState) (a : Request) (r : Result) (h : step s a = .ok r)
    (he : a.edge = .insertActive ∨ a.edge = .updateTerminal) :
    (∀ k, k ≠ a.key → trieGet r.state.trie k = trieGet s.trie k) ∧
    r.state.config.applicationPolicy = s.config.applicationPolicy ∧
    (a.edge = .insertActive → trieGet s.trie a.key = .unknown ∧
        trieGet r.state.trie a.key = .known .active ∧ r.mint = [((.active, a.key), 1)]) ∧
    (a.edge = .updateTerminal → trieGet s.trie a.key = .known .active ∧
        trieGet r.state.trie a.key = .known .terminal ∧ r.mint = [((.active, a.key), -1)]) := by
  obtain ⟨href, hr⟩ := step_eq_ok s a r h
  subst hr
  obtain ⟨_, _, _, _, hcase⟩ := (refusal_none_iff s a).1 href
  have hbefore : (a.edge = .insertActive → trieGet s.trie a.key = .unknown) ∧
      (a.edge = .updateTerminal → trieGet s.trie a.key = .known .active) := by
    constructor
    · intro he'
      rcases hcase with ⟨_, hb⟩ | ⟨he, _, _⟩
      · exact hb
      · rw [he'] at he; exact absurd he (by decide)
    · intro he'
      rcases hcase with ⟨he, _⟩ | ⟨_, hb, _⟩
      · rw [he'] at he; exact absurd he (by decide)
      · exact hb
  rcases he with he | he
  · obtain ⟨h1, h2, _, _, h5, _⟩ := applyEdge_insertActive s a he
    refine ⟨fun k hk => by rw [h1]; exact trieGet_set_of_ne _ _ _ _ hk, by rw [h2], fun _ => ?_,
      fun he' => by rw [he] at he'; exact absurd he' (by decide)⟩
    exact ⟨hbefore.1 he, by rw [h1]; exact trieGet_set_eq _ _ _, h5⟩
  · obtain ⟨h1, h2, _, _, h5, _⟩ := applyEdge_updateTerminal s a he
    refine ⟨fun k hk => by rw [h1]; exact trieGet_set_of_ne _ _ _ _ hk, by rw [h2],
      fun he' => by rw [he] at he'; exact absurd he' (by decide), fun _ => ?_⟩
    exact ⟨hbefore.2 he, by rw [h1]; exact trieGet_set_eq _ _ _, h5⟩

/-- Consistency survives a whole sequential fold. -/
theorem foldActions_consistent : ∀ (batch : List Request) (s : RegistryState) (t : Result),
    Consistent s → foldActions s batch = .ok t → Consistent t.state
  | [], s, t, hc, h => by
    rw [foldActions_nil_ok s t h]
    exact hc
  | b :: bs, s, t, hc, h => by
    obtain ⟨m, r, hs, hr, rfl⟩ := foldActions_cons_ok s b bs t h
    exact foldActions_consistent bs m.state r (step_ok_consistent s b m hc hs) hr

/-- The per-key record of a fold of insertions and terminations: the edges it
applies at the key are none, one insertion, one termination, or an insertion
then a termination, with the leaf and the active mint at the key they imply. -/
theorem foldActions_key (k : Key) : ∀ (batch : List Request) (s : RegistryState) (t : Result),
    foldActions s batch = .ok t →
    (∀ b ∈ batch, b.edge = .insertActive ∨ b.edge = .updateTerminal) →
    t.state.config.applicationPolicy = s.config.applicationPolicy ∧
    ((batch.filter (·.key == k)).map (·.edge) = [] ∧ trieGet t.state.trie k = trieGet s.trie k ∧
        assetKind t.mint (.active, k) = 0 ∨
     (batch.filter (·.key == k)).map (·.edge) = [.insertActive] ∧ trieGet s.trie k = .unknown ∧
        trieGet t.state.trie k = .known .active ∧ assetKind t.mint (.active, k) = 1 ∨
     (batch.filter (·.key == k)).map (·.edge) = [.updateTerminal] ∧
        trieGet s.trie k = .known .active ∧ trieGet t.state.trie k = .known .terminal ∧
        assetKind t.mint (.active, k) = -1 ∨
     (batch.filter (·.key == k)).map (·.edge) = [.insertActive, .updateTerminal] ∧
        trieGet s.trie k = .unknown ∧ trieGet t.state.trie k = .known .terminal ∧
        assetKind t.mint (.active, k) = 0)
  | [], s, t, h, _ => by
    rw [foldActions_nil_ok s t h]
    exact ⟨rfl, Or.inl ⟨rfl, rfl, rfl⟩⟩
  | b :: bs, s, t, h, hE => by
    obtain ⟨m, r, hs, hr, rfl⟩ := foldActions_cons_ok s b bs t h
    have hEb := hE b (List.mem_cons_self ..)
    obtain ⟨hother, hpol, hins, hterm⟩ := step_app_edge s b m hs hEb
    obtain ⟨ipol, ih⟩ :=
      foldActions_key k bs m.state r hr (fun x hx => hE x (List.mem_cons_of_mem _ hx))
    have hmint : assetKind (combineResults m r).mint (.active, k) =
        assetKind m.mint (.active, k) + assetKind r.mint (.active, k) := by
      simp only [combineResults]
      exact assetKind_assetPlus _ _ _
    refine ⟨by simp only [combineResults]; rw [ipol, hpol], ?_⟩
    rw [hmint]
    simp only [combineResults]
    by_cases hk : b.key = k
    · subst hk
      have hfil : (b :: bs).filter (·.key == b.key) = b :: bs.filter (·.key == b.key) := by
        simp
      rw [hfil, List.map_cons]
      rcases hEb with he | he
      · obtain ⟨h0, h1, h2⟩ := hins he
        have hm : assetKind m.mint (.active, b.key) = 1 := by rw [h2]; simp [assetKind]
        rw [he, hm]
        rcases ih with ⟨e, l, a⟩ | ⟨e, l, -⟩ | ⟨e, l, l', a⟩ | ⟨e, l, -⟩
        · exact Or.inr (Or.inl ⟨by rw [e], h0, by rw [l, h1], by rw [a]; rfl⟩)
        · rw [h1] at l; exact absurd l (by decide)
        · exact Or.inr (Or.inr (Or.inr ⟨by rw [e], h0, l', by rw [a]; rfl⟩))
        · rw [h1] at l; exact absurd l (by decide)
      · obtain ⟨h0, h1, h2⟩ := hterm he
        have hm : assetKind m.mint (.active, b.key) = -1 := by rw [h2]; simp [assetKind]
        rw [he, hm]
        rcases ih with ⟨e, l, a⟩ | ⟨e, l, -⟩ | ⟨e, l, -⟩ | ⟨e, l, -⟩
        · exact Or.inr (Or.inr (Or.inl ⟨by rw [e], h0, by rw [l, h1], by rw [a]; rfl⟩))
        · rw [h1] at l; exact absurd l (by decide)
        · rw [h1] at l; exact absurd l (by decide)
        · rw [h1] at l; exact absurd l (by decide)
    · have hfil : (b :: bs).filter (·.key == k) = bs.filter (·.key == k) := by
        simp [hk]
      have hm : assetKind m.mint (.active, k) = 0 := by
        rcases hEb with he | he
        · rw [(hins he).2.2]
          simp [assetKind, hk]
        · rw [(hterm he).2.2]
          simp [assetKind, hk]
      rw [hfil, hm, Int.zero_add, ← hother k (Ne.symm hk)]
      exact ih


/-! ## Monadic plumbing -/

theorem bind_ok {α β : Type} {x : Except String α} {f : α → Except String β} {b : β}
    (h : x >>= f = .ok b) : ∃ a, x = .ok a ∧ f a = .ok b := by
  cases x with
  | error e =>
    first
      | exact Except.noConfusion rfl rfl (heq_of_eq h)
      | cases h
      | (simp [bind, Except.bind] at h)
  | ok a => exact ⟨a, rfl, h⟩

theorem ensure_ok {c : Bool} {why : String} {u : Unit} (h : ensure c why = .ok u) : c = true := by
  cases c with
  | false =>
    first
      | exact Except.noConfusion rfl rfl (heq_of_eq h)
      | (simp [ensure] at h)
  | true => rfl

theorem ok_inj {α : Type} {a b : α} (h : (Except.ok a : Except String α) = .ok b) : a = b := by
  first
    | (injection h with h'; exact h')
    | (cases h; rfl)

/-! ## Application lookups -/

theorem carriesKey_single (key k : Key) : carriesKey [((.active, key), 1)] k = true ↔ key = k := by
  simp [carriesKey]

end OpenDatumApplication.ProofSupport
