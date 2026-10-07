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
  | error e => rw [hs] at h; exact Except.noConfusion h
  | ok m =>
    rw [hs] at h
    dsimp only at h
    cases hr : foldActions m.state bs with
    | error e => rw [hr] at h; exact Except.noConfusion h
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
  have hnone := (refusal_none_iff s a).1 href
  have hbefore : (a.edge = .insertActive → trieGet s.trie a.key = .unknown) ∧
      (a.edge = .updateTerminal → trieGet s.trie a.key = .known .active) := by
    constructor
    · intro he'
      rcases hnone with ⟨hw, _⟩ | ⟨ap, _, _, _, hc⟩
      · rw [he'] at hw; exact absurd hw (by decide)
      · rcases hc with ⟨hc1, hc2⟩ | ⟨hc1, hc2⟩ | ⟨hc1, hc2, -⟩ | ⟨hc1, hc2, -⟩ | ⟨hc1, hc2, -⟩ |
            ⟨hc1, hc2, -⟩ <;>
          first
            | exact hc2
            | (rw [he'] at hc1; exact absurd hc1 (by decide))
    · intro he'
      rcases hnone with ⟨hw, _⟩ | ⟨ap, _, _, _, hc⟩
      · rw [he'] at hw; exact absurd hw (by decide)
      · rcases hc with ⟨hc1, hc2⟩ | ⟨hc1, hc2⟩ | ⟨hc1, hc2, -⟩ | ⟨hc1, hc2, -⟩ | ⟨hc1, hc2, -⟩ |
            ⟨hc1, hc2, -⟩ <;>
          first
            | exact hc2
            | (rw [he'] at hc1; exact absurd hc1 (by decide))
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
      | exact Except.noConfusion h
      | cases h
      | (simp [bind, Except.bind] at h)
  | ok a => exact ⟨a, rfl, h⟩

theorem ensure_ok {c : Bool} {why : String} {u : Unit} (h : ensure c why = .ok u) : c = true := by
  cases c with
  | false =>
    first
      | exact Except.noConfusion h
      | (simp [ensure] at h)
  | true => rfl

theorem ok_inj {α : Type} {a b : α} (h : (Except.ok a : Except String α) = .ok b) : a = b := by
  first
    | (injection h with h'; exact h')
    | (cases h; rfl)

/-! ## Application lookups -/

theorem carriesKey_single (key k : Key) : carriesKey [((.active, key), 1)] k = true ↔ key = k := by
  simp [carriesKey]

theorem pendingOf_spec (w : World) (e : Edge) (k : Key) (p : Pending)
    (h : pendingOf w e k = some p) : p ∈ w.pending ∧ p.request.edge = e ∧ p.request.key = k := by
  have hm := List.mem_of_find?_eq_some h
  have hp := List.find?_some h
  simp only [Bool.and_eq_true, beq_iff_eq] at hp
  exact ⟨hm, hp.1, hp.2⟩

theorem outputAt_mem (w : World) (ref : Nat) (o : AppOutput) (h : outputAt w ref = some o) :
    o ∈ w.outputs :=
  List.mem_of_find?_eq_some h

theorem outputOfKey_spec (w : World) (k : Key) (o : AppOutput) (h : outputOfKey w k = some o) :
    o ∈ w.outputs ∧ o.address = appAddress w.app ∧ carriesKey o.assets k = true := by
  have hm := List.mem_of_find?_eq_some h
  have hp := List.find?_some h
  simp only [Bool.and_eq_true, beq_iff_eq] at hp
  exact ⟨hm, hp.1, hp.2⟩

/-- In a consistent world a live output carries a key's token exactly when it is
that key's output. -/
theorem carries_iff (w : World) (hc : AppConsistent w) (o : AppOutput) (ho : o ∈ w.outputs)
    (k : Key) : carriesKey o.assets k = true ↔ o.envelope.control.key = k := by
  obtain ⟨_, _, h3, _, _⟩ := hc
  obtain ⟨_, hassets, _, _, _, _⟩ := h3 o ho
  rw [hassets]
  exact carriesKey_single _ _

theorem outputOfKey_consistent (w : World) (hc : AppConsistent w) (k : Key) (o : AppOutput)
    (h : outputOfKey w k = some o) :
    o ∈ w.outputs ∧ o.envelope.control.key = k ∧ trieGet w.registry.trie k = .known .active := by
  obtain ⟨hm, _, hcar⟩ := outputOfKey_spec w k o h
  have hk := (carries_iff w hc o hm k).1 hcar
  obtain ⟨_, _, h3, _, _⟩ := hc
  obtain ⟨_, _, _, _, htrie, _⟩ := h3 o hm
  exact ⟨hm, hk, hk ▸ htrie⟩

/-- A consistent world's live output is its key's output. -/
theorem outputOfKey_of_mem (w : World) (hc : AppConsistent w) (o : AppOutput)
    (ho : o ∈ w.outputs) : outputOfKey w o.envelope.control.key = some o := by
  have hpo : (o.address == appAddress w.app && carriesKey o.assets o.envelope.control.key) = true := by
    obtain ⟨haddr, _, _, _, _, _⟩ := hc.2.2.1 o ho
    simp only [Bool.and_eq_true, beq_iff_eq]
    exact ⟨haddr, (carries_iff w hc o ho _).2 rfl⟩
  cases hf : outputOfKey w o.envelope.control.key with
  | none =>
    exact absurd hpo (by
      have := List.find?_eq_none.1 hf o ho
      simpa using this)
  | some x =>
    obtain ⟨hxm, hxk, _⟩ := outputOfKey_consistent w hc _ x hf
    obtain ⟨_, _, _, h4, _⟩ := hc
    rw [h4 x hxm o ho (Or.inl hxk)]

/-- A key with a live output in a consistent world is Active; so an unknown key
has none. -/
theorem outputOfKey_none_of_unknown (w : World) (hc : AppConsistent w) (k : Key)
    (hk : trieGet w.registry.trie k = .unknown) : outputOfKey w k = none := by
  cases hf : outputOfKey w k with
  | none => rfl
  | some o =>
    have := (outputOfKey_consistent w hc k o hf).2.2
    rw [hk] at this
    exact absurd this (by decide)

/-! ## Selected rows -/

/-- What `selectRow` accepts, under the standard law. -/
theorem selectRow_spec (w : World) (x : Edge × Key) (row : FoldRow)
    (h : selectRow Law.standard w x = .ok row) :
    pendingOf w x.1 x.2 = some row.pending ∧ row.pending ∈ w.pending ∧
    row.pending.request.edge = x.1 ∧ row.pending.request.key = x.2 ∧
    ((x.1 = .insertActive ∧ row.spent = none ∧ ∃ e, row.pending.envelope = some e ∧
        row.pending.request.output = destinationOf w.app e ∧
        e.control.deposit = row.pending.request.deposit ∧ e.control.registry = w.registryAsset) ∨
     (x.1 = .updateTerminal ∧ ∃ o, outputOfKey w x.2 = some o ∧ row.spent = some o)) := by
  obtain ⟨e0, k0⟩ := x
  unfold selectRow at h
  cases hp : pendingOf w e0 k0 with
  | none =>
    simp only [hp] at h
    first
      | exact Except.noConfusion h
      | (simp at h)
  | some p =>
    simp only [hp] at h
    obtain ⟨hpm, hpe, hpk⟩ := pendingOf_spec w e0 k0 p hp
    cases e0 with
    | insertActive =>
      cases he : p.envelope with
      | none =>
        simp only [he] at h
        first
          | exact Except.noConfusion h
          | (simp at h)
      | some en =>
        simp only [he] at h
        obtain ⟨_, e1, h⟩ := bind_ok h
        obtain ⟨_, _, h⟩ := bind_ok h
        obtain ⟨_, e2, h⟩ := bind_ok h
        have g1 := ensure_ok e1
        have g2 := ensure_ok e2
        simp only [Bool.and_eq_true, beq_iff_eq] at g1
        have g2' : en.control.registry = w.registryAsset := by
          simpa [Law.standard] using g2
        have hrow := (ok_inj h).symm
        subst hrow
        exact ⟨by first | exact hp | rfl, hpm, hpe, hpk, Or.inl ⟨rfl, rfl, en, he, g1.1, g1.2, g2'⟩⟩
    | updateTerminal =>
      cases ho : outputOfKey w k0 with
      | none =>
        simp only [ho] at h
        first
          | exact Except.noConfusion h
          | (simp at h)
      | some o =>
        simp only [ho] at h
        obtain ⟨_, _, h⟩ := bind_ok h
        obtain ⟨_, _, h⟩ := bind_ok h
        have hrow := (ok_inj h).symm
        subst hrow
        exact ⟨by first | exact hp | rfl, hpm, hpe, hpk, Or.inr ⟨rfl, o, by first | exact ho | rfl, rfl⟩⟩
    | _ =>
      first
        | exact Except.noConfusion h
        | (simp at h)

/-- An insertion `selectRow` accepts carries a datum. -/
theorem selectRow_insert_names_datum (w : World) (key : Key) (row : FoldRow)
    (h : selectRow Law.standard w (.insertActive, key) = .ok row) :
    row.pending.request.datum.isSome = true := by
  unfold selectRow at h
  cases hp : pendingOf w .insertActive key with
  | none =>
    simp only [hp] at h
    first
      | exact Except.noConfusion h
      | (simp at h)
  | some p =>
    simp only [hp] at h
    cases he : p.envelope with
    | none =>
      simp only [he] at h
      first
        | exact Except.noConfusion h
        | (simp at h)
    | some en =>
      simp only [he] at h
      obtain ⟨_, _, h⟩ := bind_ok h
      obtain ⟨_, e2, h⟩ := bind_ok h
      obtain ⟨_, _, h⟩ := bind_ok h
      have hrow := (ok_inj h).symm
      subst hrow
      have hd := ensure_ok e2
      simp only [beq_iff_eq] at hd
      simp [hd]

theorem mapM_ok_mem {α β : Type} (f : α → Except String β) : ∀ (xs : List α) (ys : List β),
    xs.mapM f = .ok ys → (∀ y ∈ ys, ∃ x ∈ xs, f x = .ok y) ∧ (∀ x ∈ xs, ∃ y ∈ ys, f x = .ok y)
  | [], ys, h => by
    have : ys = [] := by
      simp only [List.mapM_nil, pure, Except.pure] at h
      exact (ok_inj h).symm
    subst this
    simp
  | x :: xs, ys, h => by
    rw [List.mapM_cons] at h
    obtain ⟨y, hy, h⟩ := bind_ok h
    obtain ⟨ys', hys, h⟩ := bind_ok h
    have hyy : ys = y :: ys' := by
      simp only [pure, Except.pure] at h
      exact (ok_inj h).symm
    subst hyy
    obtain ⟨ih1, ih2⟩ := mapM_ok_mem f xs ys' hys
    constructor
    · intro z hz
      rcases List.mem_cons.1 hz with rfl | hz
      · exact ⟨x, List.mem_cons_self .., hy⟩
      · obtain ⟨x', hx', hf⟩ := ih1 z hz
        exact ⟨x', List.mem_cons_of_mem _ hx', hf⟩
    · intro z hz
      rcases List.mem_cons.1 hz with rfl | hz
      · exact ⟨y, List.mem_cons_self .., hy⟩
      · obtain ⟨y', hy', hf⟩ := ih2 z hz
        exact ⟨y', List.mem_cons_of_mem _ hy', hf⟩

/-- Every row of an accepted selection is a `selectRow` of one of its entries,
and the folded requests are insertions and terminations. -/
theorem rows_spec (w : World) (sel : List (Edge × Key)) (rows : List FoldRow)
    (h : sel.mapM (selectRow Law.standard w) = .ok rows) :
    (∀ row ∈ rows, ∃ x ∈ sel, selectRow Law.standard w x = .ok row) ∧
    (∀ x ∈ sel, ∃ row ∈ rows, selectRow Law.standard w x = .ok row) ∧
    (∀ b ∈ rows.map (·.pending.request), b.edge = .insertActive ∨ b.edge = .updateTerminal) := by
  obtain ⟨h1, h2⟩ := mapM_ok_mem _ sel rows h
  refine ⟨h1, h2, ?_⟩
  intro b hb
  obtain ⟨row, hrow, rfl⟩ := List.mem_map.1 hb
  obtain ⟨x, _, hx⟩ := h1 row hrow
  obtain ⟨_, _, hedge, _, hcase⟩ := selectRow_spec w x row hx
  rcases hcase with ⟨he, _⟩ | ⟨he, _⟩
  · exact Or.inl (hedge.trans he)
  · exact Or.inr (hedge.trans he)

/-! ## Created outputs -/

theorem createdOutputs_refs (app : App) : ∀ (ref : Nat) (rows : List FoldRow),
    (createdOutputs app ref rows).map (·.ref) =
      List.range' ref (createdOutputs app ref rows).length
  | _, [] => by simp [createdOutputs]
  | ref, row :: rows => by
    unfold createdOutputs
    split
    · simp only [List.map_cons, List.length_cons, List.range'_succ]
      rw [createdOutputs_refs app (ref + 1) rows]
    · exact createdOutputs_refs app ref rows

theorem createdOutputs_ref_bounds (app : App) (ref : Nat) (rows : List FoldRow) (o : AppOutput)
    (ho : o ∈ createdOutputs app ref rows) :
    ref ≤ o.ref ∧ o.ref < ref + (createdOutputs app ref rows).length := by
  have hm : o.ref ∈ (createdOutputs app ref rows).map (·.ref) := List.mem_map.2 ⟨o, ho, rfl⟩
  rw [createdOutputs_refs] at hm
  obtain ⟨i, hi, hoi⟩ := List.mem_range'.1 hm
  omega

theorem createdOutputs_refs_nodup (app : App) (ref : Nat) (rows : List FoldRow) :
    ((createdOutputs app ref rows).map (·.ref)).Nodup := by
  rw [createdOutputs_refs]
  exact List.nodup_range' ..

/-- Every created output is the delivery of one selected insertion. -/
theorem createdOutputs_mem (app : App) : ∀ (ref : Nat) (rows : List FoldRow) (o : AppOutput),
    o ∈ createdOutputs app ref rows →
    ∃ row ∈ rows, row.pending.request.edge = .insertActive ∧
      row.pending.envelope = some o.envelope ∧ o.address = appAddress app ∧
      o.lovelace = row.pending.request.deposit ∧
      o.assets = [((.active, row.pending.request.key), 1)]
  | _, [], o, h => by simp [createdOutputs] at h
  | ref, row :: rows, o, h => by
    unfold createdOutputs at h
    split at h
    · rename_i he hen
      rcases List.mem_cons.1 h with rfl | h
      · exact ⟨row, List.mem_cons_self .., he, by rw [hen], rfl, rfl, rfl⟩
      · obtain ⟨r, hr, rest⟩ := createdOutputs_mem app (ref + 1) rows o h
        exact ⟨r, List.mem_cons_of_mem _ hr, rest⟩
    · obtain ⟨r, hr, rest⟩ := createdOutputs_mem app ref rows o h
      exact ⟨r, List.mem_cons_of_mem _ hr, rest⟩

/-- Every selected insertion with an envelope delivers one created output. -/
theorem createdOutputs_of_row (app : App) : ∀ (ref : Nat) (rows : List FoldRow) (row : FoldRow)
    (e : Envelope), row ∈ rows → row.pending.request.edge = .insertActive →
    row.pending.envelope = some e →
    ∃ o ∈ createdOutputs app ref rows, o.envelope = e ∧
      o.assets = [((.active, row.pending.request.key), 1)] ∧
      o.lovelace = row.pending.request.deposit ∧ o.address = appAddress app
  | _, [], _, _, h, _, _ => by simp at h
  | ref, r :: rows, row, e, h, he, hen => by
    rcases List.mem_cons.1 h with rfl | h
    · unfold createdOutputs
      rw [he, hen]
      exact ⟨_, List.mem_cons_self .., rfl, rfl, rfl, rfl⟩
    · unfold createdOutputs
      split
      · obtain ⟨o, ho, rest⟩ := createdOutputs_of_row app (ref + 1) rows row e h he hen
        exact ⟨o, List.mem_cons_of_mem _ ho, rest⟩
      · exact createdOutputs_of_row app ref rows row e h he hen


/-! ## The shape of an accepted fold -/

/-- An edge the fold applies at a key appears in that key's edge record. -/
theorem edge_mem_key_record (batch : List Request) (b : Request) (hb : b ∈ batch) :
    b.edge ∈ (batch.filter (·.key == b.key)).map (·.edge) :=
  List.mem_map.2 ⟨b, List.mem_filter.2 ⟨hb, by simp⟩, rfl⟩

/-- A request in a key's edge record is a request of the batch at that key. -/
theorem key_record_mem (batch : List Request) (k : Key) (e : Edge)
    (h : e ∈ (batch.filter (·.key == k)).map (·.edge)) :
    ∃ b ∈ batch, b.key = k ∧ b.edge = e := by
  obtain ⟨b, hb, he⟩ := List.mem_map.1 h
  obtain ⟨hb, hk⟩ := List.mem_filter.1 hb
  exact ⟨b, hb, by simpa using hk, he⟩

/-- The deliveries a fold of insertions and terminations creates carry
pairwise different assets: a key is inserted at most once per fold. -/
theorem created_assets_nodup (app : App) : ∀ (rows : List FoldRow) (ref : Nat)
    (s : RegistryState) (t : Result),
    foldActions s (rows.map (·.pending.request)) = .ok t →
    (∀ b ∈ rows.map (·.pending.request), b.edge = .insertActive ∨ b.edge = .updateTerminal) →
    ((createdOutputs app ref rows).map (·.assets)).Nodup
  | [], _, _, _, _, _ => by simp [createdOutputs]
  | r :: rs, ref, s, t, h, hE => by
    rw [List.map_cons] at h
    obtain ⟨m, t', hs, hrest, _⟩ := foldActions_cons_ok s _ _ t h
    have hErs : ∀ b ∈ rs.map (·.pending.request), b.edge = .insertActive ∨
        b.edge = .updateTerminal := fun b hb => hE b (List.mem_cons_of_mem _ hb)
    unfold createdOutputs
    split
    · rename_i he hen
      refine List.nodup_cons.2 ⟨?_, created_assets_nodup app rs (ref + 1) m.state t' hrest hErs⟩
      intro hmem
      obtain ⟨o, ho, hoa⟩ := List.mem_map.1 hmem
      obtain ⟨row', hrow', he', _, _, _, hassets⟩ := createdOutputs_mem app (ref + 1) rs o ho
      have hkeq : row'.pending.request.key = r.pending.request.key := by
        rw [hassets] at hoa
        simpa using hoa
      obtain ⟨_, _, hins, _⟩ :=
        step_app_edge s r.pending.request m hs (hE _ (List.mem_cons_self ..))
      have hactive := (hins he).2.1
      have hb : row'.pending.request ∈ rs.map (·.pending.request) := List.mem_map.2 ⟨row', hrow', rfl⟩
      have hrec := edge_mem_key_record _ _ hb
      rw [he', hkeq] at hrec
      obtain ⟨_, cases⟩ := foldActions_key r.pending.request.key _ _ _ hrest hErs
      rcases cases with ⟨e, _⟩ | ⟨_, l, _⟩ | ⟨e, _⟩ | ⟨_, l, _⟩
      · rw [e] at hrec; exact absurd hrec (by simp)
      · rw [hactive] at l; exact absurd l (by decide)
      · rw [e] at hrec; exact absurd hrec (by simp)
      · rw [hactive] at l; exact absurd l (by decide)
    · exact created_assets_nodup app rs ref m.state t' hrest hErs

/-- Everything a fold over a consistent world establishes about outputs and
leaves: kept outputs keep their Active leaf, spent outputs were live, created
outputs are fresh, well-formed, Active afterwards and of pairwise different
keys, and the registry stays consistent under the same application policy. -/
theorem fold_shape (w : World) (hc : AppConsistent w) (sel : List (Edge × Key))
    (rows : List FoldRow) (t : Result)
    (hrows : sel.mapM (selectRow Law.standard w) = .ok rows)
    (ht : foldBatch w.registry (rows.map (·.pending.request)) = .ok t) :
    (∀ o ∈ w.outputs, (rows.filterMap (·.spent)).contains o = false →
        trieGet t.state.trie o.envelope.control.key = .known .active) ∧
    (∀ o ∈ rows.filterMap (·.spent), o ∈ w.outputs) ∧
    (∀ o ∈ createdOutputs w.app w.nextRef rows,
        trieGet w.registry.trie o.envelope.control.key = .unknown ∧
        trieGet t.state.trie o.envelope.control.key = .known .active ∧
        o.address = appAddress w.app ∧ o.assets = [((.active, o.envelope.control.key), 1)] ∧
        o.envelope.control.registry = w.registryAsset ∧ o.envelope.control.deposit ≤ o.lovelace) ∧
    ((createdOutputs w.app w.nextRef rows).map (·.envelope.control.key)).Nodup ∧
    Consistent t.state ∧
    t.state.config.applicationPolicy = w.registry.config.applicationPolicy := by
  obtain ⟨_, hacts⟩ := foldBatch_inv _ _ _ ht
  obtain ⟨hr1, _, hE⟩ := rows_spec w sel rows hrows
  have hkey := fun k => foldActions_key k _ _ _ hacts hE
  have hrow : ∀ row ∈ rows, row.pending ∈ w.pending ∧
      ((row.pending.request.edge = .insertActive ∧ row.spent = none) ∨
       (row.pending.request.edge = .updateTerminal ∧
        ∃ o, outputOfKey w row.pending.request.key = some o ∧ row.spent = some o)) := by
    intro row hr
    obtain ⟨x, _, hx⟩ := hr1 row hr
    obtain ⟨_, hpm, hedge, hk, hcase⟩ := selectRow_spec w x row hx
    refine ⟨hpm, ?_⟩
    rcases hcase with ⟨he, hsp, _⟩ | ⟨he, o, ho, hsp⟩
    · exact Or.inl ⟨hedge.trans he, hsp⟩
    · exact Or.inr ⟨hedge.trans he, o, by rw [hk]; exact ho, hsp⟩
  have hbatch : ∀ b ∈ rows.map (·.pending.request), ∃ row ∈ rows, row.pending.request = b :=
    fun b hb => by
      obtain ⟨row, hr, rfl⟩ := List.mem_map.1 hb
      exact ⟨row, hr, rfl⟩
  -- a terminated key is Active at the start
  have hterm_active : ∀ k, .updateTerminal ∈
      ((rows.map (·.pending.request)).filter (·.key == k)).map (·.edge) →
      ∃ o, outputOfKey w k = some o ∧ o ∈ rows.filterMap (·.spent) ∧
        trieGet w.registry.trie k = .known .active := by
    intro k hmem
    obtain ⟨b, hb, hbk, hbe⟩ := key_record_mem _ k _ hmem
    obtain ⟨row, hr, rfl⟩ := hbatch b hb
    rcases (hrow row hr).2 with ⟨he, _⟩ | ⟨_, o, ho, hsp⟩
    · rw [he] at hbe; exact absurd hbe (by decide)
    · rw [hbk] at ho
      exact ⟨o, ho, List.mem_filterMap.2 ⟨row, hr, hsp⟩, (outputOfKey_consistent w hc k o ho).2.2⟩
  have hspent : ∀ o ∈ rows.filterMap (·.spent), o ∈ w.outputs := by
    intro o ho
    obtain ⟨row, hr, hsp⟩ := List.mem_filterMap.1 ho
    rcases (hrow row hr).2 with ⟨_, hnone⟩ | ⟨_, o', ho', hsp'⟩
    · rw [hnone] at hsp; exact Option.noConfusion hsp
    · rw [hsp] at hsp'
      have : o = o' := Option.some.inj hsp'
      subst this
      exact (outputOfKey_consistent w hc _ o ho').1
  refine ⟨?_, hspent, ?_, ?_, foldActions_consistent _ _ _ hc.1 hacts, (hkey 0).1⟩
  · -- kept outputs
    intro o ho hkept
    have hact : trieGet w.registry.trie o.envelope.control.key = .known .active :=
      (hc.2.2.1 o ho).2.2.2.2.1
    rcases (hkey o.envelope.control.key).2 with ⟨_, l, _⟩ | ⟨_, l, _⟩ | ⟨e, _, _⟩ | ⟨_, l, _⟩
    · rw [l]; exact hact
    · rw [hact] at l; exact absurd l (by decide)
    · obtain ⟨o', ho', hsp, _⟩ := hterm_active _ (by rw [e]; exact List.mem_singleton_self _)
      obtain ⟨ho'm, ho'k, _⟩ := outputOfKey_consistent w hc _ o' ho'
      have hoo : o' = o := hc.2.2.2.1 o' ho'm o ho (Or.inl ho'k)
      subst hoo
      have : (rows.filterMap (·.spent)).contains o' = true := List.contains_iff_mem.2 hsp
      rw [this] at hkept
      exact absurd hkept (by decide)
    · rw [hact] at l; exact absurd l (by decide)
  · -- created outputs
    intro o ho
    obtain ⟨row, hr, hedge, henv, haddr, hlove, hassets⟩ := createdOutputs_mem _ _ _ o ho
    have hpend := hc.2.2.2.2 row.pending (hrow row hr).1
    rcases hpend with ⟨_, e', he', _, hdep, hek, hreg⟩ | ⟨he, _⟩
    · rw [henv] at he'
      have hee : o.envelope = e' := Option.some.inj he'
      subst hee
      have hb : row.pending.request ∈ rows.map (·.pending.request) := List.mem_map.2 ⟨row, hr, rfl⟩
      have hrec := edge_mem_key_record _ _ hb
      rw [hedge, ← hek] at hrec
      rcases (hkey o.envelope.control.key).2 with ⟨e, _⟩ | ⟨_, l0, l1, _⟩ | ⟨e, _⟩ | ⟨e, l0, _⟩
      · rw [e] at hrec; exact absurd hrec (by simp)
      · refine ⟨l0, l1, haddr, by rw [hassets, hek], hreg, by rw [hlove, hdep]; exact Nat.le_refl _⟩
      · rw [e] at hrec; exact absurd hrec (by simp)
      · obtain ⟨_, _, _, hact⟩ := hterm_active _ (by rw [e]; simp)
        rw [hact] at l0; exact absurd l0 (by decide)
    · rw [hedge] at he; exact absurd he (by decide)
  · -- created keys are pairwise different
    have hn := created_assets_nodup w.app rows w.nextRef w.registry t hacts hE
    have hmap : (createdOutputs w.app w.nextRef rows).map (·.assets) =
        ((createdOutputs w.app w.nextRef rows).map (·.envelope.control.key)).map
          (fun k => [((TokenKind.active, k), (1 : Int))]) := by
      rw [List.map_map]
      apply List.map_congr_left
      intro o ho
      obtain ⟨row, hr, hedge, henv, _, _, hassets⟩ := createdOutputs_mem _ _ _ o ho
      rcases hc.2.2.2.2 row.pending (hrow row hr).1 with ⟨_, e', he', _, _, hek, _⟩ | ⟨he, _⟩
      · rw [henv] at he'
        have hee : o.envelope = e' := Option.some.inj he'
        subst hee
        simp only [Function.comp, hassets, hek]
      · rw [hedge] at he; exact absurd he (by decide)
    rw [hmap] at hn
    exact List.Pairwise.of_map _ (fun a b hab heq => hab (by rw [heq])) hn


/-! ## Preservation cores -/

theorem nodup_map_inj {α β : Type} (f : α → β) : ∀ {l : List α}, (l.map f).Nodup →
    ∀ a ∈ l, ∀ b ∈ l, f a = f b → a = b
  | [], _, a, ha, _, _, _ => absurd ha (List.not_mem_nil)
  | x :: xs, h, a, ha, b, hb, hab => by
    rw [List.map_cons, List.nodup_cons] at h
    rcases List.mem_cons.1 ha with ha' | ha' <;> rcases List.mem_cons.1 hb with hb' | hb'
    · rw [ha', hb']
    · subst ha'
      exact absurd (by rw [hab]; exact List.mem_map.2 ⟨b, hb', rfl⟩) h.1
    · subst hb'
      exact absurd (by rw [← hab]; exact List.mem_map.2 ⟨a, ha', rfl⟩) h.1
    · exact nodup_map_inj f h.2 a ha' b hb' hab

theorem outputs_nodup (w : World) (hc : AppConsistent w) : w.outputs.Nodup :=
  List.Pairwise.of_map (·.ref) (fun _ _ hne heq => hne (congrArg (·.ref) heq)) hc.2.1

/-- An accepted update's successor world, from its inversion's witnesses, is
consistent. -/
theorem update_consistent_core (w : World) (hc : AppConsistent w) (o : AppOutput) (s : Successor)
    (hmem : o ∈ w.outputs) (haddr : s.address = appAddress w.app)
    (hctrl : s.envelope.control = o.envelope.control) (hassets : s.assets = o.assets)
    (hdep : o.envelope.control.deposit ≤ s.lovelace) :
    AppConsistent { w with outputs := (w.outputs.erase o) ++
        [⟨w.nextRef, s.address, s.lovelace, s.assets, s.envelope⟩], nextRef := w.nextRef + 1 } := by
  have hnd := outputs_nodup w hc
  obtain ⟨h1, h2, h3, h4, h5⟩ := hc
  have hnot : o ∉ w.outputs.erase o := by
    first
      | exact hnd.not_mem_erase
      | exact List.Nodup.not_mem_erase hnd
  have hold : ∀ q, q ∈ w.outputs.erase o → q ∈ w.outputs ∧ q ≠ o := by
    intro q hq
    refine ⟨List.mem_of_mem_erase hq, ?_⟩
    rintro rfl
    exact hnot hq
  have hkey : s.envelope.control.key = o.envelope.control.key := congrArg Control.key hctrl
  obtain ⟨_, o2, o3, _, o5, _⟩ := h3 o hmem
  refine ⟨h1, ?_, ?_, ?_, h5⟩
  · dsimp only
    rw [List.map_append]
    refine List.nodup_append.2 ⟨?_, ?_, ?_⟩
    · exact List.Nodup.sublist (List.erase_sublist.map _) h2
    · simp
    · intro a ha b hb hab
      obtain ⟨q, hq, hqa⟩ := List.mem_map.1 ha
      have hb' : b = w.nextRef := by simpa using hb
      have hlt : q.ref < w.nextRef := (h3 q (hold q hq).1).2.2.2.2.2
      have hqa' : q.ref = a := hqa
      omega
  · intro q hq
    rcases List.mem_append.1 hq with hq | hq
    · obtain ⟨g1, g2, g3, g4, g5, g6⟩ := h3 q (hold q hq).1
      exact ⟨g1, g2, g3, g4, g5, Nat.lt_succ_of_lt g6⟩
    · have hq' := List.mem_singleton.1 hq
      subst hq'
      refine ⟨haddr, ?_, ?_, ?_, ?_, Nat.lt_succ_self _⟩
      · show s.assets = [((.active, s.envelope.control.key), 1)]
        rw [hassets, hctrl]
        exact o2
      · show s.envelope.control.registry = w.registryAsset
        rw [hctrl]
        exact o3
      · show s.envelope.control.deposit ≤ s.lovelace
        rw [hctrl]
        exact hdep
      · show trieGet w.registry.trie s.envelope.control.key = .known .active
        rw [hctrl]
        exact o5
  · intro q1 hq1 q2 hq2 hkr
    have old_next : ∀ q, q ∈ w.outputs.erase o →
        (q.envelope.control.key = s.envelope.control.key ∨ q.ref = w.nextRef) → False := by
      intro q hq hqr
      rcases hqr with hk | hr
      · exact (hold q hq).2 (h4 q (hold q hq).1 o hmem (Or.inl (hk.trans hkey)))
      · have hlt : q.ref < w.nextRef := (h3 q (hold q hq).1).2.2.2.2.2
        omega
    rcases List.mem_append.1 hq1 with hq1 | hq1 <;>
      rcases List.mem_append.1 hq2 with hq2 | hq2
    · exact h4 q1 (hold q1 hq1).1 q2 (hold q2 hq2).1 hkr
    · have hq2' := List.mem_singleton.1 hq2
      subst hq2'
      exact (old_next q1 hq1 hkr).elim
    · have hq1' := List.mem_singleton.1 hq1
      subst hq1'
      exact (old_next q2 hq2 (hkr.imp Eq.symm Eq.symm)).elim
    · rw [List.mem_singleton.1 hq1, List.mem_singleton.1 hq2]

/-- An accepted fold's successor world, from its inversion's witnesses, is
consistent. -/
theorem fold_consistent_core (w : World) (hc : AppConsistent w) (sel : List (Edge × Key))
    (rows : List FoldRow) (t : Result)
    (hrows : sel.mapM (selectRow Law.standard w) = .ok rows)
    (ht : foldBatch w.registry (rows.map (·.pending.request)) = .ok t) :
    AppConsistent { w with registry := t.state
                         , outputs := (w.outputs.filter fun o => !(rows.filterMap (·.spent)).contains o) ++
                             createdOutputs w.app w.nextRef rows
                         , pending := w.pending.filter fun p => !(rows.map (·.pending)).contains p
                         , nextRef := w.nextRef + (createdOutputs w.app w.nextRef rows).length
                         , lastMint := t.mint } := by
  obtain ⟨hkept, _, hfresh, hkeys, hcons, _⟩ := fold_shape w hc sel rows t hrows ht
  obtain ⟨_, h2, h3, h4, h5⟩ := hc
  have hkm : ∀ q, q ∈ w.outputs.filter (fun o => !(rows.filterMap (·.spent)).contains o) →
      q ∈ w.outputs ∧ (rows.filterMap (·.spent)).contains q = false := by
    intro q hq
    obtain ⟨hm, hn⟩ := List.mem_filter.1 hq
    exact ⟨hm, by simpa using hn⟩
  have hfb := createdOutputs_ref_bounds w.app w.nextRef rows
  refine ⟨hcons, ?_, ?_, ?_, ?_⟩
  · dsimp only
    rw [List.map_append]
    refine List.nodup_append.2 ⟨?_, createdOutputs_refs_nodup _ _ _, ?_⟩
    · exact List.Nodup.sublist (List.filter_sublist.map _) h2
    · intro a ha b hb hab
      obtain ⟨q, hq, rfl⟩ := List.mem_map.1 ha
      obtain ⟨q', hq', rfl⟩ := List.mem_map.1 hb
      have hlt : q.ref < w.nextRef := (h3 q (hkm q hq).1).2.2.2.2.2
      have hge := (hfb q' hq').1
      omega
  · intro q hq
    rcases List.mem_append.1 hq with hq | hq
    · obtain ⟨hm, hn⟩ := hkm q hq
      obtain ⟨g1, g2, g3, g4, _, g6⟩ := h3 q hm
      exact ⟨g1, g2, g3, g4, hkept q hm hn, by dsimp only; omega⟩
    · obtain ⟨_, hact, haddr, hassets, hreg, hdep⟩ := hfresh q hq
      exact ⟨haddr, hassets, hreg, hdep, hact, (hfb q hq).2⟩
  · intro q1 hq1 q2 hq2 hkr
    have cross : ∀ a b, a ∈ w.outputs.filter (fun o => !(rows.filterMap (·.spent)).contains o) →
        b ∈ createdOutputs w.app w.nextRef rows →
        (a.envelope.control.key = b.envelope.control.key ∨ a.ref = b.ref) → False := by
      intro a b ha hb hab
      have hma := (hkm a ha).1
      rcases hab with hk | hr
      · have hact := (h3 a hma).2.2.2.2.1
        have hunk := (hfresh b hb).1
        rw [hk, hunk] at hact
        exact absurd hact (by decide)
      · have hlt : a.ref < w.nextRef := (h3 a hma).2.2.2.2.2
        have hge := (hfb b hb).1
        omega
    rcases List.mem_append.1 hq1 with hq1 | hq1 <;>
      rcases List.mem_append.1 hq2 with hq2 | hq2
    · exact h4 q1 (hkm q1 hq1).1 q2 (hkm q2 hq2).1 hkr
    · exact (cross q1 q2 hq1 hq2 hkr).elim
    · exact (cross q2 q1 hq2 hq1 (hkr.imp Eq.symm Eq.symm)).elim
    · rcases hkr with hk | hr
      · exact nodup_map_inj _ hkeys q1 hq1 q2 hq2 hk
      · exact nodup_map_inj _ (createdOutputs_refs_nodup _ _ _) q1 hq1 q2 hq2 hr
  · intro p hp
    exact h5 p (List.mem_filter.1 hp).1

/-- The mint of a sequential fold agrees at every asset with the batch's actual
mint. -/
theorem foldActions_mint : ∀ (batch : List Request) (s : RegistryState) (t : Result),
    foldActions s batch = .ok t → ∀ x, assetKind t.mint x = assetKind (actualMint batch) x
  | [], s, t, h, x => by
    rw [foldActions_nil_ok s t h]
    rfl
  | b :: bs, s, t, h, x => by
    obtain ⟨m, r, hs, hr, rfl⟩ := foldActions_cons_ok s b bs t h
    obtain ⟨_, hm⟩ := step_eq_ok s b m hs
    subst hm
    simp only [combineResults]
    rw [assetKind_assetPlus, assetKind_actualMint_cons, foldActions_mint bs _ r hr x]
    rfl

/-- A booked insertion is refused `key-exists` at a key that is Active or
Terminal, when the registry pins this application's policy. -/
theorem booked_insert_refusal (s : RegistryState) (app : App) (r : Request) (sigs : List Nat)
    (hedge : r.edge = .insertActive) (hpol : s.config.applicationPolicy = app.policy)
    (hleaf : trieGet s.trie r.key = .known .active ∨ trieGet s.trie r.key = .known .terminal) :
    refusal s (booked app r sigs) = some "key-exists" := by
  rcases hleaf with hleaf | hleaf <;>
    simp [refusal, booked, mintApproval, admitsFor, requestDestination, hedge, hpol, hleaf]


/-! ## The executable consistency observation -/

theorem byteArray_toList_loop (arr : Array UInt8) : ∀ (i : Nat) (r : List UInt8), i ≤ arr.size →
    ByteArray.toList.loop ⟨arr⟩ i r = r.reverse ++ arr.toList.drop i := by
  intro i
  induction h : arr.size - i generalizing i with
  | zero =>
    intro r hi
    have hi' : i = arr.size := by omega
    subst hi'
    unfold ByteArray.toList.loop
    split
    · rename_i hc
      exact absurd hc (Nat.lt_irrefl _)
    · rw [List.drop_of_length_le (by simp), List.append_nil]
  | succ n ih =>
    intro r hi
    have hlt : i < arr.size := by omega
    unfold ByteArray.toList.loop
    split
    · rw [ih (i + 1) (by omega) _ (by omega)]
      have hget : ByteArray.get! ⟨arr⟩ i = arr.toList[i]'(by simpa using hlt) := by
        show arr[i]! = _
        rw [getElem!_pos arr i hlt]
        simp
      rw [hget, List.reverse_cons, List.append_assoc, List.singleton_append,
        ← List.drop_eq_getElem_cons (by simpa using hlt)]
    · rename_i hc
      exact absurd hlt hc

theorem byteArray_toList (bs : ByteArray) : bs.toList = bs.data.toList := by
  cases bs with
  | mk arr =>
    unfold ByteArray.toList
    rw [byteArray_toList_loop arr 0 [] (Nat.zero_le _)]
    simp

theorem byteArray_eq_of_toList (a b : ByteArray) (h : a.toList = b.toList) : a = b := by
  rw [byteArray_toList, byteArray_toList] at h
  cases a
  cases b
  simp only at h
  rw [Array.toList_inj.1 h]

/-- Membership in a first-occurrence deduplicating fold. -/
theorem mem_foldl_dedup (k : Key) : ∀ (l acc : List Key),
    k ∈ l.foldl (fun acc x => if acc.contains x then acc else acc ++ [x]) acc ↔ k ∈ acc ∨ k ∈ l
  | [], acc => by simp
  | x :: xs, acc => by
    rw [List.foldl_cons, mem_foldl_dedup k xs]
    by_cases hx : acc.contains x = true
    · rw [if_pos hx]
      have hxm : x ∈ acc := List.contains_iff_mem.1 hx
      constructor
      · rintro (h | h)
        · exact Or.inl h
        · exact Or.inr (List.mem_cons_of_mem _ h)
      · rintro (h | h)
        · exact Or.inl h
        · rcases List.mem_cons.1 h with rfl | h
          · exact Or.inl hxm
          · exact Or.inr h
    · rw [if_neg hx]
      simp only [List.mem_append, List.mem_cons, List.not_mem_nil, or_false]
      constructor
      · rintro ((h | h) | h)
        · exact Or.inl h
        · exact Or.inr (Or.inl h)
        · exact Or.inr (Or.inr h)
      · rintro (h | h | h)
        · exact Or.inl (Or.inl h)
        · exact Or.inl (Or.inr h)
        · exact Or.inr h

theorem mem_stateKeys (s : RegistryState) (k : Key) :
    k ∈ Singular.Driver.stateKeys s ↔
      k ∈ s.trie.map (·.1) ∨ k ∈ s.custody.map (·.key) ∨ k ∈ s.held.map (·.key) := by
  unfold Singular.Driver.stateKeys
  rw [mem_foldl_dedup]
  simp only [List.not_mem_nil, false_or, List.mem_append, or_assoc]

theorem trieGet_of_not_mem (t : Trie) (k : Key) (h : k ∉ t.map (·.1)) : trieGet t k = .unknown := by
  have : t.filter (·.1 == k) = [] := by
    rw [List.filter_eq_nil_iff]
    intro p hp hpk
    exact h (List.mem_map.2 ⟨p, hp, by simpa using hpk⟩)
  simp [trieGet, this]

theorem kindCount_of_not_mem (s : RegistryState) (kk : TokenKind) (k : Key)
    (h : k ∉ s.held.map (·.key)) : kindCount s kk k = 0 := by
  unfold kindCount
  rw [List.length_eq_zero_iff, List.filter_eq_nil_iff]
  intro x hx hxk
  simp only [Bool.and_eq_true, beq_iff_eq] at hxk
  exact h (List.mem_map.2 ⟨x, hx, hxk.1⟩)

theorem custodyCount_of_not_mem (s : RegistryState) (k : Key)
    (h : k ∉ s.custody.map (·.key)) : custodyCount s k = 0 := by
  unfold custodyCount
  rw [List.length_eq_zero_iff, List.filter_eq_nil_iff]
  intro x hx hxk
  exact h (List.mem_map.2 ⟨x, hx, by simpa using hxk⟩)

theorem two_le_length_of_ne {α : Type} [DecidableEq α] (l : List α) (a b : α) (ha : a ∈ l)
    (hb : b ∈ l) (hab : a ≠ b) : 2 ≤ l.length := by
  have hsub : [a, b].Sublist l ∨ [b, a].Sublist l := by
    induction l with
    | nil => simp at ha
    | cons x xs ih =>
      rcases List.mem_cons.1 ha with rfl | ha' <;> rcases List.mem_cons.1 hb with rfl | hb'
      · exact absurd rfl hab
      · exact Or.inl (List.Sublist.cons₂ _ (List.singleton_sublist.2 hb'))
      · exact Or.inr (List.Sublist.cons₂ _ (List.singleton_sublist.2 ha'))
      · rcases ih ha' hb' with h | h
        · exact Or.inl (List.Sublist.cons _ h)
        · exact Or.inr (List.Sublist.cons _ h)
  rcases hsub with h | h <;> simpa using h.length_le

theorem bool_iff_beq (a b : Bool) : (a == b) = true ↔ (a = true ↔ b = true) := by
  cases a <;> cases b <;> simp

/-- The root driver's executable consistency observation is exactly
`Singular.Consistent`. -/
theorem consistentB_iff (s : RegistryState) :
    Singular.Driver.consistentB s = true ↔ Consistent s := by
  unfold Singular.Driver.consistentB
  simp only [Bool.and_eq_true, List.all_eq_true]
  constructor
  · rintro ⟨⟨⟨hroot, hkeys⟩, hheld⟩, hcust⟩
    have hk : ∀ k, (kindCount s .active k = 1 ↔ trieGet s.trie k = .known .active) ∧
        kindCount s .active k ≤ 1 ∧
        (custodyCount s k = 1 ↔ trieGet s.trie k = .known .absent) ∧ custodyCount s k ≤ 1 := by
      intro k
      by_cases hm : k ∈ Singular.Driver.stateKeys s
      · have := hkeys k hm
        simp only [decide_eq_true_eq] at this
        obtain ⟨⟨⟨h1, h2⟩, h3⟩, h4⟩ := this
        rw [bool_iff_beq] at h1 h3
        simp only [beq_iff_eq] at h1 h3
        exact ⟨h1, h2, h3, h4⟩
      · rw [mem_stateKeys] at hm
        simp only [not_or] at hm
        obtain ⟨ht, hc, hh⟩ := hm
        rw [kindCount_of_not_mem s _ k hh, custodyCount_of_not_mem s k hc, trieGet_of_not_mem _ k ht]
        simp
    refine ⟨byteArray_eq_of_toList _ _ (by simpa using hroot), fun k => (hk k).1, fun k => (hk k).2.1,
      fun k => (hk k).2.2.1, fun k => (hk k).2.2.2, ?_, ?_, ?_⟩
    · intro h hh hkind
      have := hheld h hh
      simp only [Bool.or_eq_true, Bool.not_eq_true', beq_iff_eq, beq_eq_false_iff_ne] at this
      rcases this with h1 | h1
      · exact absurd hkind h1
      · exact h1
    · intro c hc
      simpa using hcust c hc
    · intro c₁ h1 c₂ h2 hkey
      by_cases hne : c₁ = c₂
      · exact hne
      exfalso
      have hle := (hk c₁.key).2.2.2
      have hm1 : c₁ ∈ s.custody.filter (·.key == c₁.key) := List.mem_filter.2 ⟨h1, by simp⟩
      have hm2 : c₂ ∈ s.custody.filter (·.key == c₁.key) := List.mem_filter.2 ⟨h2, by simp [hkey]⟩
      have := two_le_length_of_ne _ _ _ hm1 hm2 hne
      unfold custodyCount at hle
      omega
  · rintro ⟨hroot, hA1, hA2, hC1, hC2, hTerm, hCleaf, _⟩
    refine ⟨⟨⟨by rw [hroot]; simp, ?_⟩, ?_⟩, ?_⟩
    · intro k _
      simp only [decide_eq_true_eq]
      exact ⟨⟨⟨(bool_iff_beq _ _).2 (by simp only [beq_iff_eq]; exact hA1 k), hA2 k⟩,
        (bool_iff_beq _ _).2 (by simp only [beq_iff_eq]; exact hC1 k)⟩, hC2 k⟩
    · intro h hh
      simp only [Bool.or_eq_true, Bool.not_eq_true', beq_iff_eq, beq_eq_false_iff_ne]
      by_cases hkind : h.kind = .terminal
      · exact Or.inr (hTerm h hh hkind)
      · exact Or.inl hkind
    · intro c hc
      simpa using hCleaf c hc

/-- The occurrence observation: no reference repeats. -/
theorem eraseDups_length_le {α} [BEq α] [LawfulBEq α] : ∀ l : List α,
    l.eraseDups.length ≤ l.length
  | [] => by simp
  | a :: as => by
    have ih := eraseDups_length_le (as.filter fun b => !b == a)
    have hf := List.length_filter_le (fun b => !b == a) as
    rw [List.eraseDups_cons]
    simp only [List.length_cons]
    omega
termination_by l => l.length
decreasing_by
  all_goals
    have := List.length_filter_le (fun b => !b == a) as
    simp only [List.length_cons]
    omega

theorem eraseDups_length_iff {α} [BEq α] [LawfulBEq α] : ∀ l : List α,
    l.eraseDups.length = l.length ↔ l.Nodup
  | [] => by simp
  | a :: as => by
    have ih := eraseDups_length_iff (as.filter fun b => !b == a)
    have hle := eraseDups_length_le (as.filter fun b => !b == a)
    have hf := List.length_filter_le (fun b => !b == a) as
    rw [List.eraseDups_cons, List.length_cons, List.length_cons, List.nodup_cons]
    constructor
    · intro h
      have hfl : (as.filter fun b => !b == a).length = as.length := by omega
      have hall : as.filter (fun b => !b == a) = as := List.filter_eq_self.2 (by
        intro x hx
        by_cases hne : (!x == a) = true
        · exact hne
        exfalso
        have : (as.filter fun b => !b == a).length < as.length :=
          List.length_filter_lt_length_iff_exists.2 ⟨x, hx, hne⟩
        omega)
      have hna : a ∉ as := by
        intro ha
        have := List.mem_filter.1 (hall ▸ ha)
        simp at this
      refine ⟨hna, ?_⟩
      rw [← hall]
      exact ih.1 (by omega)
    · rintro ⟨hna, hnd⟩
      have hall : as.filter (fun b => !b == a) = as := List.filter_eq_self.2 (by
        intro x hx
        have : x ≠ a := fun h => hna (h ▸ hx)
        simpa using this)
      have := ih.2 (by rw [hall]; exact hnd)
      rw [hall] at this ⊢
      omega
termination_by l => l.length
decreasing_by
  all_goals
    have := List.length_filter_le (fun b => !b == a) as
    simp only [List.length_cons]
    omega


/-! ## Holdings through a fold -/

/-- A holding survives one accepted step of an insertion, or of a termination
of another key. -/
theorem step_keeps_holding (s : RegistryState) (a : Request) (r : Result) (h : step s a = .ok r)
    (he : a.edge = .insertActive ∨ a.edge = .updateTerminal) (x : Holding) (hx : x ∈ s.held)
    (hk : a.edge = .updateTerminal → a.key ≠ x.key) : x ∈ r.state.held := by
  obtain ⟨_, hr⟩ := step_eq_ok s a r h
  subst hr
  rcases he with he | he
  · obtain ⟨_, _, _, hheld, _, _⟩ := applyEdge_insertActive s a he
    rw [hheld]
    exact List.mem_cons_of_mem _ hx
  · obtain ⟨_, _, _, hheld, _, _⟩ := applyEdge_updateTerminal s a he
    rw [hheld]
    refine List.mem_filter.2 ⟨hx, ?_⟩
    have hne : (x.key == a.key) = false := by simpa using (hk he).symm
    simp [hne]

/-- A holding survives a whole fold of insertions and of terminations of other
keys. -/
theorem foldActions_keeps_holding (x : Holding) : ∀ (batch : List Request) (s : RegistryState)
    (t : Result), foldActions s batch = .ok t →
    (∀ b ∈ batch, b.edge = .insertActive ∨ b.edge = .updateTerminal) →
    (∀ b ∈ batch, b.edge = .updateTerminal → b.key ≠ x.key) →
    x ∈ s.held → x ∈ t.state.held
  | [], s, t, h, _, _, hx => by
    rw [foldActions_nil_ok s t h]
    exact hx
  | b :: bs, s, t, h, hE, hT, hx => by
    obtain ⟨m, r, hs, hr, rfl⟩ := foldActions_cons_ok s b bs t h
    have hm := step_keeps_holding s b m hs (hE b (List.mem_cons_self ..)) x hx
      (hT b (List.mem_cons_self ..))
    exact foldActions_keeps_holding x bs m.state r hr
      (fun c hc => hE c (List.mem_cons_of_mem _ hc)) (fun c hc => hT c (List.mem_cons_of_mem _ hc)) hm

/-- Every insertion of a fold that terminates no request of its key leaves an
active holding of that key carrying the datum form the insertion delivered. -/
theorem foldActions_insert_holding : ∀ (batch : List Request) (s : RegistryState) (t : Result),
    foldActions s batch = .ok t →
    (∀ b ∈ batch, b.edge = .insertActive ∨ b.edge = .updateTerminal) →
    ∀ b ∈ batch, b.edge = .insertActive →
      (∀ c ∈ batch, c.edge = .updateTerminal → c.key ≠ b.key) →
      ∃ x ∈ t.state.held, x.key = b.key ∧ x.kind = .active ∧ x.datum = b.datum
  | [], _, _, _, _, b, hb, _, _ => absurd hb (List.not_mem_nil)
  | b0 :: bs, s, t, h, hE, b, hb, hins, hT => by
    obtain ⟨m, r, hs, hr, rfl⟩ := foldActions_cons_ok s b0 bs t h
    have hEbs : ∀ c ∈ bs, c.edge = .insertActive ∨ c.edge = .updateTerminal :=
      fun c hc => hE c (List.mem_cons_of_mem _ hc)
    rcases List.mem_cons.1 hb with rfl | hb'
    · obtain ⟨_, hm⟩ := step_eq_ok s b m hs
      have hheld := (applyEdge_insertActive s b hins).2.2.2.1
      let x : Holding := { key := b.key, kind := .active, output := b.output, datum := b.datum }
      have hxm : x ∈ m.state.held := by
        rw [hm, hheld]
        exact List.mem_cons_self ..
      refine ⟨x, ?_, rfl, rfl, rfl⟩
      exact foldActions_keeps_holding x bs m.state r hr hEbs
        (fun c hc => hT c (List.mem_cons_of_mem _ hc)) hxm
    · exact foldActions_insert_holding bs m.state r hr hEbs b hb' hins
        (fun c hc => hT c (List.mem_cons_of_mem _ hc))

end OpenDatumApplication.ProofSupport
