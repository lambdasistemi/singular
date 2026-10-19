import OpenDatumApplication.Model
import OpenDatumApplication.Driver
import Singular.Lemmas
import Singular.Statements.Termination
import Singular.Statements.FoldAccounting
import Singular.Lemmas.FoldWitnessObservation

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


/-! ## Exact application admission plumbing -/
theorem bind_eq_ok_iff {α β : Type} (x : Except String α) (f : α → Except String β) (b : β) :
    (x >>= f) = .ok b ↔ ∃ a, x = .ok a ∧ f a = .ok b := by
  cases x <;> simp [bind, Except.bind]

theorem ensure_bind_eq_ok_iff {α : Type} (condition : Bool) (why : String)
    (f : Unit → Except String α) (a : α) :
    (ensure condition why >>= f) = .ok a ↔ condition = true ∧ f () = .ok a := by
  cases condition <;> simp [ensure, bind, Except.bind]

theorem application_timing_none (world : Singular.World) (tx : EconomicTransaction) :
    applicationFoldTimingRefusal world tx = none := by
  unfold applicationFoldTimingRefusal
  cases hv : tx.transaction.validity with
  | none => rfl
  | some interval =>
    generalize foldMembers world tx = members
    induction members with
    | nil => rfl
    | cons member rest ih =>
      cases member <;> simp_all [List.findSome?, terminationFoldTiming, foldMemberRefusal]

theorem fold_decision_eq_root (world : Singular.World) (u : EconomicUtxo) (tx : EconomicTransaction) :
    applicationFoldDecision world u tx = Singular.foldAccepted world u tx := by
  unfold applicationFoldDecision
  rw [application_timing_none]
  cases Singular.foldAccepted world u tx <;> rfl


theorem ensure_eq_ok_iff (condition : Bool) (why : String) (u : Unit) :
    ensure condition why = .ok u ↔ condition = true := by
  cases condition <;> cases u <;> simp [ensure]

instance holdingLawfulBEq : LawfulBEq Holding where
  eq_of_beq {a b} h := by
    cases a; cases b
    simpa only [reduceBEq, Bool.and_eq_true, beq_iff_eq, Holding.mk.injEq] using h
  rfl {a} := by
    cases a
    simp only [reduceBEq, beq_self_eq_true, Bool.and_self]

theorem book_checks {before after : Singular.World} {b : RegistrationBooking}
    (h : Singular.book before b = .ok after) :
    registrationBookingRefusal before.registry.config b = none ∧
      after = { before with pending := b :: before.pending } := by
  unfold Singular.book at h
  split at h
  next reason => contradiction
  next admitted =>
    split at h
    next duplicate => contradiction
    next fresh => cases h; exact ⟨admitted, rfl⟩

theorem bookTermination_checks {before after : Singular.World} {b : TerminationBooking}
    (h : Singular.bookTermination before b = .ok after) :
    terminationBookingRefusal before.registry b = none ∧
      after = { before with
        registry := { before.registry with held := before.registry.held.filter (fun h => !(h.key == b.request.key && h.kind == .active)) }
        terminations := b :: before.terminations } := by
  unfold Singular.bookTermination at h
  split at h
  next reason => contradiction
  next admitted =>
    split at h
    next duplicate => contradiction
    next fresh => cases h; exact ⟨admitted, rfl⟩

/-! Exact transition descriptions for preservation and projection proofs. -/
theorem bookInsert_inversion (w w' : World) (b : RegistrationBooking) (e : Envelope) (sigs : List Nat) :
    bookInsertStep Law.standard w b e sigs = .ok w' ↔
      w.registry.config.applicationPolicy = w.app.policy ∧ w.app.registry = w.registryAsset ∧
      e.control.registry = w.registryAsset ∧
      w.registryAsset.policy = w.registry.config.stateToken.policy ∧
      w.registryAsset.assetName = w.registry.config.stateToken.name ∧ e.control.version = envelopeVersion ∧
      e.control.activePolicy = w.registry.config.activePolicy ∧ e.control.key = b.request.key ∧
      e.control.controller = b.request.refundAddress ∧ e.control.controller ∈ sigs ∧
      b.request.destination = destinationOf w.app e ∧ b.request.datum = some (envelopeHash e) ∧
      e.control.deposit = b.request.carrierAda ∧
      ∃ economic, Singular.book w.economic b = .ok economic ∧
        w' = { w with economic, pending := ⟨b.request.reference, e⟩ :: w.pending } := by
  unfold bookInsertStep
  simp only [ProofSupport.bind_eq_ok_iff, ProofSupport.ensure_eq_ok_iff]
  simp [Law.standard, insertionBinding, registryAssetMatches, pure, Except.pure]
  simp only [and_assoc]
  constructor
  · rintro ⟨a,b,c,d,e,f,g,h,i,j,k,l,m,n,root,effect⟩
    exact ⟨a,b,c,d,e,f,g,h,i,m,j,k,l,n,root,effect.symm⟩
  · rintro ⟨a,b,c,d,e,f,g,h,i,m,j,k,l,n,root,effect⟩
    exact ⟨a,b,c,d,e,f,g,h,i,j,k,l,m,n,root,effect.symm⟩

theorem bookTerminate_inversion (w w' : World) (b : TerminationBooking) (ref added : Nat) (sigs : List Nat) :
    bookTerminateStep Law.standard w b ref added sigs = .ok w' ↔
      ∃ o economic, outputAt w ref = some o ∧
        w.registry.config.applicationPolicy = w.app.policy ∧
        w.registryAsset.policy = w.registry.config.stateToken.policy ∧
        w.registryAsset.assetName = w.registry.config.stateToken.name ∧ o.address = appAddress w.app ∧
        o.assets = [((.active, b.request.key), 1)] ∧ o.envelope.control.key = b.request.key ∧
        o.envelope.control.registry = w.registryAsset ∧
        o.envelope.control.activePolicy = w.registry.config.activePolicy ∧
        o.envelope.control = o.registered.control ∧ o.envelope.control.controller ∈ sigs ∧
        b.request.destination = 0 ∧ b.custodyInputs = [rootHolding w o] ∧
        b.request.contents.lovelace = o.lovelace + added ∧
        Singular.bookTermination w.economic b = .ok economic ∧
        w' = { w with economic, outputs := w.outputs.erase o } := by
  cases ho : outputAt w ref with
  | none => simp [bookTerminateStep, ho]
  | some o =>
    simp only [bookTerminateStep, ho]
    simp only [ProofSupport.bind_eq_ok_iff, ProofSupport.ensure_eq_ok_iff]
    simp [ho, Law.standard, registryAssetMatches, pure, Except.pure]
    simp only [and_assoc]
    intro pinned
    constructor
    · rintro ⟨a,b,c,d,e,f,g,h,i,j,k,l,next,root,effect⟩
      exact ⟨a,b,c,d,e,f,g,h,i,j,k,l,next,root,effect.symm⟩
    · rintro ⟨a,b,c,d,e,f,g,h,i,j,k,l,next,root,effect⟩
      exact ⟨a,b,c,d,e,f,g,h,i,j,k,l,next,root,effect.symm⟩

theorem update_inversion (w w' : World) (ref : Nat) (ss : List Successor) (sigs : List Nat) :
    updateStep Law.standard w ref ss sigs = .ok w' ↔
      ∃ o s, outputAt w ref = some o ∧ o.envelope.control.controller ∈ sigs ∧
        ss.filter (fun x => carriesKey x.assets o.envelope.control.key) = [s] ∧
        s.address = appAddress w.app ∧ s.envelope.control = o.envelope.control ∧ s.assets = o.assets ∧
        o.envelope.control.deposit ≤ s.lovelace ∧
        w' = { w with outputs := w.outputs.erase o ++ [{ ref := w.nextRef, address := s.address,           lovelace := s.lovelace, assets := s.assets, envelope := s.envelope, registered := o.registered }],           nextRef := w.nextRef + 1 } := by
  cases ho : outputAt w ref with
  | none => simp [updateStep, ho]
  | some o =>
    cases hc : ss.filter (fun x => carriesKey x.assets o.envelope.control.key) with
    | nil => simp only [updateStep, ho, hc, ProofSupport.bind_eq_ok_iff, ProofSupport.ensure_eq_ok_iff]; simp [ho, hc]
    | cons s rest =>
      cases rest with
      | nil =>
        simp only [updateStep, ho, hc]
        simp only [ProofSupport.bind_eq_ok_iff, ProofSupport.ensure_eq_ok_iff]
        simp [ho, hc, Law.standard, pure, Except.pure]
        intros
        exact eq_comm
      | cons t rest => simp only [updateStep, ho, hc, ProofSupport.bind_eq_ok_iff, ProofSupport.ensure_eq_ok_iff]; simp [ho, hc]

theorem fold_inversion (w w' : World) (u : EconomicUtxo) (tx : EconomicTransaction) :
    foldEffect Law.standard w u tx = .ok w' ↔
      ∃ rows economic, (selectedReferences w tx).mapM (selectRow Law.standard w) = .ok rows ∧
        Singular.foldAccepted w.economic u tx = .ok economic ∧
        applicationFoldTimingRefusal w.economic tx = none ∧
        w' = { w with economic, outputs := w.outputs ++ createdOutputs w.app w.nextRef rows,           pending := w.pending.filter (fun p => !inputsContainReference tx.transaction.inputs p.reference),           nextRef := w.nextRef + (createdOutputs w.app w.nextRef rows).length } := by
  unfold foldEffect
  simp only [ProofSupport.ensure_bind_eq_ok_iff, ProofSupport.bind_eq_ok_iff]
  simp [foldEffect, ProofSupport.bind_eq_ok_iff, ProofSupport.fold_decision_eq_root, ProofSupport.application_timing_none, pure, Except.pure, eq_comm]

theorem reject_inversion (w w' : World) (u : EconomicUtxo) (r : Rejection) :
    rejectStep w u r = .ok w' ↔
      ∃ economic, rejectionAccepted w.economic u r = .ok economic ∧
        w' = { w with economic, pending := w.pending.filter fun p => !(r.members.any fun m => m.1 == p.reference) } := by
  unfold rejectStep
  simp only [ProofSupport.ensure_bind_eq_ok_iff, ProofSupport.bind_eq_ok_iff]
  simp [rejectStep, applicationRejectionDecision, ProofSupport.bind_eq_ok_iff, pure, Except.pure, eq_comm]


theorem root_reachable (w : World) (reached : Reachable w) : Singular.WorldReachable w.economic := by
  induction reached with
  | initial app c asset => exact Singular.WorldReachable.initial _ (Singular.Reachable.initial c)
  | @next w w' a reached accepted ih =>
    cases a with
    | bookInsert b e sigs =>
      obtain ⟨_,_,_,_,_,_,_,_,_,_,_,_,_,economic,root,effect⟩ := (bookInsert_inversion w w' b e sigs).mp accepted
      subst w'
      exact Singular.WorldReachable.booking ih b root
    | bookTerminate b ref added sigs =>
      obtain ⟨o,economic,_,_,_,_,_,_,_,_,_,_,_,_,_,_,root,effect⟩ := (bookTerminate_inversion w w' b ref added sigs).mp accepted
      subst w'
      exact Singular.WorldReachable.termination ih b root
    | bookOther r sigs => cases accepted
    | update ref ss sigs =>
      obtain ⟨o,s,_,_,_,_,_,_,_,effect⟩ := (update_inversion w w' ref ss sigs).mp accepted
      subst w'
      exact ih
    | fold u tx =>
      obtain ⟨rows,economic,_,root,_,effect⟩ := (fold_inversion w w' u tx).mp accepted
      subst w'
      exact Singular.WorldReachable.fold ih u tx root
    | reject u r =>
      obtain ⟨economic,root,effect⟩ := (reject_inversion w w' u r).mp accepted
      subst w'
      exact Singular.WorldReachable.rejection ih u r root
    | withdraw ref outs =>
      change withdrawStep w ref outs = .ok w' at accepted
      unfold withdrawStep at accepted
      cases ho : outputAt w ref <;> simp [ho] at accepted

theorem registration_admitted {c : Config} {b : RegistrationBooking}
    (admitted : registrationBookingRefusal c b = none) :
    exactContents c b.request = true ∧
      b.applicationTagsMinted = b.request.contents.applicationTags := by
  simp only [registrationBookingRefusal] at admitted
  split at admitted
  next dirty => contradiction
  next shape =>
    split at admitted
    next surplus => contradiction
    next value =>
      split at admitted
      next forged => contradiction
      next tags =>
        split at admitted
        next missing => contradiction
        next application =>
          have shape' : registrationContentsShape c b.request = true ∧
              registrationDeclaredLovelace b.request ≤ b.request.contents.lovelace := by simpa using shape
          have tags' : b.request.contents.trieReadyTags = [b.request.trieReadyTag c] ∧
              b.trieReadyTagsMinted = [b.request.trieReadyTag c] := by simpa using tags
          have application' : b.applicationTagsMinted = b.request.contents.applicationTags := by simpa using application
          have amount : b.request.contents.lovelace = registrationDeclaredLovelace b.request := by omega
          exact ⟨by simp [exactContents, shape'.1, amount, tags'.1], application'⟩

theorem folded_registration_was_unknown {w : World} {u : EconomicUtxo} {tx : EconomicTransaction}
    {after : Singular.World} {b : RegistrationBooking}
    (root : Singular.foldAccepted w.economic u tx = .ok after)
    (selected : FoldMember.registration b ∈ foldMembers w.economic tx) :
    trieGet w.registry.trie b.request.key = .unknown := by
  obtain ⟨_,result,registry,_,_⟩ := Singular.foldAccepted_checks root
  have edges : ∀ r ∈ (foldMembers w.economic tx).map (foldLegacyRequest w.registry.config),
      r.edge = .insertActive ∨ r.edge = .updateTerminal := by
    intro r hr
    obtain ⟨member,hm,rfl⟩ := List.mem_map.mp hr
    cases member <;> simp [foldLegacyRequest]
  have present : Edge.insertActive ∈
      (((foldMembers w.economic tx).map (foldLegacyRequest w.registry.config)).filter
        (fun r => r.key == b.request.key)).map (·.edge) := by
    apply List.mem_map.mpr
    refine ⟨foldLegacyRequest w.registry.config (.registration b), ?_, rfl⟩
    apply List.mem_filter.mpr
    exact ⟨List.mem_map.mpr ⟨.registration b,selected,rfl⟩,by simp [foldLegacyRequest]⟩
  unfold World.registry at present
  have cases := (foldActions_key b.request.key _ _ _ (Singular.foldBatch_inv _ _ _ registry).2 edges).2
  rcases cases with ⟨empty,_,_⟩ | ⟨one,unknown,_,_⟩ | ⟨one,_,_,_⟩ | ⟨two,unknown,_,_⟩
  · rw [empty] at present
    cases present
  · exact unknown
  · rw [one] at present
    simp at present
  · exact unknown

theorem book_reference_fresh {before after : Singular.World} {b : RegistrationBooking}
    (accepted : Singular.book before b = .ok after) :
    b.request.reference ∉ (before.pending.map (·.request.reference)) ++
      before.terminations.map (·.request.reference) := by
  unfold Singular.book at accepted
  split at accepted
  next reason => contradiction
  next admitted =>
    split at accepted
    next duplicate => contradiction
    next fresh =>
      simpa [List.any_eq_true, List.mem_map] using fresh

theorem insertion_consistent (w w' : World) (b : RegistrationBooking) (e : Envelope) (sigs : List Nat)
    (hc : AppConsistent w) (accepted : bookInsertStep Law.standard w b e sigs = .ok w') :
    AppConsistent w' := by
  obtain ⟨pin,app,reg,policy,name,version,active,key,controller,signer,dest,datum,deposit,economic,root,effect⟩ := (bookInsert_inversion w w' b e sigs).mp accepted
  have binding : insertionBinding Law.standard w b.request e = true := by
    simp [insertionBinding,Law.standard,registryAssetMatches,pin,app,reg,policy,name,version,active,key,controller,dest,datum,deposit]
  have fresh := book_reference_fresh root
  obtain ⟨admitted,economicEffect⟩ := book_checks root
  subst w'
  subst economic
  obtain ⟨consistent,distinct,outputs,unique,custody,metadataDistinct,requestsDistinct,metadata,back,registrations,terminations⟩ := hc
  refine ⟨consistent,distinct,outputs,unique,custody,?_,?_,?_,?_,?_,terminations⟩
  · apply List.nodup_cons.mpr
    refine ⟨?_,metadataDistinct⟩
    intro member
    obtain ⟨p,hp,same⟩ := List.mem_map.mp member
    obtain ⟨old,oldMem,oldRef,_⟩ := metadata p hp
    apply fresh
    exact List.mem_append_left _ (List.mem_map.mpr ⟨old,oldMem,oldRef.trans same⟩)
  · exact List.nodup_cons.mpr ⟨fresh,requestsDistinct⟩
  · intro p hp
    rcases List.mem_cons.mp hp with same | old
    · subst p
      exact ⟨b,List.mem_cons_self,rfl,binding⟩
    · obtain ⟨old,member,same,bind⟩ := metadata p old
      exact ⟨old,List.mem_cons_of_mem _ member,same,bind⟩
  · intro old member
    rcases List.mem_cons.mp member with same | oldMem
    · subst old
      exact ⟨⟨b.request.reference,e⟩,List.mem_cons_self,rfl⟩
    · obtain ⟨p,hp,same⟩ := back old oldMem
      exact ⟨p,List.mem_cons_of_mem _ hp,same⟩
  · intro old member
    rcases List.mem_cons.mp member with same | oldMem
    · subst old; exact admitted
    · exact registrations old oldMem

theorem rejection_consistent (w w' : World) (u : EconomicUtxo) (r : Rejection)
    (hc : AppConsistent w) (accepted : rejectStep w u r = .ok w') : AppConsistent w' := by
  obtain ⟨economic,root,effect⟩ := (reject_inversion w w' u r).mp accepted
  have economicEffect := Singular.rejectionAccepted_effect root
  subst w'
  subst economic
  obtain ⟨consistent,distinct,outputs,unique,custody,metadataDistinct,requestsDistinct,metadata,back,registrations,terminations⟩ := hc
  refine ⟨consistent,distinct,outputs,unique,custody,?_,?_,?_,?_,?_,terminations⟩
  · exact (List.filter_sublist.map (fun p : Pending => p.reference)).nodup metadataDistinct
  · exact ((List.filter_sublist.map (fun b : RegistrationBooking => b.request.reference)).append_right _).nodup requestsDistinct
  · intro p hp
    obtain ⟨old,oldMem,same,binding⟩ := metadata p (List.mem_filter.mp hp).1
    refine ⟨old,List.mem_filter.mpr ⟨oldMem,?_⟩,same,binding⟩
    simpa [same] using (List.mem_filter.mp hp).2
  · intro old oldMem
    obtain ⟨p,hp,same⟩ := back old (List.mem_filter.mp oldMem).1
    refine ⟨p,List.mem_filter.mpr ⟨hp,?_⟩,same⟩
    simpa [same] using (List.mem_filter.mp oldMem).2
  · intro old oldMem
    exact registrations old (List.mem_filter.mp oldMem).1

theorem update_consistent (w w' : World) (ref : Nat) (ss : List Successor) (sigs : List Nat)
    (hc : AppConsistent w) (accepted : updateStep Law.standard w ref ss sigs = .ok w') : AppConsistent w' := by
  obtain ⟨o,s,found,signer,card,address,control,assets,floor,effect⟩ := (update_inversion w w' ref ss sigs).mp accepted
  have oMem : o ∈ w.outputs := List.mem_of_find?_eq_some found
  obtain ⟨consistent,distinct,outputs,unique,custody,metadataDistinct,requestsDistinct,metadata,back,registrations,terminations⟩ := hc
  have oShape := outputs o oMem
  have outputNodup : w.outputs.Nodup :=
    List.Pairwise.of_map (·.ref) (fun a b h eq => h (congrArg AppOutput.ref eq)) distinct
  let next : AppOutput := ⟨w.nextRef,s.address,s.lovelace,s.assets,s.envelope,o.registered⟩
  have oldNotSame : ∀ x ∈ w.outputs.erase o,
      ¬(x.envelope.control.key = next.envelope.control.key ∨ x.ref = next.ref) := by
    intro x hx same
    rcases same with key | reference
    · have key' : x.envelope.control.key = o.envelope.control.key := by simpa [next,control] using key
      have eq := unique x (List.mem_of_mem_erase hx) o oMem (Or.inl key')
      subst x
      exact outputNodup.not_mem_erase hx
    · have bound := (outputs x (List.mem_of_mem_erase hx)).2.2.2.2.2
      change x.ref = w.nextRef at reference
      omega
  subst w'
  change AppConsistent {w with outputs := w.outputs.erase o ++ [next],nextRef := w.nextRef + 1}
  refine ⟨consistent,?_,?_,?_,?_,metadataDistinct,requestsDistinct,metadata,back,registrations,terminations⟩
  · rw [List.map_append]
    refine List.nodup_append.mpr ⟨(List.erase_sublist.map (fun x : AppOutput => x.ref)).nodup distinct,by simp,?_⟩
    intro a ha b hb eq
    obtain ⟨x,hx,rfl⟩ := List.mem_map.mp ha
    simp only [List.map_cons,List.map_nil,List.mem_singleton] at hb
    exact oldNotSame x hx (Or.inr (eq.trans hb))
  · intro x hx
    rcases List.mem_append.mp hx with old | fresh
    · have shape := outputs x (List.mem_of_mem_erase old)
      exact ⟨shape.1,shape.2.1,shape.2.2.1,shape.2.2.2.1,shape.2.2.2.2.1,by change x.ref < w.nextRef + 1; have := shape.2.2.2.2.2; omega⟩
    · have eq := List.mem_singleton.mp fresh
      subst x
      exact ⟨address,by simpa [next,assets,control] using oShape.2.1,
        control.trans oShape.2.2.1,by simpa [next,control] using oShape.2.2.2.1,
        by simpa [next,control] using floor,Nat.lt_succ_self _⟩
  · intro a ha b hb same
    rcases List.mem_append.mp ha with oldA | freshA <;>
      rcases List.mem_append.mp hb with oldB | freshB
    · exact unique a (List.mem_of_mem_erase oldA) b (List.mem_of_mem_erase oldB) same
    · have eq := List.mem_singleton.mp freshB
      subst b
      exact False.elim (oldNotSame a oldA same)
    · have eq := List.mem_singleton.mp freshA
      subst a
      exact False.elim (oldNotSame b oldB (same.elim (fun h => Or.inl h.symm) (fun h => Or.inr h.symm)))
    · exact (List.mem_singleton.mp freshA).trans (List.mem_singleton.mp freshB).symm
  · constructor
    · intro x hx
      rcases List.mem_append.mp hx with old | fresh
      · exact custody.1 x (List.mem_of_mem_erase old)
      · have eq := List.mem_singleton.mp fresh
        subst x
        exact custody.1 o oMem
    · intro h hh
      obtain ⟨x,hx,same⟩ := custody.2 h hh
      by_cases eq : x = o
      · subst x
        exact ⟨next,List.mem_append_right _ (List.mem_singleton_self _),same⟩
      · exact ⟨x,List.mem_append_left _ ((List.mem_erase_of_ne eq).mpr hx),same⟩

theorem consistent_held_perm (s : RegistryState) (held : List Holding) (hp : held.Perm s.held)
    (hc : Consistent s) : Consistent {s with held} := by
  have counts : ∀ kind key, kindCount {s with held} kind key = kindCount s kind key := by
    intro kind key
    exact (hp.filter (fun h => h.key == key && h.kind == kind)).length_eq
  obtain ⟨root,active,activeBound,absent,absentBound,terminal,custody,unique⟩ := hc
  refine ⟨root,?_,?_,absent,absentBound,?_,custody,unique⟩
  · intro key; rw [counts]; exact active key
  · intro key; rw [counts]; exact activeBound key
  · intro h hh; exact terminal h (hp.mem_iff.mp hh)

theorem termination_reference_fresh {before after : Singular.World} {b : TerminationBooking}
    (accepted : Singular.bookTermination before b = .ok after) :
    b.request.reference ∉ (before.pending.map (·.request.reference)) ++
      before.terminations.map (·.request.reference) := by
  unfold Singular.bookTermination at accepted
  split at accepted
  next reason => contradiction
  next admitted =>
    split at accepted
    next duplicate => contradiction
    next fresh => simpa [List.any_eq_true,List.mem_map] using fresh

theorem termination_consistent (w w' : World) (b : TerminationBooking) (ref added : Nat) (sigs : List Nat)
    (hc : AppConsistent w) (accepted : bookTerminateStep Law.standard w b ref added sigs = .ok w') : AppConsistent w' := by
  obtain ⟨o,economic,found,pin,policy,name,address,assets,key,registry,active,snapshot,signer,destination,custodyInputs,value,root,effect⟩ := (bookTerminate_inversion w w' b ref added sigs).mp accepted
  have oMem : o ∈ w.outputs := List.mem_of_find?_eq_some found
  have fresh := termination_reference_fresh root
  obtain ⟨admitted,economicEffect⟩ := bookTermination_checks root
  have facts := Singular.Statements.termination_booking_has_exact_contents w.registry b admitted
  have inputs := facts.2.2.2.1
  have contents := facts.2.2.2.2.2.2.2.2
  obtain ⟨consistent,distinct,outputs,unique,custody,metadataDistinct,requestsDistinct,metadata,back,registrations,terminations⟩ := hc
  have outputNodup : w.outputs.Nodup :=
    List.Pairwise.of_map (·.ref) (fun a b h eq => h (congrArg AppOutput.ref eq)) distinct
  have oldKey : ∀ x ∈ w.outputs.erase o, (rootHolding w x).key ≠ b.request.key := by
    intro x hx same
    have shape := outputs x (List.mem_of_mem_erase hx)
    have current : x.envelope.control.key = b.request.key := by
      simpa only [rootHolding,← shape.2.2.1] using same
    have eq := unique x (List.mem_of_mem_erase hx) o oMem (Or.inl (current.trans key.symm))
    subst x
    exact outputNodup.not_mem_erase hx
  have holdingKey : (rootHolding w o).key = b.request.key := by
    simpa only [rootHolding,← snapshot] using key
  have perm :
      ((w.registry.held.filter (fun h => !(h.key == b.request.key && h.kind == .active))) ++
        (b.custodyInputs ++ w.economic.terminations.flatMap (·.custodyInputs))).Perm
      (w.registry.held ++ w.economic.terminations.flatMap (·.custodyInputs)) := by
    rw [inputs]
    simp only [terminationCustody,← List.append_assoc]
    exact (List.perm_append_comm.trans (List.filter_append_perm _ _)).append_right _
  have projected := consistent_held_perm (foldProjectedRegistry w.economic) _ perm consistent
  subst w'
  subst economic
  refine ⟨projected,(List.erase_sublist.map (fun x : AppOutput => x.ref)).nodup distinct,?_,?_,?_,metadataDistinct,?_,metadata,back,registrations,?_⟩
  · intro x hx; exact outputs x (List.mem_of_mem_erase hx)
  · intro a ha c hc; exact unique a (List.mem_of_mem_erase ha) c (List.mem_of_mem_erase hc)
  · constructor
    · intro x hx
      apply List.mem_filter.mpr
      refine ⟨custody.1 x (List.mem_of_mem_erase hx),?_⟩
      have ne : x.registered.control.key ≠ b.request.key := oldKey x hx
      simp [rootHolding,ne]
    · intro h hh
      obtain ⟨old,kept⟩ := List.mem_filter.mp hh
      obtain ⟨x,hx,same⟩ := custody.2 h old
      have ne : x ≠ o := by
        intro eq
        subst x
        rw [← same] at kept
        have hk : o.registered.control.key = b.request.key := holdingKey
        simp [rootHolding,hk] at kept
      exact ⟨x,(List.mem_erase_of_ne ne).mpr hx,same⟩
  · obtain ⟨hr,ht,cross⟩ := List.nodup_append.mp requestsDistinct
    refine List.nodup_append.mpr ⟨hr,List.nodup_cons.mpr ⟨?_,ht⟩,?_⟩
    · intro mem; exact fresh (List.mem_append_right _ mem)
    · intro a ha c hc eq
      rcases List.mem_cons.mp hc with same | old
      · subst c; subst a
        exact fresh (List.mem_append_left _ ha)
      · exact cross a ha c old eq
  · intro old hOld
    rcases List.mem_cons.mp hOld with same | oldMem
    · subst old
      refine ⟨contents,facts.2.2.2.2.1,?_⟩
      intro h hh
      rw [custodyInputs] at hh
      have same := List.mem_singleton.mp hh
      subst h
      exact ⟨holdingKey,rfl⟩
    · exact terminations old oldMem

theorem byteArray_toList_data (bs : ByteArray) : bs.toList = bs.data.toList := by
  have loop : ∀ i acc, ByteArray.toList.loop bs i acc = acc.reverse ++ bs.data.toList.drop i := by
    intro i acc
    fun_induction ByteArray.toList.loop with
    | case1 i acc within ih =>
      rw [ih]
      have bound : i < bs.data.toList.length := by simpa using within
      rw [List.drop_eq_getElem_cons bound]
      simp [List.reverse_cons,List.append_assoc,ByteArray.get!,getElem!_pos,within]
    | case2 i acc outside =>
      have bound : bs.data.toList.length ≤ i := by simpa using Nat.le_of_not_gt outside
      simp [List.drop_eq_nil_of_le bound]
  exact loop 0 []

theorem byteArray_toList_inj (a b : ByteArray) : a.toList = b.toList ↔ a = b := by
  rw [byteArray_toList_data,byteArray_toList_data,Array.toList_inj]
  cases a; cases b
  constructor
  · exact congrArg ByteArray.mk
  · intro h; cases h; rfl

theorem key_extent (s : RegistryState) (key : Key) :
    key ∈ Singular.Driver.stateKeys s ↔
      key ∈ s.trie.map (·.1) ++ s.custody.map (·.key) ++ s.held.map (·.key) := by
  have loop : ∀ (xs acc : List Key),
      key ∈ xs.foldl (fun acc k => if acc.contains k then acc else acc ++ [k]) acc ↔
        key ∈ acc ∨ key ∈ xs := by
    intro xs
    induction xs with
    | nil => intro acc; simp
    | cons x xs ih =>
      intro acc
      simp only [List.foldl_cons]
      by_cases hx : acc.contains x = true
      · simp only [hx,if_true,ih,List.mem_cons]
        have inside : x ∈ acc := by simpa using hx
        constructor
        · intro h; exact h.elim Or.inl (fun h => Or.inr (Or.inr h))
        · rintro (h | eq | h)
          · exact Or.inl h
          · subst key; exact Or.inl inside
          · exact Or.inr h
      · simp only [hx,Bool.false_eq_true,if_false,ih,List.mem_append,List.mem_singleton,List.mem_cons]
        simpa using (@or_assoc (key ∈ acc) (key = x) (key ∈ xs))
  simpa [Singular.Driver.stateKeys] using loop (s.trie.map (·.1) ++ s.custody.map (·.key) ++ s.held.map (·.key)) []

theorem outside_extent (s : RegistryState) (key : Key) (outside : key ∉ Singular.Driver.stateKeys s) :
    kindCount s .active key = 0 ∧ custodyCount s key = 0 ∧ trieGet s.trie key = .unknown := by
  have absent := fun h => outside ((key_extent s key).mpr h)
  have trie : s.trie.filter (·.1 == key) = [] := by
    apply List.filter_eq_nil_iff.mpr
    intro p hp eq
    exact absent (List.mem_append_left _ (List.mem_append_left _ (List.mem_map.mpr ⟨p,hp,beq_iff_eq.mp eq⟩)))
  have custody : s.custody.filter (·.key == key) = [] := by
    apply List.filter_eq_nil_iff.mpr
    intro c hc eq
    exact absent (List.mem_append_left _ (List.mem_append_right _ (List.mem_map.mpr ⟨c,hc,beq_iff_eq.mp eq⟩)))
  have held : s.held.filter (fun h => h.key == key && h.kind == .active) = [] := by
    apply List.filter_eq_nil_iff.mpr
    intro h hh both
    simp only [Bool.and_eq_true,beq_iff_eq] at both
    exact absent (List.mem_append_right _ (List.mem_map.mpr ⟨h,hh,both.1⟩))
  simp [kindCount,custodyCount,trieGet,trie,custody,held]

theorem bool_beq_iff (a b : Bool) : (a == b) = true ↔ (a = true ↔ b = true) := by
  cases a <;> cases b <;> decide

theorem beqs_equal {α β : Type} [BEq α] [LawfulBEq α] [BEq β] [LawfulBEq β]
    (a b : α) (c d : β) : (a == b) = (c == d) ↔ (a = b ↔ c = d) := by
  have truth (x y : Bool) : x = y ↔ (x = true ↔ y = true) := by cases x <;> cases y <;> decide
  rw [truth]
  simp only [beq_iff_eq]

theorem root_bool_shape (s : RegistryState) : Singular.Driver.consistentB s = true ↔
    s.config.root = rootOf s.trie ∧
      (∀ key ∈ Singular.Driver.stateKeys s,
        (kindCount s .active key = 1 ↔ trieGet s.trie key = .known .active) ∧
        kindCount s .active key ≤ 1 ∧
        (custodyCount s key = 1 ↔ trieGet s.trie key = .known .absent) ∧ custodyCount s key ≤ 1) ∧
      (∀ h ∈ s.held, h.kind ≠ .terminal ∨ trieGet s.trie h.key = .known .terminal) ∧
      (∀ c ∈ s.custody, trieGet s.trie c.key = .known .absent) := by
  simp only [Singular.Driver.consistentB,Bool.and_eq_true,List.all_eq_true,bool_beq_iff,
    beq_iff_eq,decide_eq_true_eq,Bool.or_eq_true,Bool.not_eq_true,beq_eq_false_iff_ne]
  simp only [and_assoc,byteArray_toList_inj]
  simp [beqs_equal]

theorem root_bool_consistent (s : RegistryState) : Singular.Driver.consistentB s = true ↔ Consistent s := by
  rw [root_bool_shape]
  constructor
  · rintro ⟨root,census,terminals,custody⟩
    have allKeys : ∀ key,
        (kindCount s .active key = 1 ↔ trieGet s.trie key = .known .active) ∧
        kindCount s .active key ≤ 1 ∧
        (custodyCount s key = 1 ↔ trieGet s.trie key = .known .absent) ∧ custodyCount s key ≤ 1 := by
      intro key
      by_cases inside : key ∈ Singular.Driver.stateKeys s
      · exact census key inside
      · obtain ⟨active,absent,leaf⟩ := outside_extent s key inside
        simp [active,absent,leaf]
    refine ⟨root,fun key => (allKeys key).1,fun key => (allKeys key).2.1,
      fun key => (allKeys key).2.2.1,fun key => (allKeys key).2.2.2,?_,custody,?_⟩
    · intro h hh terminal
      exact (terminals h hh).resolve_left (fun ne => ne terminal)
    · intro a ha b hb same
      apply Singular.members_equal_of_length_le_one ((allKeys a.key).2.2.2)
      · exact List.mem_filter.mpr ⟨ha,by simp⟩
      · exact List.mem_filter.mpr ⟨hb,by simp [same]⟩
  · rintro ⟨root,active,bound,absent,custodyBound,terminals,custody,unique⟩
    refine ⟨root,fun key _ => ⟨active key,bound key,absent key,custodyBound key⟩,?_,custody⟩
    intro h hh
    by_cases terminal : h.kind = .terminal
    · exact Or.inr (terminals h hh terminal)
    · exact Or.inl terminal

theorem mapM_ok_mem {α β : Type} (f : α → Except String β) {xs : List α} {ys : List β}
    (accepted : xs.mapM f = .ok ys) {x : α} (member : x ∈ xs) : ∃ y ∈ ys, f x = .ok y := by
  induction xs generalizing ys with
  | nil => cases member
  | cons a rest ih =>
    simp only [List.mapM_cons,bind_eq_ok_iff] at accepted
    obtain ⟨b,head,tail,later,effect⟩ := accepted
    have eq : b :: tail = ys := ok_inj effect
    subst ys
    rcases List.mem_cons.mp member with same | old
    · subst x; exact ⟨b,List.mem_cons_self,head⟩
    · obtain ⟨y,hy,accepted⟩ := ih later old
      exact ⟨y,List.mem_cons_of_mem _ hy,accepted⟩

theorem registration_at_reference {world : Singular.World} {ref : OutRef} {b : RegistrationBooking}
    (chosen : foldMemberAt world ref = some (.registration b)) : b.request.reference = ref := by
  unfold foldMemberAt at chosen
  cases found : world.pending.find? (fun b => b.request.reference == ref) with
  | some old =>
    simp only [found,Option.some.injEq,FoldMember.registration.injEq] at chosen
    subst old
    simpa using List.find?_some found
  | none =>
    simp only [found] at chosen
    cases world.terminations.find? (fun b => b.request.reference == ref) <;> simp_all

theorem registration_carrier_details {c : Config} {outputs : List EconomicOutput} {b : RegistrationBooking}
    (accepted : foldCarrierRefusal c outputs (.registration b) = none) :
    ∃ o ∈ outputs, o.output.datum = datumFormOf b.request.datum ∧ o.output.datumValue = b.request.datum ∧
      o.output.address = some b.request.destination ∧ o.output.lovelace = b.request.carrierAda ∧
      o.singularTags = [c.singularTag b.request.key] := by
  obtain ⟨o,selected,value,tags,zero⟩ := Singular.foldCarrier_checked accepted
  have member : o ∈ outputs := (List.mem_filter.mp (show o ∈ outputs.filter (fun o => o.singularTags.contains (c.singularTag b.request.key)) from by rw [selected]; simp)).1
  have shape : o.output.address = some b.request.destination ∧ o.output.datumValue = b.request.datum ∧
      o.output.datum = datumFormOf b.request.datum := by
    simp only [foldCarrierRefusal,selected,bind,pure,Option.bind] at accepted
    repeat (split at accepted <;> try contradiction)
    all_goals simp_all
  exact ⟨o,member,shape.2.2,shape.2.1,shape.1,value,tags⟩

theorem pending_key_not_output (w : World) (hc : AppConsistent w) (b : TerminationBooking)
    (pending : b ∈ w.economic.terminations) (o : AppOutput) (member : o ∈ w.outputs) :
    o.envelope.control.key ≠ b.request.key := by
  intro same
  have shape := hc.2.2.1 o member
  have custody := hc.2.2.2.2.1.1 o member
  have pendingShape := hc.2.2.2.2.2.2.2.2.2.2 b pending
  obtain ⟨h,hm⟩ := List.exists_mem_of_length_pos (by rw [pendingShape.2.1]; decide)
  have hShape := pendingShape.2.2 h hm
  have holdingKey : (rootHolding w o).key = b.request.key := by
    simpa only [rootHolding,← shape.2.2.1] using same
  have live : 0 < (w.registry.held.filter (fun h => h.key == b.request.key && h.kind == .active)).length :=
    List.length_pos_of_mem (List.mem_filter.mpr ⟨custody,by have hk : o.registered.control.key = b.request.key := holdingKey; simp [rootHolding,hk]⟩)
  have queued : 0 < ((w.economic.terminations.flatMap (·.custodyInputs)).filter (fun h => h.key == b.request.key && h.kind == .active)).length :=
    List.length_pos_of_mem (List.mem_filter.mpr ⟨List.mem_flatMap.mpr ⟨b,pending,hm⟩,by simp [hShape.1,hShape.2]⟩)
  have bound := hc.1.2.2.1 b.request.key
  simp only [kindCount,foldProjectedRegistry,List.filter_append,List.length_append] at bound
  change 0 < (w.economic.registry.held.filter (fun h => h.key == b.request.key && h.kind == .active)).length at live
  omega

theorem output_key_none (w : World) (key : Key) (hc : AppConsistent w)
    (absent : ∀ o ∈ w.outputs, o.envelope.control.key ≠ key) : (outputOfKey w key).isNone = true := by
  have missing : outputOfKey w key = none := by
    apply List.find?_eq_none.mpr
    intro o member carrying
    have assets := (hc.2.2.1 o member).2.1
    have carried : carriesKey o.assets key = true := by
      simp only [Bool.and_eq_true] at carrying
      exact carrying.2
    rw [assets] at carried
    exact absent o member ((carriesKey_single _ _).mp carried)
  rw [missing]
  rfl

def insertedHolding (r : Request) : Holding := ⟨r.key,.active,r.output,r.datum⟩

theorem foldActions_holding_membership (s : RegistryState) (batch : List Request) (t : Result)
    (accepted : foldActions s batch = .ok t)
    (edges : ∀ r ∈ batch, r.edge = .insertActive ∨ r.edge = .updateTerminal)
    (scan : batch.Pairwise (fun a b => a.edge = .insertActive → b.edge = .updateTerminal → a.key ≠ b.key))
    (holding : Holding) : holding ∈ t.state.held ↔
      (∃ r ∈ batch, r.edge = .insertActive ∧ holding = insertedHolding r) ∨
      (holding ∈ s.held ∧ ∀ r ∈ batch, r.edge = .updateTerminal → ¬(holding.key = r.key ∧ holding.kind = .active)) := by
  induction batch generalizing s t with
  | nil =>
    rw [foldActions_nil_ok s t accepted]
    simp [emptyResult]
  | cons a rest ih =>
    obtain ⟨m,last,first,later,effect⟩ := foldActions_cons_ok s a rest t accepted
    subst t
    change holding ∈ last.state.held ↔ _
    obtain ⟨headScan,tailScan⟩ := List.pairwise_cons.mp scan
    rw [ih m.state last later (fun r hr => edges r (List.mem_cons_of_mem _ hr)) tailScan]
    obtain ⟨refusal,effect⟩ := step_eq_ok s a m first
    subst m
    rcases edges a List.mem_cons_self with insertion | termination
    · have freshSurvives : ∀ r ∈ rest, r.edge = .updateTerminal → ¬((insertedHolding a).key = r.key ∧ (insertedHolding a).kind = .active) := by
        intro r hr terminal same
        exact headScan r hr insertion terminal same.1
      simp only [applyEdge,insertion]
      constructor
      · rintro (⟨r,hr,edge,same⟩ | ⟨member,survives⟩)
        · exact Or.inl ⟨r,List.mem_cons_of_mem _ hr,edge,same⟩
        · rcases List.mem_cons.mp member with same | old
          · exact Or.inl ⟨a,List.mem_cons_self,insertion,same⟩
          · refine Or.inr ⟨old,?_⟩
            intro r hr terminal
            rcases List.mem_cons.mp hr with same | member
            · subst r; simp [insertion] at terminal
            · exact survives r member terminal
      · rintro (⟨r,hr,edge,same⟩ | ⟨member,survives⟩)
        · rcases List.mem_cons.mp hr with head | tail
          · subst r
            subst holding
            exact Or.inr ⟨List.mem_cons_self,freshSurvives⟩
          · exact Or.inl ⟨r,tail,edge,same⟩
        · exact Or.inr ⟨List.mem_cons_of_mem _ member,fun r hr => survives r (List.mem_cons_of_mem _ hr)⟩
    · simp only [applyEdge,termination]
      constructor
      · rintro (⟨r,hr,edge,same⟩ | ⟨member,survives⟩)
        · exact Or.inl ⟨r,List.mem_cons_of_mem _ hr,edge,same⟩
        · obtain ⟨old,kept⟩ := List.mem_filter.mp member
          have avoids : ¬(holding.key = a.key ∧ holding.kind = .active) := by
            intro both
            simp [both.1,both.2] at kept
          refine Or.inr ⟨old,?_⟩
          intro r hr terminal
          rcases List.mem_cons.mp hr with same | member
          · subst r; exact avoids
          · exact survives r member terminal
      · rintro (⟨r,hr,edge,same⟩ | ⟨member,survives⟩)
        · rcases List.mem_cons.mp hr with head | tail
          · subst r; simp [termination] at edge
          · exact Or.inl ⟨r,tail,edge,same⟩
        · refine Or.inr ⟨List.mem_filter.mpr ⟨member,?_⟩,fun r hr => survives r (List.mem_cons_of_mem _ hr)⟩
          have avoids := survives a List.mem_cons_self termination
          by_cases same : holding.key = a.key
          · have different : holding.kind ≠ .active := fun kind => avoids ⟨same,kind⟩
            simp [same,different]
          · simp [same]

theorem pending_key_active (w : World) (hc : AppConsistent w) (b : TerminationBooking)
    (pending : b ∈ w.economic.terminations) : trieGet w.registry.trie b.request.key = .known .active := by
  have shape := hc.2.2.2.2.2.2.2.2.2.2 b pending
  obtain ⟨h,hm⟩ := List.exists_mem_of_length_pos (by rw [shape.2.1]; decide)
  have hs := shape.2.2 h hm
  have positive : 0 < kindCount (foldProjectedRegistry w.economic) .active b.request.key := by
    apply List.length_pos_of_mem
    apply List.mem_filter.mpr
    exact ⟨List.mem_append_right _ (List.mem_flatMap.mpr ⟨b,pending,hm⟩),by simp [hs.1,hs.2]⟩
  have bound := hc.1.2.2.1 b.request.key
  exact (hc.1.2.1 b.request.key).mp (by omega)

theorem pending_key_not_holding (w : World) (hc : AppConsistent w) (b : TerminationBooking)
    (pending : b ∈ w.economic.terminations) (h : Holding) (member : h ∈ w.registry.held) : h.key ≠ b.request.key := by
  obtain ⟨o,omem,same⟩ := hc.2.2.2.2.1.2 h member
  have shape := hc.2.2.1 o omem
  have ne := pending_key_not_output w hc b pending o omem
  intro eq
  apply ne
  rw [← same] at eq
  simpa only [rootHolding,← shape.2.2.1] using eq

theorem pending_termination_selected (w : World) (hc : AppConsistent w) (b : TerminationBooking)
    (tx : EconomicTransaction) (pending : b ∈ w.economic.terminations)
    (spent : inputsContainReference tx.transaction.inputs b.request.reference = true) :
    FoldMember.termination b ∈ foldMembers w.economic tx := by
  have distinct := List.nodup_append.mp hc.2.2.2.2.2.2.1
  have registration : w.economic.pending.find? (fun r => r.request.reference == b.request.reference) = none := by
    apply List.find?_eq_none.mpr
    intro r hr same
    exact distinct.2.2 _ (List.mem_map.mpr ⟨r,hr,rfl⟩) _ (List.mem_map.mpr ⟨b,pending,rfl⟩) (beq_iff_eq.mp same)
  have selected := Singular.distinct_key_filter (fun b : TerminationBooking => b.request.reference) distinct.2.1 pending
  have termination : w.economic.terminations.find? (fun r => r.request.reference == b.request.reference) = some b := by
    rw [← List.head?_filter]
    have predicates : (fun r : TerminationBooking => r.request.reference == b.request.reference) =
        (fun r => decide (r.request.reference = b.request.reference)) := by
      funext r; apply Bool.eq_iff_iff.mpr; simp
    rw [predicates,selected]
    rfl
  obtain ⟨input,member,reference⟩ := List.any_eq_true.mp spent
  have reference' : input.ref = some b.request.reference := by simpa using reference
  apply List.mem_filterMap.mpr
  exact ⟨input,member,by simp [reference',foldMemberAt,registration,termination]⟩

theorem root_fold_holdings (w : World) (hc : AppConsistent w) (u : EconomicUtxo) (tx : EconomicTransaction)
    (after : Singular.World) (accepted : Singular.foldAccepted w.economic u tx = .ok after) (h : Holding) :
    h ∈ after.registry.held ↔ h ∈ w.registry.held ∨
      ∃ b, FoldMember.registration b ∈ foldMembers w.economic tx ∧
        h = insertedHolding (foldLegacyRequest w.registry.config (.registration b)) := by
  obtain ⟨_,result,registry,_,effect⟩ := Singular.foldAccepted_checks accepted
  have edges : ∀ r ∈ (foldMembers w.economic tx).map (foldLegacyRequest w.registry.config),
      r.edge = .insertActive ∨ r.edge = .updateTerminal := by
    intro r hr
    obtain ⟨member,hm,rfl⟩ := List.mem_map.mp hr
    cases member <;> simp [foldLegacyRequest]
  have scan := (Singular.created_scan_none [] _).mp (Singular.foldBatch_scan _ _ _ registry) |>.2
  have holdings := foldActions_holding_membership _ _ _ (Singular.foldBatch_inv _ _ _ registry).2 edges scan h
  have registrationNe : ∀ b, FoldMember.registration b ∈ foldMembers w.economic tx →
      ∀ t ∈ w.economic.terminations, b.request.key ≠ t.request.key := by
    intro b selected t pending eq
    have unknown := folded_registration_was_unknown accepted selected
    have active := pending_key_active w hc t pending
    rw [eq,active] at unknown
    contradiction
  have oldKept : h ∈ w.registry.held →
      (foldRemainingTerminations w.economic tx).any (fun b => b.request.key == h.key) = false := by
    intro member
    apply Bool.eq_false_iff.mpr
    intro present
    obtain ⟨b,hb,same⟩ := List.any_eq_true.mp present
    exact pending_key_not_holding w hc b (List.mem_filter.mp hb).1 h member (beq_iff_eq.mp same).symm
  subst after
  change h ∈ result.state.held.filter (fun h => !(h.kind == .active && (foldRemainingTerminations w.economic tx).any (fun b => b.request.key == h.key))) ↔ _
  constructor
  · intro member
    obtain ⟨original,kept⟩ := List.mem_filter.mp member
    rcases holdings.mp original with ⟨r,hr,inserted,same⟩ | ⟨old,survives⟩
    · obtain ⟨m,hm,rfl⟩ := List.mem_map.mp hr
      cases m with
      | registration b => exact Or.inr ⟨b,hm,same⟩
      | termination b => simp [foldLegacyRequest] at inserted
    · rcases List.mem_append.mp old with live | pending
      · exact Or.inl live
      · obtain ⟨b,hb,hh⟩ := List.mem_flatMap.mp pending
        have shape := (hc.2.2.2.2.2.2.2.2.2.2 b hb).2.2 h hh
        by_cases spent : inputsContainReference tx.transaction.inputs b.request.reference = true
        · have chosen := pending_termination_selected w hc b tx hb spent
          have avoids := survives (foldLegacyRequest w.registry.config (.termination b))
            (List.mem_map.mpr ⟨.termination b,chosen,rfl⟩) rfl
          exact False.elim (avoids ⟨shape.1,shape.2⟩)
        · have remaining : b ∈ foldRemainingTerminations w.economic tx := List.mem_filter.mpr ⟨hb,by simpa using spent⟩
          have present : (foldRemainingTerminations w.economic tx).any (fun b => b.request.key == h.key) = true :=
            List.any_eq_true.mpr ⟨b,remaining,by simp [shape.1]⟩
          simp [shape.2,present] at kept
  · rintro (old | ⟨b,chosen,same⟩)
    · apply List.mem_filter.mpr
      refine ⟨holdings.mpr (Or.inr ⟨List.mem_append_left _ old,?_⟩),by simp [oldKept old]⟩
      intro r hr terminal both
      obtain ⟨m,hm,rfl⟩ := List.mem_map.mp hr
      cases m with
      | registration b => simp [foldLegacyRequest] at terminal
      | termination b => exact pending_key_not_holding w hc b (Singular.foldMembers_termination hm).1 h old both.1
    · apply List.mem_filter.mpr
      refine ⟨holdings.mpr (Or.inl ⟨_,List.mem_map.mpr ⟨.registration b,chosen,rfl⟩,rfl,same⟩),?_⟩
      have missing : (foldRemainingTerminations w.economic tx).any (fun t => t.request.key == h.key) = false := by
        apply Bool.eq_false_iff.mpr
        intro present
        obtain ⟨t,ht,key⟩ := List.any_eq_true.mp present
        have key' : t.request.key = b.request.key := by simpa [same,insertedHolding,foldLegacyRequest] using key
        exact registrationNe b chosen t (List.mem_filter.mp ht).1 key'.symm
      simp [missing]

theorem consistent_pending_shape (w : World) (hc : AppConsistent w) : PendingCustodyShape w.economic := by
  intro b member
  have shape := hc.2.2.2.2.2.2.2.2.2.2 b member
  have contents := shape.1
  simp only [terminationExactContents,Bool.and_eq_true,decide_eq_true_eq] at contents
  exact ⟨contents.2.2.1,shape.2⟩

theorem consistent_world_supply (w : World) (hc : AppConsistent w) :
    WorldSupplyConsistent w.economic ∧
      ∀ key, carriedSingularCount w.economic key = pendingTerminationCount w.economic key := by
  have shape := consistent_pending_shape w hc
  have counts := fun key => Singular.pending_custody_counts w.registry.config w.economic.terminations shape key
  refine ⟨?_,fun key => (counts key).2⟩
  intro key
  have law : kindCount (foldProjectedRegistry w.economic) .active key =
      if trieGet w.registry.trie key = .known .active then 1 else 0 := by
    by_cases active : trieGet w.registry.trie key = .known .active
    · simp [active,(hc.1.2.1 key).mpr active]
    · have ne : kindCount (foldProjectedRegistry w.economic) .active key ≠ 1 := fun one => active ((hc.1.2.1 key).mp one)
      have bound : kindCount (foldProjectedRegistry w.economic) .active key ≤ 1 := hc.1.2.2.1 key
      rw [if_neg active]
      omega
  unfold worldSingularSupply
  have carried : carriedSingularCount w.economic key = pendingTerminationCount w.economic key := (counts key).2
  rw [carried]
  simpa [World.registry,kindCount,foldProjectedRegistry,List.filter_append,List.length_append,(counts key).1,pendingTerminationCount] using law

theorem fold_projected_consistent (w : World) (hc : AppConsistent w) (u : EconomicUtxo) (tx : EconomicTransaction)
    (after : Singular.World) (accepted : Singular.foldAccepted w.economic u tx = .ok after) :
    Consistent (foldProjectedRegistry after) := by
  obtain ⟨_,result,registry,_,effect⟩ := Singular.foldAccepted_checks accepted
  have final := foldActions_consistent _ _ _ hc.1 (Singular.foldBatch_inv _ _ _ registry).2
  obtain ⟨supply,counts⟩ := consistent_world_supply w hc
  have beforeShape := consistent_pending_shape w hc
  have afterShape : PendingCustodyShape after := by
    intro b member
    rw [(Singular.foldAccepted_pending accepted).2] at member
    have shape := beforeShape b (List.mem_filter.mp member).1
    rw [Singular.foldAccepted_config accepted]
    simpa [Config.singularTag] using shape
  have bound : ∀ key, pendingTerminationCount w.economic key ≤ 1 := by
    intro key
    have law := supply key
    unfold worldSingularSupply at law
    rw [counts] at law
    split at law <;> omega
  have countAfter : ∀ key, kindCount (foldProjectedRegistry after) .active key = kindCount result.state .active key := by
    intro key
    have restored := (Singular.pending_custody_counts after.registry.config after.terminations afterShape key).1
    have projected : kindCount (foldProjectedRegistry after) .active key =
        kindCount after.registry .active key + pendingTerminationCount after key := by
      simp [kindCount,foldProjectedRegistry,List.filter_append,List.length_append,restored,pendingTerminationCount]
    have remainingBound : pendingTerminationCount after key ≤ 1 := by
      apply Nat.le_trans ?_ (bound key)
      unfold pendingTerminationCount
      rw [(Singular.foldAccepted_pending accepted).2]
      exact (List.Sublist.filter _ List.filter_sublist).length_le
    rw [projected]
    have afterRegistry : after.registry = foldRegistryEffect w.economic tx result := by rw [effect]; rfl
    rw [afterRegistry,Singular.fold_effect_active_count]
    by_cases present : (foldRemainingTerminations w.economic tx).any (fun b => b.request.key == key) = true
    · obtain ⟨b,member,same⟩ := List.any_eq_true.mp present
      have keyEq : b.request.key = key := by simpa using same
      have active := Singular.remaining_active_after_fold supply counts bound registry member
      rw [keyEq] at active
      have one := (final.2.1 key).mpr active
      have positive : 0 < pendingTerminationCount after key := by
        unfold pendingTerminationCount
        rw [(Singular.foldAccepted_pending accepted).2]
        exact List.length_pos_of_mem (List.mem_filter.mpr ⟨member,same⟩)
      rw [if_pos present,one]
      omega
    · have zero : pendingTerminationCount after key = 0 := by
        unfold pendingTerminationCount
        rw [(Singular.foldAccepted_pending accepted).2]
        apply List.length_eq_zero_iff.mpr
        apply List.filter_eq_nil_iff.mpr
        intro b member same
        exact present (List.any_eq_true.mpr ⟨b,member,same⟩)
      rw [if_neg present,zero,Nat.add_zero]
  obtain ⟨root,active,activeBound,absent,absentBound,terminal,custody,unique⟩ := final
  have sameTrie : (foldProjectedRegistry after).trie = result.state.trie := by rw [effect]; rfl
  have sameConfig : (foldProjectedRegistry after).config = result.state.config := by rw [effect]; rfl
  have sameCustody : (foldProjectedRegistry after).custody = result.state.custody := by rw [effect]; rfl
  refine ⟨?_,?_,?_,?_,?_,?_,?_,?_⟩
  · rw [sameConfig,sameTrie]; exact root
  · intro key; rw [countAfter,sameTrie]; exact active key
  · intro key; rw [countAfter]; exact activeBound key
  · intro key; simpa only [custodyCount,sameCustody,sameTrie] using absent key
  · intro key; simpa only [custodyCount,sameCustody] using absentBound key
  · intro h member kind
    rw [sameTrie]
    rcases List.mem_append.mp member with held | pending
    · have kept : h ∈ result.state.held := by
        rw [effect] at held
        exact (List.mem_filter.mp held).1
      exact terminal h kept kind
    · obtain ⟨b,member,held⟩ := List.mem_flatMap.mp pending
      have active := (afterShape b member).2.2 h held
      rw [kind] at active
      cases active.2
  · simpa only [sameCustody,sameTrie] using custody
  · simpa only [sameCustody] using unique

theorem selectRow_inversion (w : World) (ref : OutRef) (row : FoldRow) :
    selectRow Law.standard w ref = .ok row ↔
      (∃ b p, foldMemberAt w.economic ref = some (.registration b) ∧ pendingOf w ref = some p ∧
        insertionBinding Law.standard w b.request p.envelope = true ∧ row = ⟨.registration b, some p.envelope⟩) ∨
      (∃ b, foldMemberAt w.economic ref = some (.termination b) ∧ row = ⟨.termination b, none⟩) := by
  cases hm : foldMemberAt w.economic ref with
  | none => simp [selectRow, hm]
  | some member =>
    cases member with
    | registration b =>
      cases hp : pendingOf w ref with
      | none => simp [selectRow, hm, hp]
      | some p =>
        simp only [selectRow, hm, hp]
        simp only [ProofSupport.bind_eq_ok_iff, ProofSupport.ensure_eq_ok_iff]
        simp [hm, hp, pure, Except.pure]
        intro binding
        exact eq_comm
    | termination b =>
      simp [selectRow, hm, pure, Except.pure]
      exact eq_comm

theorem mapM_ok_image {α β γ : Type} (f : α → Except String β) (lookup : α → Option γ) (project : β → γ)
    (agrees : ∀ x y, f x = .ok y → lookup x = some (project y))
    {xs : List α} {ys : List β} (accepted : xs.mapM f = .ok ys) : xs.filterMap lookup = ys.map project := by
  induction xs generalizing ys with
  | nil => have eq : ([] : List β) = ys := ok_inj accepted; subst ys; rfl
  | cons a rest ih =>
    simp only [List.mapM_cons,bind_eq_ok_iff] at accepted
    obtain ⟨b,head,tail,later,effect⟩ := accepted
    have eq : b :: tail = ys := ok_inj effect
    subst ys
    simp only [List.filterMap_cons,agrees a b head,Option.toList_some,List.map_cons]
    rw [ih later]

theorem mapM_ok_preimage {α β : Type} (f : α → Except String β) {xs : List α} {ys : List β}
    (accepted : xs.mapM f = .ok ys) {y : β} (member : y ∈ ys) : ∃ x ∈ xs, f x = .ok y := by
  induction xs generalizing ys with
  | nil => have eq : ([] : List β) = ys := ok_inj accepted; subst ys; cases member
  | cons a rest ih =>
    simp only [List.mapM_cons,bind_eq_ok_iff] at accepted
    obtain ⟨b,head,tail,later,effect⟩ := accepted
    have eq : b :: tail = ys := ok_inj effect
    subst ys
    rcases List.mem_cons.mp member with same | old
    · subst y; exact ⟨a,List.mem_cons_self,head⟩
    · obtain ⟨x,hx,accepted⟩ := ih later old
      exact ⟨x,List.mem_cons_of_mem _ hx,accepted⟩

theorem selectedRows_members (w : World) (tx : EconomicTransaction) (rows : List FoldRow)
    (selection : (selectedReferences w tx).mapM (selectRow Law.standard w) = .ok rows) :
    rows.map (·.member) = foldMembers w.economic tx := by
  have agrees : ∀ ref row, selectRow Law.standard w ref = .ok row → foldMemberAt w.economic ref = some row.member := by
    intro ref row accepted
    rcases (selectRow_inversion w ref row).mp accepted with ⟨b,p,found,_,_,effect⟩ | ⟨b,found,effect⟩
    · subst row; exact found
    · subst row; exact found
  rw [← mapM_ok_image (selectRow Law.standard w) (foldMemberAt w.economic) (fun row => row.member) agrees selection]
  unfold selectedReferences foldMembers
  simp only [List.filterMap_filterMap]
  congr 1
  funext input
  cases reference : input.ref with
  | none => simp
  | some ref =>
    cases lookup : foldMemberAt w.economic ref <;> simp [lookup,Option.filter]

def registrationPairs (rows : List FoldRow) : List (RegistrationBooking × Envelope) :=
  rows.filterMap fun row => match row.member,row.envelope with
    | .registration b,some e => some (b,e)
    | _,_ => none

theorem registrationPair_facts (w : World) (tx : EconomicTransaction) (rows : List FoldRow)
    (selection : (selectedReferences w tx).mapM (selectRow Law.standard w) = .ok rows)
    (b : RegistrationBooking) (e : Envelope) (pair : (b,e) ∈ registrationPairs rows) :
    FoldMember.registration b ∈ foldMembers w.economic tx ∧ insertionBinding Law.standard w b.request e = true := by
  obtain ⟨row,rowMem,chosen⟩ := List.mem_filterMap.mp pair
  obtain ⟨ref,_,accepted⟩ := mapM_ok_preimage _ selection rowMem
  rcases (selectRow_inversion w ref row).mp accepted with ⟨booking,p,found,hp,binding,effect⟩ | ⟨booking,found,effect⟩
  · subst row
    simp only [Option.some.injEq,Prod.mk.injEq] at chosen
    obtain ⟨rfl,rfl⟩ := chosen
    exact ⟨by rw [← selectedRows_members w tx rows selection]; exact List.mem_map.mpr ⟨_,rowMem,rfl⟩,binding⟩
  · subst row
    cases chosen

theorem insertedKeys_nodup (s : RegistryState) (batch : List Request) (result : Result)
    (accepted : foldActions s batch = .ok result)
    (edges : ∀ r ∈ batch, r.edge = .insertActive ∨ r.edge = .updateTerminal) :
    ((batch.filter (fun r => r.edge == .insertActive)).map (·.key)).Nodup := by
  have count (key : Key) : ((batch.filter (fun r => r.edge == .insertActive)).map (·.key)).count key =
      (((batch.filter (fun r => r.key == key)).map (·.edge)).count .insertActive) := by
    clear accepted edges
    induction batch with
    | nil => rfl
    | cons r rest ih =>
      by_cases hk : r.key = key <;> by_cases he : r.edge = .insertActive <;> simp [hk,he,ih]
  apply List.nodup_iff_count.mpr
  intro key
  rw [count]
  rcases (foldActions_key key batch s result accepted edges).2 with ⟨empty,_,_⟩ | ⟨one,_,_,_⟩ | ⟨one,_,_,_⟩ | ⟨two,_,_,_⟩
  · rw [empty]; decide
  · rw [one]; decide
  · rw [one]; decide
  · rw [two]; decide

theorem registrationPairs_keys (w : World) (rows : List FoldRow)
    (valid : ∀ row ∈ rows, ∃ ref, selectRow Law.standard w ref = .ok row) :
    (registrationPairs rows).map (fun p => p.1.request.key) =
      (((rows.map (·.member)).map (foldLegacyRequest w.registry.config)).filter (fun r => r.edge == .insertActive)).map (·.key) := by
  induction rows with
  | nil => rfl
  | cons row rest ih =>
    obtain ⟨ref,accepted⟩ := valid row List.mem_cons_self
    have tail := ih (fun r hr => valid r (List.mem_cons_of_mem _ hr))
    rcases (selectRow_inversion w ref row).mp accepted with ⟨b,p,_,_,_,effect⟩ | ⟨b,_,effect⟩
    · subst row; simp [registrationPairs,foldLegacyRequest]
      simpa [registrationPairs,List.map_map] using tail
    · subst row; simp [registrationPairs,foldLegacyRequest]
      simpa [registrationPairs,List.map_map] using tail

theorem registrationPairs_keys_distinct (w : World) (tx : EconomicTransaction) (rows : List FoldRow)
    (selection : (selectedReferences w tx).mapM (selectRow Law.standard w) = .ok rows)
    (u : EconomicUtxo) (after : Singular.World) (accepted : Singular.foldAccepted w.economic u tx = .ok after) :
    ((registrationPairs rows).map (fun p => p.1.request.key)).Nodup := by
  have valid : ∀ row ∈ rows, ∃ ref, selectRow Law.standard w ref = .ok row := by
    intro row member
    obtain ⟨ref,_,selected⟩ := mapM_ok_preimage _ selection member
    exact ⟨ref,selected⟩
  rw [registrationPairs_keys w rows valid,selectedRows_members w tx rows selection]
  obtain ⟨_,result,registry,_,_⟩ := Singular.foldAccepted_checks accepted
  apply insertedKeys_nodup _ _ result (Singular.foldBatch_inv _ _ _ registry).2
  intro r member
  obtain ⟨m,hm,rfl⟩ := List.mem_map.mp member
  cases m <;> simp [foldLegacyRequest]

theorem created_refs (app : App) (first : Nat) (rows : List FoldRow) :
    (createdOutputs app first rows).map (·.ref) = List.range' first (registrationPairs rows).length := by
  calc
    _ = ((registrationPairs rows).zipIdx.map Prod.snd).map (first + ·) := by
      simp only [createdOutputs,registrationPairs,List.map_map]
      rfl
    _ = _ := by rw [List.zipIdx_map_snd,List.map_add_range']; simp

theorem created_keys (app : App) (first : Nat) (rows : List FoldRow) :
    (createdOutputs app first rows).map (fun o => o.envelope.control.key) =
      (registrationPairs rows).map (fun p => p.2.control.key) := by
  calc
    _ = ((registrationPairs rows).zipIdx.map Prod.fst).map (fun p => p.2.control.key) := by
      simp only [createdOutputs,registrationPairs,List.map_map]
      rfl
    _ = _ := by rw [List.zipIdx_map_fst]

theorem created_keys_distinct (w : World) (tx : EconomicTransaction) (rows : List FoldRow)
    (selection : (selectedReferences w tx).mapM (selectRow Law.standard w) = .ok rows)
    (u : EconomicUtxo) (after : Singular.World) (accepted : Singular.foldAccepted w.economic u tx = .ok after) :
    ((createdOutputs w.app w.nextRef rows).map (fun o => o.envelope.control.key)).Nodup := by
  rw [created_keys]
  have same : (registrationPairs rows).map (fun p => p.2.control.key) =
      (registrationPairs rows).map (fun p => p.1.request.key) := by
    apply List.map_congr_left
    intro p hp
    have binding := (registrationPair_facts w tx rows selection p.1 p.2 hp).2
    simp only [insertionBinding,Bool.and_eq_true,beq_iff_eq] at binding
    exact binding.1.1.1.1.2
  rw [same]
  exact registrationPairs_keys_distinct w tx rows selection u after accepted

theorem created_observation (app : App) (first : Nat) (rows : List FoldRow) (o : AppOutput)
    (member : o ∈ createdOutputs app first rows) :
    ∃ b e i, (b,e) ∈ registrationPairs rows ∧ i < (registrationPairs rows).length ∧
      o = { ref := first + i,address := appAddress app,lovelace := b.request.carrierAda, assets := [((.active,b.request.key),1)],envelope := e,registered := e } := by
  obtain ⟨⟨⟨b,e⟩,i⟩,chosen,effect⟩ := List.mem_map.mp member
  exact ⟨b,e,i,List.fst_mem_of_mem_zipIdx chosen,(List.mem_zipIdx' chosen).1,effect.symm⟩

theorem map_key_unique {α : Type} (key : α → Nat) (xs : List α) (distinct : (xs.map key).Nodup)
    (a b : α) (ha : a ∈ xs) (hb : b ∈ xs) (same : key a = key b) : a = b := by
  have selected := Singular.distinct_key_filter key distinct hb
  have member : a ∈ xs.filter (fun x => decide (key x = key b)) := List.mem_filter.mpr ⟨ha,by simpa using same⟩
  rw [selected] at member
  exact List.mem_singleton.mp member

theorem output_key_active (w : World) (hc : AppConsistent w) (o : AppOutput) (member : o ∈ w.outputs) :
    trieGet w.registry.trie o.envelope.control.key = .known .active := by
  have shape := hc.2.2.1 o member
  have custody := hc.2.2.2.2.1.1 o member
  have positive : 0 < kindCount (foldProjectedRegistry w.economic) .active o.envelope.control.key := by
    apply List.length_pos_of_mem
    apply List.mem_filter.mpr
    refine ⟨List.mem_append_left _ custody,?_⟩
    simp [rootHolding,← shape.2.2.1]
  have bound : kindCount (foldProjectedRegistry w.economic) .active o.envelope.control.key ≤ 1 := hc.1.2.2.1 _
  exact (hc.1.2.1 _).mp (by omega)

theorem selected_registration_pair (w : World) (tx : EconomicTransaction) (rows : List FoldRow)
    (selection : (selectedReferences w tx).mapM (selectRow Law.standard w) = .ok rows)
    (b : RegistrationBooking) (selected : FoldMember.registration b ∈ foldMembers w.economic tx) :
    ∃ e, (b,e) ∈ registrationPairs rows := by
  rw [← selectedRows_members w tx rows selection] at selected
  obtain ⟨row,rowMem,member⟩ := List.mem_map.mp selected
  obtain ⟨ref,_,accepted⟩ := mapM_ok_preimage _ selection rowMem
  rcases (selectRow_inversion w ref row).mp accepted with ⟨booking,p,_,_,_,effect⟩ | ⟨booking,_,effect⟩
  · subst row
    cases member
    exact ⟨p.envelope,List.mem_filterMap.mpr ⟨_,rowMem,rfl⟩⟩
  · subst row
    cases member

theorem created_from_pair (app : App) (first : Nat) (rows : List FoldRow) (b : RegistrationBooking) (e : Envelope)
    (member : (b,e) ∈ registrationPairs rows) : ∃ i,
      ({ref := first+i,address := appAddress app,lovelace := b.request.carrierAda, assets := [((.active,b.request.key),1)],envelope := e,registered := e} : AppOutput) ∈ createdOutputs app first rows := by
  have mapped : (b,e) ∈ (registrationPairs rows).zipIdx.map Prod.fst := by rw [List.zipIdx_map_fst]; exact member
  obtain ⟨⟨⟨booking,envelope⟩,i⟩,chosen,effect⟩ := List.mem_map.mp mapped
  cases effect
  exact ⟨i,List.mem_map.mpr ⟨((b,e),i),chosen,rfl⟩⟩

theorem binding_fields (w : World) (b : RegistrationBooking) (e : Envelope)
    (binding : insertionBinding Law.standard w b.request e = true) :
    e.control.key = b.request.key ∧ e.control.registry = w.registryAsset ∧ e.control.deposit = b.request.carrierAda ∧
      b.request.destination = destinationOf w.app e ∧ b.request.datum = some (envelopeHash e) := by
  simp only [insertionBinding,Law.standard,Bool.and_eq_true,Bool.not_true,Bool.false_or,beq_iff_eq] at binding
  exact ⟨binding.1.1.1.1.2,binding.1.1.1.1.1.1.1.2.1.2,binding.2,binding.1.1.2,binding.1.2⟩

theorem created_holding (w : World) (tx : EconomicTransaction) (rows : List FoldRow)
    (selection : (selectedReferences w tx).mapM (selectRow Law.standard w) = .ok rows)
    (o : AppOutput) (member : o ∈ createdOutputs w.app w.nextRef rows) :
    ∃ b, FoldMember.registration b ∈ foldMembers w.economic tx ∧
      rootHolding w o = insertedHolding (foldLegacyRequest w.registry.config (.registration b)) := by
  obtain ⟨b,e,i,pair,bound,effect⟩ := created_observation w.app w.nextRef rows o member
  obtain ⟨chosen,binding⟩ := registrationPair_facts w tx rows selection b e pair
  obtain ⟨key,_,_,destination,datum⟩ := binding_fields w b e binding
  subst o
  exact ⟨b,chosen,by simp [rootHolding,insertedHolding,foldLegacyRequest,key,destination,datum]⟩

theorem created_shape (w : World) (tx : EconomicTransaction) (rows : List FoldRow)
    (selection : (selectedReferences w tx).mapM (selectRow Law.standard w) = .ok rows)
    (o : AppOutput) (member : o ∈ createdOutputs w.app w.nextRef rows) :
    o.address = appAddress w.app ∧ o.assets = [((.active,o.envelope.control.key),1)] ∧
      o.envelope.control = o.registered.control ∧ o.envelope.control.registry = w.registryAsset ∧
      o.envelope.control.deposit ≤ o.lovelace ∧ w.nextRef ≤ o.ref ∧
      o.ref < w.nextRef + (createdOutputs w.app w.nextRef rows).length := by
  obtain ⟨b,e,i,pair,bound,effect⟩ := created_observation w.app w.nextRef rows o member
  obtain ⟨key,registry,value,_,_⟩ := binding_fields w b e (registrationPair_facts w tx rows selection b e pair).2
  have length : (createdOutputs w.app w.nextRef rows).length = (registrationPairs rows).length := by
    simp [createdOutputs,registrationPairs]
    rfl
  subst o
  refine ⟨rfl,by simp [key],rfl,registry,by simp [value],by simp,?_⟩
  change w.nextRef + i < w.nextRef + (createdOutputs w.app w.nextRef rows).length
  rw [length]
  omega

theorem fold_consistent (w w' : World) (u : EconomicUtxo) (tx : EconomicTransaction)
    (hc : AppConsistent w) (accepted : foldEffect Law.standard w u tx = .ok w') : AppConsistent w' := by
  obtain ⟨rows,economic,selection,root,timing,effect⟩ := (fold_inversion w w' u tx).mp accepted
  have original := hc
  have projected := fold_projected_consistent w hc u tx economic root
  have config := Singular.foldAccepted_config root
  have keys := created_keys_distinct w tx rows selection u economic root
  have refs : ((createdOutputs w.app w.nextRef rows).map (·.ref)).Nodup := by
    rw [created_refs]
    exact List.nodup_range'
  have differentKeys : ∀ old ∈ w.outputs, ∀ fresh ∈ createdOutputs w.app w.nextRef rows,
      old.envelope.control.key ≠ fresh.envelope.control.key := by
    intro old oldMem fresh freshMem eq
    obtain ⟨b,e,i,pair,_,freshEffect⟩ := created_observation w.app w.nextRef rows fresh freshMem
    obtain ⟨chosen,binding⟩ := registrationPair_facts w tx rows selection b e pair
    have key := (binding_fields w b e binding).1
    have freshKey : fresh.envelope.control.key = b.request.key := by rw [freshEffect]; exact key
    have active := output_key_active w hc old oldMem
    have unknown := folded_registration_was_unknown root chosen
    rw [← eq.trans freshKey,active] at unknown
    contradiction
  have differentRefs : ∀ old ∈ w.outputs, ∀ fresh ∈ createdOutputs w.app w.nextRef rows, old.ref ≠ fresh.ref := by
    intro old oldMem fresh freshMem eq
    have before := (hc.2.2.1 old oldMem).2.2.2.2.2
    have after := (created_shape w tx rows selection fresh freshMem).2.2.2.2.2.1
    omega
  have bindingEq (r : RegistrationRequest) (e : Envelope) :
      insertionBinding Law.standard {w with economic} r e = insertionBinding Law.standard w r e := by
    unfold insertionBinding registryAssetMatches World.registry
    rw [config]
    rfl
  obtain ⟨consistent,distinct,outputs,unique,custody,metadataDistinct,requestsDistinct,metadata,back,registrations,terminations⟩ := hc
  subst w'
  refine ⟨projected,?_,?_,?_,?_,?_,?_,?_,?_,?_,?_⟩
  · rw [List.map_append]
    refine List.nodup_append.mpr ⟨distinct,refs,?_⟩
    intro a ha b hb eq
    obtain ⟨old,oldMem,rfl⟩ := List.mem_map.mp ha
    obtain ⟨fresh,freshMem,rfl⟩ := List.mem_map.mp hb
    exact differentRefs old oldMem fresh freshMem eq
  · intro o member
    rcases List.mem_append.mp member with old | fresh
    · have shape := outputs o old
      refine ⟨shape.1,shape.2.1,shape.2.2.1,shape.2.2.2.1,shape.2.2.2.2.1,?_⟩
      change o.ref < w.nextRef + (createdOutputs w.app w.nextRef rows).length
      have := shape.2.2.2.2.2
      omega
    · have shape := created_shape w tx rows selection o fresh
      exact ⟨shape.1,shape.2.1,shape.2.2.1,shape.2.2.2.1,shape.2.2.2.2.1,shape.2.2.2.2.2.2⟩
  · intro a ha b hb same
    rcases List.mem_append.mp ha with oldA | freshA <;> rcases List.mem_append.mp hb with oldB | freshB
    · exact unique a oldA b oldB same
    · exact False.elim (same.elim (differentKeys a oldA b freshB) (differentRefs a oldA b freshB))
    · exact False.elim (same.elim (fun h => differentKeys b oldB a freshA h.symm) (fun h => differentRefs b oldB a freshA h.symm))
    · rcases same with key | ref
      · exact map_key_unique (fun o => o.envelope.control.key) _ keys a b freshA freshB key
      · exact map_key_unique (fun o => o.ref) _ refs a b freshA freshB ref
  · constructor
    · intro o member
      change rootHolding w o ∈ economic.registry.held
      apply (root_fold_holdings w original u tx economic root _).mpr
      rcases List.mem_append.mp member with old | fresh
      · exact Or.inl (custody.1 o old)
      · exact Or.inr (created_holding w tx rows selection o fresh)
    · intro h member
      change h ∈ economic.registry.held at member
      rcases (root_fold_holdings w original u tx economic root h).mp member with old | ⟨b,selected,same⟩
      · obtain ⟨o,omem,effect⟩ := custody.2 h old
        exact ⟨o,List.mem_append_left _ omem,effect⟩
      · obtain ⟨e,pair⟩ := selected_registration_pair w tx rows selection b selected
        obtain ⟨i,created⟩ := created_from_pair w.app w.nextRef rows b e pair
        obtain ⟨key,_,_,destination,datum⟩ := binding_fields w b e (registrationPair_facts w tx rows selection b e pair).2
        refine ⟨_,List.mem_append_right _ created,?_⟩
        rw [same]
        simp [rootHolding,insertedHolding,foldLegacyRequest,key,destination,datum]
  · exact (List.filter_sublist.map (fun p : Pending => p.reference)).nodup metadataDistinct
  · rw [(Singular.foldAccepted_pending root).1,(Singular.foldAccepted_pending root).2]
    exact ((List.filter_sublist.map (fun b : RegistrationBooking => b.request.reference)).append
      (List.filter_sublist.map (fun b : TerminationBooking => b.request.reference))).nodup requestsDistinct
  · intro p member
    obtain ⟨b,bmem,same,binding⟩ := metadata p (List.mem_filter.mp member).1
    refine ⟨b,?_,same,?_⟩
    · rw [(Singular.foldAccepted_pending root).1]
      exact List.mem_filter.mpr ⟨bmem,by simpa [same] using (List.mem_filter.mp member).2⟩
    · change insertionBinding Law.standard {w with economic} b.request p.envelope = true
      rw [bindingEq]
      exact binding
  · intro b member
    rw [(Singular.foldAccepted_pending root).1] at member
    obtain ⟨p,pmem,same⟩ := back b (List.mem_filter.mp member).1
    exact ⟨p,List.mem_filter.mpr ⟨pmem,by simpa [same] using (List.mem_filter.mp member).2⟩,same⟩
  · intro b member
    rw [(Singular.foldAccepted_pending root).1] at member
    change registrationBookingRefusal economic.registry.config b = none
    rw [config]
    exact registrations b (List.mem_filter.mp member).1
  · intro b member
    rw [(Singular.foldAccepted_pending root).2] at member
    have shape := terminations b (List.mem_filter.mp member).1
    change terminationExactContents economic.registry.config b.request = true ∧ _
    rw [config]
    exact shape

theorem length_le_one_of_nodup_unique {α : Type} (xs : List α) (distinct : xs.Nodup)
    (unique : ∀ a ∈ xs, ∀ b ∈ xs, a = b) : xs.length ≤ 1 := by
  cases xs with
  | nil => simp
  | cons a rest =>
    cases rest with
    | nil => simp
    | cons b tail =>
      have same := unique a (by simp) b (by simp)
      have ne := (List.nodup_cons.mp distinct).1
      exact False.elim (ne (by simp [same]))

theorem output_count_eq_kind (w : World) (hc : AppConsistent w) (key : Key) :
    (w.outputs.filter (fun o => o.envelope.control.key == key)).length = kindCount w.registry .active key := by
  have distinct : w.outputs.Nodup := List.Pairwise.of_map (·.ref) (fun a b h eq => h (congrArg AppOutput.ref eq)) hc.2.1
  have outputBound : (w.outputs.filter (fun o => o.envelope.control.key == key)).length ≤ 1 := by
    apply length_le_one_of_nodup_unique _ (List.Pairwise.filter _ distinct)
    intro a ha b hb
    obtain ⟨ma,ka⟩ := List.mem_filter.mp ha
    obtain ⟨mb,kb⟩ := List.mem_filter.mp hb
    exact hc.2.2.2.1 a ma b mb (Or.inl ((beq_iff_eq.mp ka).trans (beq_iff_eq.mp kb).symm))
  have rootBound : kindCount w.registry .active key ≤ 1 := by
    have bound := hc.1.2.2.1 key
    simp only [kindCount,foldProjectedRegistry,List.filter_append,List.length_append] at bound
    unfold kindCount World.registry
    omega
  have presence : 0 < (w.outputs.filter (fun o => o.envelope.control.key == key)).length ↔ 0 < kindCount w.registry .active key := by
    constructor
    · intro positive
      obtain ⟨o,member⟩ := List.exists_mem_of_length_pos positive
      obtain ⟨omem,okey⟩ := List.mem_filter.mp member
      have shape := hc.2.2.1 o omem
      have held := hc.2.2.2.2.1.1 o omem
      have keyEq : o.registered.control.key = key := by rw [← shape.2.2.1]; exact beq_iff_eq.mp okey
      exact List.length_pos_of_mem (List.mem_filter.mpr ⟨held,by simp [rootHolding,keyEq]⟩)
    · intro positive
      obtain ⟨h,member⟩ := List.exists_mem_of_length_pos positive
      obtain ⟨hmem,hkey⟩ := List.mem_filter.mp member
      obtain ⟨o,omem,same⟩ := hc.2.2.2.2.1.2 h hmem
      have shape := hc.2.2.1 o omem
      have keyEq : h.key = key := by simp only [Bool.and_eq_true,beq_iff_eq] at hkey; exact hkey.1
      rw [← same] at keyEq
      have current : o.envelope.control.key = key := by simpa only [rootHolding,← shape.2.2.1] using keyEq
      exact List.length_pos_of_mem (List.mem_filter.mpr ⟨omem,by simp [current]⟩)
  omega

theorem foldRouting_quantities {world : Singular.World} {u : EconomicUtxo} {tx : EconomicTransaction} {result : Result}
    (accepted : foldRoutingRefusal world u tx result = none) :
    foldSameQuantities tx.singularMint (foldMint world.registry.config (foldMembers world tx)) = true := by
  set_option maxRecDepth 2048 in
    unfold foldRoutingRefusal at accepted
    simp only [bind,pure,Option.bind] at accepted
    repeat (split at accepted <;> try contradiction)
    all_goals simp_all [← Option.eq_none_iff_forall_ne_some]

theorem foldMint_key_sum (c : Config) (members : List FoldMember) (key : Key)
    (tags : ∀ b, FoldMember.termination b ∈ members → b.request.singularTags = [c.singularTag b.request.key]) :
    (((foldMint c members).filter (fun p => decide (p.1 = c.singularTag key))).map Prod.snd).sum =
      (((((members.map (foldLegacyRequest c)).filter (fun r => r.key == key)).map (·.edge)).map
        (fun edge => if edge == .insertActive then (1 : Int) else -1)).sum) := by
  induction members with
  | nil => rfl
  | cons m rest ih =>
    have tail := ih (fun b member => tags b (List.mem_cons_of_mem _ member))
    cases m with
    | registration b =>
      by_cases same : b.request.key = key <;> simp [foldMint,foldLegacyRequest,Config.singularTag,same] <;>
        simpa [foldMint,Config.singularTag,List.map_map] using tail
    | termination b =>
      have shape := tags b List.mem_cons_self
      by_cases same : b.request.key = key <;> simp [foldMint,foldLegacyRequest,shape,Config.singularTag,same] <;>
        simpa [foldMint,Config.singularTag,List.map_map] using tail

theorem folded_termination_result (w : World) (hc : AppConsistent w) (u : EconomicUtxo) (tx : EconomicTransaction)
    (after : Singular.World) (accepted : Singular.foldAccepted w.economic u tx = .ok after)
    (b : TerminationBooking) (selected : FoldMember.termination b ∈ foldMembers w.economic tx) :
    trieGet after.registry.trie b.request.key = .known .terminal ∧
      (((tx.singularMint.filter (fun p => p.1 == w.registry.config.singularTag b.request.key)).map Prod.snd).sum = -1) := by
  obtain ⟨_,result,registry,routing,effect⟩ := Singular.foldAccepted_checks accepted
  have pending := (Singular.foldMembers_termination selected).1
  have active := pending_key_active w hc b pending
  have edges : ∀ r ∈ (foldMembers w.economic tx).map (foldLegacyRequest w.registry.config), r.edge = .insertActive ∨ r.edge = .updateTerminal := by
    intro r member
    obtain ⟨m,hm,rfl⟩ := List.mem_map.mp member
    cases m <;> simp [foldLegacyRequest]
  have present : Edge.updateTerminal ∈ (((foldMembers w.economic tx).map (foldLegacyRequest w.registry.config)).filter (fun r => r.key == b.request.key)).map (·.edge) := by
    apply List.mem_map.mpr
    refine ⟨foldLegacyRequest w.registry.config (.termination b),List.mem_filter.mpr ⟨List.mem_map.mpr ⟨.termination b,selected,rfl⟩,?_⟩,rfl⟩
    simp [foldLegacyRequest]
  have keyCases := (foldActions_key b.request.key _ _ _ (Singular.foldBatch_inv _ _ _ registry).2 edges).2
  have final : trieGet result.state.trie b.request.key = .known .terminal ∧
      (((foldMembers w.economic tx).map (foldLegacyRequest w.registry.config)).filter (fun r => r.key == b.request.key)).map (·.edge) = [.updateTerminal] := by
    unfold World.registry at present ⊢
    rcases keyCases with ⟨empty,_,_⟩ | ⟨one,unknown,_,_⟩ | ⟨one,_,terminal,_⟩ | ⟨two,unknown,_,_⟩
    · rw [empty] at present; cases present
    · change trieGet w.registry.trie b.request.key = .unknown at unknown
      rw [active] at unknown; contradiction
    · exact ⟨terminal,one⟩
    · change trieGet w.registry.trie b.request.key = .unknown at unknown
      rw [active] at unknown; contradiction
  refine ⟨by rw [effect]; exact final.1,?_⟩
  have shape := consistent_pending_shape w hc
  have tags : ∀ t, FoldMember.termination t ∈ foldMembers w.economic tx → t.request.singularTags = [w.registry.config.singularTag t.request.key] := by
    intro t member
    exact (shape t (Singular.foldMembers_termination member).1).1
  have expected := foldMint_key_sum w.registry.config (foldMembers w.economic tx) b.request.key tags
  rw [final.2] at expected
  have minted : (w.registry.config.singularTag b.request.key,(-1 : Int)) ∈ foldMint w.registry.config (foldMembers w.economic tx) := by
    apply List.mem_flatMap.mpr
    exact ⟨.termination b,selected,by simp [tags b selected]⟩
  have quantities := foldRouting_quantities routing
  have equal := List.all_eq_true.mp quantities (w.registry.config.singularTag b.request.key)
    (List.mem_append_right _ (List.mem_map.mpr ⟨_,minted,rfl⟩))
  have predicates : (fun p : SingularTag × Int => p.1 == w.registry.config.singularTag b.request.key) =
      (fun p => decide (p.1 = w.registry.config.singularTag b.request.key)) := by
    funext p; apply Bool.eq_iff_iff.mpr; simp
  rw [predicates]
  have equality := of_decide_eq_true equal
  exact equality.trans expected

end OpenDatumApplication.ProofSupport
