import OpenDatumApplication.Model
import OpenDatumApplication.Driver
import OpenDatumApplication.ProofSupport

/-! # The open-datum application's intended statements and inversions

Thirty-five declarations, all proved over the root model at main a0770318. An insertion names its envelope datum: `bookInsert_inversion` states it, `selectRow_requires_named_datum` re-checks it at selection, and `insertion_holding_inline` proves the reached delivery carries it inline. Only captured #print axioms results establish each declaration's proof status; the generated ledger computes it from the build.

Three kinds of statement, kept apart:

* **inversions** are exact and hold over ANY `World`: they say what each
  accepted branch of the law is, and nothing more;
* **invariant obligations** say the consistency `AppConsistent` holds at every
  genesis and is preserved by every accepted action, hence by every reached
  world (`reachable_consistent`);
* **required properties** that depend on that consistency take `Reachable w`.
  Over unrestricted worlds they are false — an arbitrary `World` value can hold
  two outputs of one key, or one output occurrence twice — and those
  counterexamples are published in the specification, not hidden. The
  invariant's own preservation obligations are stated over every consistent
  world, not only reached ones, so its domain excludes those worlds by the
  occurrence and key clauses, never by assuming reachability.
  Properties that are guards of a single step hold over any world and say so. -/

namespace OpenDatumApplication.Statements

open Singular
open OpenDatumApplication

/-! ## Public inversions (any world) -/

/-- An accepted insertion booking is exactly: every guard holds, including that
the application and the envelope name the actual registry state asset, and the
booked request is appended with its envelope. Nothing else changes. -/
theorem bookInsert_inversion (w w' : World) (r : Request) (e : Envelope)
    (sigs : List Nat) :
    bookInsertStep Law.standard w r e sigs = .ok w' ↔
      (r.edge = .insertActive ∧ w.registry.config.applicationPolicy = w.app.policy ∧
        w.app.registry = w.registryAsset ∧ e.control.version = envelopeVersion ∧
        e.control.registry = w.registryAsset ∧
        e.control.activePolicy = w.registry.config.activePolicy ∧ e.control.key = r.key ∧
        e.control.controller = r.owner ∧ e.control.controller ∈ sigs ∧
        r.output = destinationOf w.app e ∧ r.datum = some (envelopeHash e) ∧
        e.control.deposit = r.deposit ∧
        w' = { w with pending := w.pending ++ [⟨booked w.app r sigs, some e⟩] }) := by
  have bind_ok : ∀ {α β : Type} (x : Except String α) (f : α → Except String β) (b : β),
      x >>= f = Except.ok b → ∃ a, x = Except.ok a ∧ f a = Except.ok b := by
    intro α β x f b hx
    cases x with
    | error e =>
      first
        | exact Except.noConfusion hx
        | cases hx
        | (simp [bind, Except.bind] at hx)
    | ok a => exact ⟨a, rfl, hx⟩
  have bind_ok_intro : ∀ {α β : Type} {x : Except String α} {f : α → Except String β} {a : α}
      {b : β}, x = Except.ok a → f a = Except.ok b → x >>= f = Except.ok b := by
    intro α β x f a b hx hf
    subst hx
    exact hf
  have ens : ∀ (c : Bool) (why : String) (u : Unit), ensure c why = .ok u → c = true := by
    intro c why u hc
    cases c with
    | false =>
      first
        | exact Except.noConfusion hc
        | (simp [ensure] at hc)
    | true => rfl
  have ens_ok : ∀ (c : Bool) (why : String), c = true → ensure c why = Except.ok () := by
    intro c why hc
    subst hc
    rfl
  have ok_inj : ∀ {α : Type} {a b : α}, (Except.ok a : Except String α) = Except.ok b → a = b := by
    intro α a b hab
    first
      | (injection hab with h'; exact h')
      | (cases hab; rfl)
  have edge_sound : ∀ x y : Edge, (x == y) = true → x = y := by
    intro x y hxy
    first
      | exact eq_of_beq hxy
      | (cases x <;> cases y <;> first | rfl | exact absurd hxy (by decide))
  have hreg : ∀ b : Bool, (!Law.standard.checkRegistryAsset || b) = true → b = true := by
    intro b hb
    first
      | (cases b with
          | false => exact absurd hb (by decide)
          | true => rfl)
      | simpa [Law.standard] using hb
  have hreg_intro : ∀ b : Bool, b = true → (!Law.standard.checkRegistryAsset || b) = true := by
    intro b hb
    subst hb
    first
      | rfl
      | decide
      | simp [Law.standard]
  have beq_sound : ∀ a b : StateAsset, (a == b) = true → a = b := by
    intro a b hab
    first
      | exact eq_of_beq hab
      | (cases a
         cases b
         simp only [reduceBEq, Bool.and_eq_true, beq_iff_eq] at hab
         obtain ⟨h1, h2⟩ := hab
         subst h1
         subst h2
         rfl)
      | (cases a
         cases b
         simp_all [reduceBEq])
  have beq_refl : ∀ a : StateAsset, (a == a) = true := by
    intro a
    first
      | exact beq_self_eq_true a
      | (cases a
         simp [reduceBEq])
      | (cases a
         rfl)
  constructor
  · intro h
    first
      | unfold bookInsertStep at h
      | simp only [bookInsertStep] at h
      | skip
    obtain ⟨_, e1, h⟩ := bind_ok _ _ _ h
    obtain ⟨_, e2, h⟩ := bind_ok _ _ _ h
    obtain ⟨_, e3, h⟩ := bind_ok _ _ _ h
    obtain ⟨_, e4, h⟩ := bind_ok _ _ _ h
    obtain ⟨_, e5, h⟩ := bind_ok _ _ _ h
    obtain ⟨_, e6, h⟩ := bind_ok _ _ _ h
    obtain ⟨_, e7, h⟩ := bind_ok _ _ _ h
    obtain ⟨_, e8, h⟩ := bind_ok _ _ _ h
    obtain ⟨_, e9, h⟩ := bind_ok _ _ _ h
    obtain ⟨_, e10, h⟩ := bind_ok _ _ _ h
    obtain ⟨_, e11, h⟩ := bind_ok _ _ _ h
    obtain ⟨_, e12, h⟩ := bind_ok _ _ _ h
    exact ⟨edge_sound _ _ (ens _ _ _ e1), eq_of_beq (ens _ _ _ e2),
      beq_sound _ _ (hreg _ (ens _ _ _ e3)), eq_of_beq (ens _ _ _ e4),
      beq_sound _ _ (hreg _ (ens _ _ _ e5)), eq_of_beq (ens _ _ _ e6),
      eq_of_beq (ens _ _ _ e7), eq_of_beq (ens _ _ _ e8), List.contains_iff.1 (ens _ _ _ e9),
      eq_of_beq (ens _ _ _ e10), eq_of_beq (ens _ _ _ e11), eq_of_beq (ens _ _ _ e12),
      (ok_inj h).symm⟩
  · rintro ⟨h1, h2, h3, h4, h5, h6, h7, h8, h9, h10, hnd, h11, hw⟩
    subst hw
    first
      | unfold bookInsertStep
      | simp only [bookInsertStep]
      | skip
    refine bind_ok_intro (ens_ok _ _ ?_) ?_
    · first
        | (rw [h1]; done)
        | (rw [h1]; rfl)
        | (rw [h1]; decide)
        | simp [h1]
    refine bind_ok_intro (ens_ok _ _ ?_) ?_
    · exact beq_iff_eq.2 h2
    refine bind_ok_intro (ens_ok _ _ ?_) ?_
    · exact hreg_intro _ (by
        first
          | (rw [h3]; exact beq_refl _)
          | (rw [h3]; done)
          | simp [h3, beq_refl])
    refine bind_ok_intro (ens_ok _ _ ?_) ?_
    · exact beq_iff_eq.2 h4
    refine bind_ok_intro (ens_ok _ _ ?_) ?_
    · exact hreg_intro _ (by
        first
          | (rw [h5]; exact beq_refl _)
          | (rw [h5]; done)
          | simp [h5, beq_refl])
    refine bind_ok_intro (ens_ok _ _ ?_) ?_
    · exact beq_iff_eq.2 h6
    refine bind_ok_intro (ens_ok _ _ ?_) ?_
    · exact beq_iff_eq.2 h7
    refine bind_ok_intro (ens_ok _ _ ?_) ?_
    · exact beq_iff_eq.2 h8
    refine bind_ok_intro (ens_ok _ _ ?_) ?_
    · exact List.contains_iff.2 h9
    refine bind_ok_intro (ens_ok _ _ ?_) ?_
    · exact beq_iff_eq.2 h10
    refine bind_ok_intro (ens_ok _ _ ?_) ?_
    · exact beq_iff_eq.2 hnd
    refine bind_ok_intro (ens_ok _ _ ?_) ?_
    · exact beq_iff_eq.2 h11
    rfl

/-- An accepted termination booking is exactly: the guards hold and the booked
request is appended; outputs, registry and mint are unchanged. -/
theorem bookTerminate_inversion (w w' : World) (r : Request) (ref : Nat)
    (sigs : List Nat) :
    bookTerminateStep w r ref sigs = .ok w' ↔
      ∃ o, r.edge = .updateTerminal ∧ w.registry.config.applicationPolicy = w.app.policy ∧
        outputAt w ref = some o ∧ o.address = appAddress w.app ∧ carriesKey o.assets r.key ∧
        o.envelope.control.key = r.key ∧ o.envelope.control.registry = w.registryAsset ∧
        r.owner = o.envelope.control.controller ∧ o.envelope.control.controller ∈ sigs ∧
        r.output = 0 ∧ w' = { w with pending := w.pending ++ [⟨booked w.app r sigs, none⟩] } := by
  have bind_ok : ∀ {α β : Type} (x : Except String α) (f : α → Except String β) (b : β),
      x >>= f = Except.ok b → ∃ a, x = Except.ok a ∧ f a = Except.ok b := by
    intro α β x f b hx
    cases x with
    | error e =>
      first
        | exact Except.noConfusion hx
        | cases hx
        | (simp [bind, Except.bind] at hx)
    | ok a => exact ⟨a, rfl, hx⟩
  have bind_ok_intro : ∀ {α β : Type} {x : Except String α} {f : α → Except String β} {a : α}
      {b : β}, x = Except.ok a → f a = Except.ok b → x >>= f = Except.ok b := by
    intro α β x f a b hx hf
    subst hx
    exact hf
  have ens : ∀ (c : Bool) (why : String) (u : Unit), ensure c why = .ok u → c = true := by
    intro c why u hc
    cases c with
    | false =>
      first
        | exact Except.noConfusion hc
        | (simp [ensure] at hc)
    | true => rfl
  have ens_ok : ∀ (c : Bool) (why : String), c = true → ensure c why = Except.ok () := by
    intro c why hc
    subst hc
    rfl
  have ok_inj : ∀ {α : Type} {a b : α}, (Except.ok a : Except String α) = Except.ok b → a = b := by
    intro α a b hab
    first
      | (injection hab with h'; exact h')
      | (cases hab; rfl)
  have edge_sound : ∀ x y : Edge, (x == y) = true → x = y := by
    intro x y hxy
    first
      | exact eq_of_beq hxy
      | (cases x <;> cases y <;> first | rfl | exact absurd hxy (by decide))
  have beq_sound : ∀ a b : StateAsset, (a == b) = true → a = b := by
    intro a b hab
    first
      | exact eq_of_beq hab
      | (cases a
         cases b
         simp only [reduceBEq, Bool.and_eq_true, beq_iff_eq] at hab
         obtain ⟨h1, h2⟩ := hab
         subst h1
         subst h2
         rfl)
      | (cases a
         cases b
         simp_all [reduceBEq])
  have beq_refl : ∀ a : StateAsset, (a == a) = true := by
    intro a
    first
      | exact beq_self_eq_true a
      | (cases a
         simp [reduceBEq])
      | (cases a
         rfl)
  constructor
  · intro h
    first
      | unfold bookTerminateStep at h
      | simp only [bookTerminateStep] at h
      | skip
    obtain ⟨_, e1, h⟩ := bind_ok _ _ _ h
    obtain ⟨_, e2, h⟩ := bind_ok _ _ _ h
    cases ho : outputAt w ref with
    | none =>
      first
        | (simp only [ho] at h; exact Except.noConfusion h)
        | (simp only [ho] at h)
        | (simp [ho] at h)
    | some o =>
      simp only [ho] at h
      obtain ⟨_, e3, h⟩ := bind_ok _ _ _ h
      obtain ⟨_, e4, h⟩ := bind_ok _ _ _ h
      obtain ⟨_, e5, h⟩ := bind_ok _ _ _ h
      obtain ⟨_, e6, h⟩ := bind_ok _ _ _ h
      obtain ⟨_, e7, h⟩ := bind_ok _ _ _ h
      obtain ⟨ga, gb⟩ := Bool.and_eq_true_iff.1 (ens _ _ _ e3)
      obtain ⟨gc, gd⟩ := Bool.and_eq_true_iff.1 (ens _ _ _ e4)
      exact ⟨o, edge_sound _ _ (ens _ _ _ e1), eq_of_beq (ens _ _ _ e2), rfl, eq_of_beq ga, gb,
        eq_of_beq gc, beq_sound _ _ gd, eq_of_beq (ens _ _ _ e5),
        List.contains_iff.1 (ens _ _ _ e6), eq_of_beq (ens _ _ _ e7), (ok_inj h).symm⟩
  · rintro ⟨o, h1, h2, ho, h3, h4, h5, h6, h7, h8, h9, hw⟩
    subst hw
    first
      | unfold bookTerminateStep
      | simp only [bookTerminateStep]
      | skip
    refine bind_ok_intro (ens_ok _ _ ?_) ?_
    · first
        | (rw [h1]; done)
        | (rw [h1]; rfl)
        | (rw [h1]; decide)
        | simp [h1]
    refine bind_ok_intro (ens_ok _ _ ?_) ?_
    · exact beq_iff_eq.2 h2
    simp only [ho]
    refine bind_ok_intro (ens_ok _ _ ?_) ?_
    · exact Bool.and_eq_true_iff.2 ⟨beq_iff_eq.2 h3, h4⟩
    refine bind_ok_intro (ens_ok _ _ ?_) ?_
    · exact Bool.and_eq_true_iff.2 ⟨beq_iff_eq.2 h5, by
        first
          | (rw [h6]; exact beq_refl _)
          | (rw [h6]; done)
          | simp [h6, beq_refl]⟩
    refine bind_ok_intro (ens_ok _ _ ?_) ?_
    · exact beq_iff_eq.2 h7
    refine bind_ok_intro (ens_ok _ _ ?_) ?_
    · exact List.contains_iff.2 h8
    refine bind_ok_intro (ens_ok _ _ ?_) ?_
    · exact beq_iff_eq.2 h9
    rfl

/-- The application certifies no other edge. -/
theorem bookOther_refused (w w' : World) (r : Request) (sigs : List Nat) :
    appStep w (.bookOther r sigs) ≠ .ok w' := by
  intro h
  first
    | exact Except.noConfusion h
    | (simp [appStep, appStepWith, bookOtherStep] at h)
    | cases h

/-- An accepted update is exactly: the controller signed, one proposed output
carries the token, at this contract, with the same control, the same assets and
at least the deposit; it replaces the spent output under a fresh reference. -/
theorem update_inversion (w w' : World) (ref : Nat) (succs : List Successor)
    (sigs : List Nat) :
    updateStep Law.standard w ref succs sigs = .ok w' ↔
      ∃ o s, outputAt w ref = some o ∧ o.envelope.control.controller ∈ sigs ∧
        succs.filter (fun x => carriesKey x.assets o.envelope.control.key) = [s] ∧
        s.address = appAddress w.app ∧ s.envelope.control = o.envelope.control ∧
        s.assets = o.assets ∧ o.envelope.control.deposit ≤ s.lovelace ∧
        w' = { w with outputs := (w.outputs.erase o) ++
                        [⟨w.nextRef, s.address, s.lovelace, s.assets, s.envelope⟩]
                    , nextRef := w.nextRef + 1 } := by
  have control_sound : ∀ a b : Control, (a == b) = true → a = b := by
    intro a b hab
    obtain ⟨v1, ⟨p1, n1⟩, ap1, k1, c1, d1⟩ := a
    obtain ⟨v2, ⟨p2, n2⟩, ap2, k2, c2, d2⟩ := b
    simp only [reduceBEq, Bool.and_eq_true, beq_iff_eq] at hab
    first
      | (simp only [hab]; done)
      | simp [hab]
      | simp_all
  have control_refl : ∀ a : Control, (a == a) = true := by
    intro a
    obtain ⟨v, ⟨p, n⟩, ap, k, c, d⟩ := a
    simp [reduceBEq]
  have bind_ok : ∀ {α β : Type} (x : Except String α) (f : α → Except String β) (b : β),
      x >>= f = Except.ok b → ∃ a, x = Except.ok a ∧ f a = Except.ok b := by
    intro α β x f b hx
    cases x with
    | error e =>
      first
        | exact Except.noConfusion hx
        | cases hx
        | (simp [bind, Except.bind] at hx)
    | ok a => exact ⟨a, rfl, hx⟩
  have bind_ok_intro : ∀ {α β : Type} {x : Except String α} {f : α → Except String β} {a : α}
      {b : β}, x = Except.ok a → f a = Except.ok b → x >>= f = Except.ok b := by
    intro α β x f a b hx hf
    subst hx
    exact hf
  have ens : ∀ (c : Bool) (why : String) (u : Unit), ensure c why = .ok u → c = true := by
    intro c why u hc
    cases c with
    | false =>
      first
        | exact Except.noConfusion hc
        | (simp [ensure] at hc)
    | true => rfl
  have ens_ok : ∀ (c : Bool) (why : String), c = true → ensure c why = Except.ok () := by
    intro c why hc
    subst hc
    rfl
  have ok_inj : ∀ {α : Type} {a b : α}, (Except.ok a : Except String α) = Except.ok b → a = b := by
    intro α a b hab
    first
      | (injection hab with h'; exact h')
      | (cases hab; rfl)
  have hupd : ∀ b : Bool, (!Law.standard.checkUpdateSigner || b) = true → b = true := by
    intro b hb
    first
      | (cases b with
          | false => exact absurd hb (by decide)
          | true => rfl)
      | simpa [Law.standard] using hb
  have hupd_intro : ∀ b : Bool, b = true → (!Law.standard.checkUpdateSigner || b) = true := by
    intro b hb
    subst hb
    first
      | rfl
      | decide
      | simp [Law.standard]
  constructor
  · intro h
    first
      | unfold updateStep at h
      | simp only [updateStep] at h
      | skip
    cases ho : outputAt w ref with
    | none =>
      first
        | (simp only [ho] at h; exact Except.noConfusion h)
        | (simp only [ho] at h)
        | (simp [ho] at h)
    | some o =>
      simp only [ho] at h
      obtain ⟨_, e1, h⟩ := bind_ok _ _ _ h
      cases hcar : List.filter (fun x => carriesKey x.assets o.envelope.control.key) succs with
      | nil =>
        first
          | (simp only [hcar] at h; exact Except.noConfusion h)
          | (simp only [hcar] at h)
          | (simp [hcar] at h)
      | cons s rest =>
        cases rest with
        | cons s2 rest2 =>
          first
            | (simp only [hcar] at h; exact Except.noConfusion h)
            | (simp only [hcar] at h)
            | (simp [hcar] at h)
        | nil =>
          simp only [hcar] at h
          obtain ⟨_, e2, h⟩ := bind_ok _ _ _ h
          obtain ⟨_, e3, h⟩ := bind_ok _ _ _ h
          obtain ⟨_, e4, h⟩ := bind_ok _ _ _ h
          obtain ⟨_, e5, h⟩ := bind_ok _ _ _ h
          have hsig : o.envelope.control.controller ∈ sigs :=
            List.contains_iff.1 (hupd _ (ens _ _ _ e1))
          have haddr : s.address = appAddress w.app := eq_of_beq (ens _ _ _ e2)
          have hctrl : s.envelope.control = o.envelope.control := control_sound _ _ (ens _ _ _ e3)
          have hassets : s.assets = o.assets := by
            first
              | exact eq_of_beq (ens _ _ _ e4)
              | exact beq_iff_eq.1 (ens _ _ _ e4)
              | simpa using ens _ _ _ e4
          have hdep : o.envelope.control.deposit ≤ s.lovelace := of_decide_eq_true (ens _ _ _ e5)
          exact ⟨o, s, rfl, hsig, hcar, haddr, hctrl, hassets, hdep, (ok_inj h).symm⟩
  · rintro ⟨o, s, ho, hsig, hcar, haddr, hctrl, hassets, hdep, hw⟩
    subst hw
    first
      | unfold updateStep
      | simp only [updateStep]
      | skip
    simp only [ho]
    refine bind_ok_intro (ens_ok _ _ ?_) ?_
    · exact hupd_intro _ (List.contains_iff.2 hsig)
    simp only [hcar]
    refine bind_ok_intro (ens_ok _ _ ?_) ?_
    · exact beq_iff_eq.2 haddr
    refine bind_ok_intro (ens_ok _ _ ?_) ?_
    · first
        | (rw [hctrl]; exact control_refl _)
        | (rw [hctrl]; done)
        | simp [hctrl, control_refl]
    refine bind_ok_intro (ens_ok _ _ ?_) ?_
    · first
        | exact beq_iff_eq.2 hassets
        | (rw [hassets]; exact beq_self_eq_true _)
        | simp [hassets]
    refine bind_ok_intro (ens_ok _ _ ?_) ?_
    · exact decide_eq_true hdep
    rfl

/-- An accepted fold is exactly: the selected rows are the ones `selectRow`
chooses, the registry's `foldBatch` accepts their requests with result `t`, the
whole payment duty of those rows settles against the outputs and the created
deliveries, and the world moves to the registry's state, drops exactly the spent
outputs and folded bookings, adds the created outputs and keeps `t.mint`. -/
theorem fold_inversion (w w' : World) (sel : List (Edge × Key)) (outs : List TxOutput)
    (t : Result) :
    foldEffect Law.standard w sel outs = .ok (w', t) ↔
      ∃ rows, sel.mapM (selectRow Law.standard w) = .ok rows ∧
        foldBatch w.registry (rows.map (·.pending.request)) = .ok t ∧
        settle (foldPayments rows)
          (outs ++ (createdOutputs w.app w.nextRef rows).map (deliveryOf w.app)) = none ∧
        w' = { w with registry := t.state
                    , outputs := (w.outputs.filter fun o => !(rows.filterMap (·.spent)).contains o) ++
                        createdOutputs w.app w.nextRef rows
                    , pending := w.pending.filter fun p => !(rows.map (·.pending)).contains p
                    , nextRef := w.nextRef + (createdOutputs w.app w.nextRef rows).length
                    , lastMint := t.mint } := by
  have bind_ok : ∀ {α β : Type} (x : Except String α) (f : α → Except String β) (b : β),
      x >>= f = Except.ok b → ∃ a, x = Except.ok a ∧ f a = Except.ok b := by
    intro α β x f b hx
    cases x with
    | error e =>
      first
        | exact Except.noConfusion hx
        | cases hx
        | (simp [bind, Except.bind] at hx)
    | ok a => exact ⟨a, rfl, hx⟩
  have bind_ok_intro : ∀ {α β : Type} {x : Except String α} {f : α → Except String β} {a : α}
      {b : β}, x = Except.ok a → f a = Except.ok b → x >>= f = Except.ok b := by
    intro α β x f a b hx hf
    subst hx
    exact hf
  have ok_inj : ∀ {α : Type} {a b : α}, (Except.ok a : Except String α) = Except.ok b → a = b := by
    intro α a b hab
    first
      | (injection hab with h'; exact h')
      | (cases hab; rfl)
  constructor
  · intro h
    first
      | unfold foldEffect at h
      | simp only [foldEffect] at h
      | skip
    obtain ⟨rows, hrows, h⟩ := bind_ok _ _ _ h
    obtain ⟨t0, ht, h⟩ := bind_ok _ _ _ h
    first
      | simp only at h
      | skip
    cases hs : settleFold Law.standard rows
        (outs ++ (createdOutputs w.app w.nextRef rows).map (deliveryOf w.app)) with
    | some why =>
      first
        | (simp only [hs] at h; exact Except.noConfusion h)
        | (simp only [hs] at h)
        | (rw [hs] at h; exact Except.noConfusion h)
    | none =>
      first
        | simp only [hs] at h
        | rw [hs] at h
      obtain ⟨hw, ht0⟩ := Prod.mk.inj (ok_inj h)
      subst ht0
      first
        | exact ⟨rows, hrows, ht, hs, hw.symm⟩
        | exact ⟨rows, hrows, ht, by simpa [settleFold, Law.standard] using hs, hw.symm⟩
  · rintro ⟨rows, hrows, ht, hs, hw⟩
    subst hw
    first
      | unfold foldEffect
      | simp only [foldEffect]
      | skip
    refine bind_ok_intro hrows ?_
    refine bind_ok_intro ht ?_
    have hs' : settleFold Law.standard rows
        (outs ++ (createdOutputs w.app w.nextRef rows).map (deliveryOf w.app)) = none := by
      first
        | exact hs
        | simpa [settleFold, Law.standard] using hs
    first
      | (simp only [hs']; done)
      | (simp only [hs']; rfl)
      | (simp only; rw [hs']; rfl)
      | (simp only [hs'])

/-- The application step of a fold is the fold's world. -/
theorem appStep_fold (w : World) (sel : List (Edge × Key)) (outs : List TxOutput) :
    appStep w (.fold sel outs) = (foldEffect Law.standard w sel outs).map (·.1) := by
  first
    | rfl
    | simp [appStep, appStepWith]

/-- An accepted reject is exactly the registry's reject of the booked request,
its refund settled; application outputs are untouched. -/
theorem reject_inversion (w w' : World) (edge : Edge) (key : Key) (outs : List TxOutput) :
    rejectStep w edge key outs = .ok w' ↔
      ∃ p t, pendingOf w edge key = some p ∧ exitStep w.registry .reject p.request = .ok t ∧
        settle (obligations .reject p.request) outs = none ∧
        w' = { w with registry := t.state, pending := w.pending.erase p, lastMint := t.mint } := by
  have bind_ok : ∀ {α β : Type} (x : Except String α) (f : α → Except String β) (b : β),
      x >>= f = Except.ok b → ∃ a, x = Except.ok a ∧ f a = Except.ok b := by
    intro α β x f b hx
    cases x with
    | error e =>
      first
        | exact Except.noConfusion hx
        | cases hx
        | (simp [bind, Except.bind] at hx)
    | ok a => exact ⟨a, rfl, hx⟩
  have bind_ok_intro : ∀ {α β : Type} {x : Except String α} {f : α → Except String β} {a : α}
      {b : β}, x = Except.ok a → f a = Except.ok b → x >>= f = Except.ok b := by
    intro α β x f a b hx hf
    subst hx
    exact hf
  have ok_inj : ∀ {α : Type} {a b : α}, (Except.ok a : Except String α) = Except.ok b → a = b := by
    intro α a b hab
    first
      | (injection hab with h'; exact h')
      | (cases hab; rfl)
  constructor
  · intro h
    first
      | unfold rejectStep at h
      | simp only [rejectStep] at h
      | skip
    cases hp : pendingOf w edge key with
    | none =>
      first
        | (simp only [hp] at h; exact Except.noConfusion h)
        | (simp only [hp] at h)
        | (simp [hp] at h)
    | some p =>
      simp only [hp] at h
      obtain ⟨t, ht, h⟩ := bind_ok _ _ _ h
      cases hs : settle (obligations .reject p.request) outs with
      | some why =>
        first
          | (simp only [hs] at h; exact Except.noConfusion h)
          | (simp only [hs] at h)
          | (simp [hs] at h)
      | none =>
        simp only [hs] at h
        exact ⟨p, t, rfl, ht, hs, (ok_inj h).symm⟩
  · rintro ⟨p, t, hp, ht, hs, hw⟩
    subst hw
    first
      | unfold rejectStep
      | simp only [rejectStep]
      | skip
    simp only [hp]
    refine bind_ok_intro ht ?_
    first
      | (simp only [hs]; done)
      | (simp only [hs]; rfl)
      | (split <;> simp_all)

/-- No withdrawal is ever accepted. -/
theorem withdraw_inversion (w w' : World) (ref : Nat) (outs : List TxOutput) :
    withdrawStep w ref outs ≠ .ok w' := by
  intro h
  first
    | (unfold withdrawStep at h; split at h <;> exact Except.noConfusion h)
    | (simp only [withdrawStep] at h; split at h <;> exact Except.noConfusion h)
    | (unfold withdrawStep at h
       cases ho : outputAt w ref <;> rw [ho] at h <;> exact Except.noConfusion h)
    | (cases ho : outputAt w ref <;> simp [withdrawStep, ho] at h)

/-! ## The consistency of reached worlds -/

/-- A genesis world is consistent. -/
theorem genesis_consistent (app : App) (c : Config) (asset : StateAsset) :
    AppConsistent (genesis app c asset) := by
  refine ⟨?_, ?_, ?_, ?_, ?_⟩
  · first
      | (show Singular.Consistent
            { config := { c with root := rootOf [] }, trie := [], custody := [], held := [] }
         exact ⟨rfl,
           fun key => by simp [kindCount, trieGet],
           fun key => by simp [kindCount, trieGet],
           fun key => by simp [custodyCount, trieGet],
           fun key => by simp [custodyCount, trieGet],
           fun h0 hm _ => absurd hm (by simp),
           fun c hm => absurd hm (by simp),
           fun c₁ h1 _ _ => absurd h1 (by simp)⟩)
      | (simp [genesis, Singular.Consistent, kindCount, custodyCount, trieGet])
  · first
      | exact List.nodup_nil
      | simp [genesis]
  · first
      | (intro o ho; nomatch ho)
      | (intro o ho; simp [genesis] at ho)
      | simp [genesis]
  · first
      | (intro o₁ h1; nomatch h1)
      | (intro o₁ h1; simp [genesis] at h1)
      | simp [genesis]
  · first
      | (intro p hp; nomatch hp)
      | (intro p hp; simp [genesis] at hp)
      | simp [genesis]

/-- Every accepted action of every constructor preserves consistency. -/
theorem appStep_preserves_consistent (w w' : World) (a : AppAction) :
    AppConsistent w → appStep w a = .ok w' → AppConsistent w' := by
  intro hc h
  cases a with
  | bookInsert r e sigs =>
    obtain ⟨hedge, _, _, _, hreg2, _, hkey, _, _, hout, _, hdep, hw⟩ :=
      (bookInsert_inversion w w' r e sigs).1 h
    subst hw
    obtain ⟨h1, h2, h3, h4, h5⟩ := hc
    refine ⟨h1, h2, h3, h4, ?_⟩
    intro p hp
    rcases List.mem_append.1 hp with hold | hnew
    · exact h5 p hold
    · rw [List.mem_singleton.1 hnew]
      exact Or.inl ⟨hedge, e, rfl, hout, hdep, hkey, hreg2⟩
  | bookTerminate r ref sigs =>
    obtain ⟨_, hedge, _, _, _, _, _, _, _, _, _, hw⟩ :=
      (bookTerminate_inversion w w' r ref sigs).1 h
    subst hw
    obtain ⟨h1, h2, h3, h4, h5⟩ := hc
    refine ⟨h1, h2, h3, h4, ?_⟩
    intro p hp
    rcases List.mem_append.1 hp with hold | hnew
    · exact h5 p hold
    · rw [List.mem_singleton.1 hnew]
      exact Or.inr ⟨hedge, rfl⟩
  | bookOther r sigs => exact absurd h (bookOther_refused w w' r sigs)
  | update ref succs sigs =>
    change updateStep Law.standard w ref succs sigs = .ok w' at h
    obtain ⟨o, s, ho, _, _, haddr, hctrl, hassets, hdep, hw⟩ :=
      (update_inversion w w' ref succs sigs).1 h
    subst hw
    exact ProofSupport.update_consistent_core w hc o s (ProofSupport.outputAt_mem w ref o ho)
      haddr hctrl hassets hdep
  | fold sel outs =>
    rw [appStep_fold] at h
    cases hf : foldEffect Law.standard w sel outs with
    | error e =>
      rw [hf] at h
      exact Except.noConfusion h
    | ok res =>
      rw [hf] at h
      have hres : res.1 = w' := ProofSupport.ok_inj h
      obtain ⟨w1, t⟩ := res
      obtain ⟨rows, hrows, ht, _, hw1⟩ := (fold_inversion w w1 sel outs t).1 hf
      subst hres
      subst hw1
      exact ProofSupport.fold_consistent_core w hc sel rows t hrows ht
  | reject edge key outs =>
    change rejectStep w edge key outs = .ok w' at h
    obtain ⟨p, t, _, ht, _, hw⟩ := (reject_inversion w w' edge key outs).1 h
    have hstate : t.state = w.registry := by
      first
        | (cases ht; rfl)
        | (simp only [exitStep, emptyResult] at ht
           injection ht with h'
           subst h'
           rfl)
    subst hw
    obtain ⟨h1, h2, h3, h4, h5⟩ := hc
    refine ⟨?_, h2, ?_, h4, ?_⟩
    · show Singular.Consistent t.state
      rw [hstate]
      exact h1
    · intro o ho
      obtain ⟨g1, g2, g3, g4, g5, g6⟩ := h3 o ho
      refine ⟨g1, g2, g3, g4, ?_, g6⟩
      show trieGet t.state.trie o.envelope.control.key = .known .active
      rw [hstate]
      exact g5
    · intro q hq
      exact h5 q (List.mem_of_mem_erase hq)
  | withdraw ref outs => exact absurd h (withdraw_inversion w w' ref outs)

/-- Every reached world is consistent. -/
theorem reachable_consistent (w : World) : Reachable w → AppConsistent w := by
  intro hr
  induction hr with
  | start app c asset => exact genesis_consistent app c asset
  | next _ hstep ih => exact appStep_preserves_consistent _ _ _ ih hstep

/-! ### Occurrences and the invariant boundary -/

/-- A consistent inventory holds each output occurrence once: its outputs and
their references are both duplicate-free. -/
theorem consistent_occurrences_distinct (w : World) :
    AppConsistent w → w.outputs.Nodup ∧ (w.outputs.map (·.ref)).Nodup := by
  intro hc
  obtain ⟨_, hrefs, _, _, _⟩ := hc
  first
    | exact ⟨List.Pairwise.of_map (·.ref) (fun _ _ hne heq => hne (congrArg (·.ref) heq)) hrefs,
        hrefs⟩
    | exact ⟨(List.pairwise_map.1 hrefs).imp (fun hne heq => hne (congrArg _ heq)), hrefs⟩

/-- Holding any live output a second time leaves the invariant: an inventory
with an identical duplicate occurrence is never consistent. This is the
previous invariant's counterexample, `[o, o]`, excluded at the boundary. -/
theorem duplicate_occurrence_outside_invariant (w : World) (o : AppOutput) :
    o ∈ w.outputs → ¬ AppConsistent { w with outputs := w.outputs ++ [o] } := by
  intro ho hc
  obtain ⟨_, hrefs, _, _, _⟩ := hc
  have hin : o.ref ∈ w.outputs.map (·.ref) := List.mem_map.2 ⟨o, ho, rfl⟩
  have hsplit : ((w.outputs.map (·.ref)) ++ [o.ref]).Nodup := by
    first
      | (dsimp only at hrefs; rw [List.map_append] at hrefs; exact hrefs)
      | (rw [List.map_append] at hrefs; exact hrefs)
      | (simpa [List.map_append] using hrefs)
  exact (List.nodup_append.1 hsplit).2.2 _ hin _ (List.mem_singleton_self _) rfl

/-- The executable observation the driver publishes at every step is exactly
the invariant; the registry conjunct goes through the root driver's own
`Singular.Driver.consistentB`. -/
theorem appConsistentB_iff (w : World) :
    OpenDatumApplication.Driver.appConsistentB w = true ↔ AppConsistent w := by
  unfold OpenDatumApplication.Driver.appConsistentB OpenDatumApplication.Driver.appConsistentBWith
  simp only [Bool.and_eq_true, List.all_eq_true]
  constructor
  · rintro ⟨⟨⟨⟨hreg, hrefs⟩, houts⟩, hpairs⟩, hpend⟩
    refine ⟨(ProofSupport.consistentB_iff _).1 hreg, ?_, ?_, ?_, ?_⟩
    · simp only [Bool.not_true, Bool.false_or, beq_iff_eq] at hrefs
      rw [← List.length_map (f := fun x : AppOutput => x.ref)] at hrefs
      exact (ProofSupport.eraseDups_length_iff _).1 hrefs
    · intro o ho
      have := houts o ho
      simp only [beq_iff_eq, decide_eq_true_eq] at this
      obtain ⟨⟨⟨⟨⟨h1, h2⟩, h3⟩, h4⟩, h5⟩, h6⟩ := this
      exact ⟨h1, h2, h3, h4, h5, h6⟩
    · intro o₁ h1 o₂ h2 hkr
      have := hpairs o₁ h1 o₂ h2
      by_cases he : o₁ = o₂
      · exact he
      · exfalso
        have hne : (o₁ == o₂) = false := by simpa using he
        rw [hne, Bool.or_false] at this
        rcases hkr with hk | hr
        · simp [hk] at this
        · simp [hr] at this
    · intro p hp
      have := hpend p hp
      revert this
      cases hE : p.request.edge <;> cases hv : p.envelope <;> simp
      all_goals (intros; simp_all)
  · rintro ⟨hreg, hrefs, houts, hpairs, hpend⟩
    refine ⟨⟨⟨⟨(ProofSupport.consistentB_iff _).2 hreg, ?_⟩, ?_⟩, ?_⟩, ?_⟩
    · simp only [Bool.not_true, Bool.false_or, beq_iff_eq]
      have := (ProofSupport.eraseDups_length_iff _).2 hrefs
      rw [List.length_map] at this
      exact this
    · intro o ho
      obtain ⟨h1, h2, h3, h4, h5, h6⟩ := houts o ho
      simp [h1, h2, h3, h4, h5, h6]
    · intro o₁ h1 o₂ h2
      by_cases hk : o₁.envelope.control.key = o₂.envelope.control.key
      · rw [hpairs o₁ h1 o₂ h2 (Or.inl hk)]
        simp
      · by_cases hr : o₁.ref = o₂.ref
        · rw [hpairs o₁ h1 o₂ h2 (Or.inr hr)]
          simp
        · simp [hk, hr]
    · intro p hp
      have := hpend p hp
      revert this
      cases hE : p.request.edge <;> cases hv : p.envelope <;> simp
      all_goals (intros; simp_all)

/-! ### Preservation, constructor by constructor

`bookOther` and `withdraw` accept nothing (`bookOther_refused`,
`withdraw_inversion`), so they have no preservation obligation. -/

theorem bookInsert_preserves_consistent (w w' : World) (r : Request) (e : Envelope)
    (sigs : List Nat) :
    AppConsistent w → appStep w (.bookInsert r e sigs) = .ok w' → AppConsistent w' := by
  intro hc h
  obtain ⟨hedge, _, _, _, hreg2, _, hkey, _, _, hout, _, hdep, hw⟩ :=
    (bookInsert_inversion w w' r e sigs).1 h
  subst hw
  obtain ⟨h1, h2, h3, h4, h5⟩ := hc
  refine ⟨h1, h2, h3, h4, ?_⟩
  intro p hp
  have hp' : p ∈ w.pending ∨ p = ⟨booked w.app r sigs, some e⟩ := by
    first
      | exact (List.mem_append.1 hp).imp id List.mem_singleton.1
      | (simp only [List.mem_append, List.mem_singleton] at hp; exact hp)
      | simpa using hp
  rcases hp' with hold | hnew
  · exact h5 p hold
  · subst hnew
    first
      | exact Or.inl ⟨hedge, e, rfl, hout, hdep, hkey, hreg2⟩
      | (left; exact ⟨hedge, e, rfl, hout, hdep, hkey, hreg2⟩)

theorem bookTerminate_preserves_consistent (w w' : World) (r : Request) (ref : Nat)
    (sigs : List Nat) :
    AppConsistent w → appStep w (.bookTerminate r ref sigs) = .ok w' → AppConsistent w' := by
  intro hc h
  obtain ⟨_, hedge, _, _, _, _, _, _, _, _, _, hw⟩ := (bookTerminate_inversion w w' r ref sigs).1 h
  subst hw
  obtain ⟨h1, h2, h3, h4, h5⟩ := hc
  refine ⟨h1, h2, h3, h4, ?_⟩
  intro p hp
  have hp' : p ∈ w.pending ∨ p = ⟨booked w.app r sigs, none⟩ := by
    first
      | exact (List.mem_append.1 hp).imp id List.mem_singleton.1
      | (simp only [List.mem_append, List.mem_singleton] at hp; exact hp)
      | simpa using hp
  rcases hp' with hold | hnew
  · exact h5 p hold
  · subst hnew
    first
      | exact Or.inr ⟨hedge, rfl⟩
      | (right; exact ⟨hedge, rfl⟩)

theorem update_preserves_consistent (w w' : World) (ref : Nat) (succs : List Successor)
    (sigs : List Nat) :
    AppConsistent w → appStep w (.update ref succs sigs) = .ok w' → AppConsistent w' := by
  intro hc h
  change updateStep Law.standard w ref succs sigs = .ok w' at h
  obtain ⟨o, s, ho, _, _, haddr, hctrl, hassets, hdep, hw⟩ :=
    (update_inversion w w' ref succs sigs).1 h
  have hnd : w.outputs.Nodup := (consistent_occurrences_distinct w hc).1
  subst hw
  obtain ⟨h1, h2, h3, h4, h5⟩ := hc
  have hmem : o ∈ w.outputs := by
    first
      | exact List.mem_of_find?_eq_some ho
      | exact List.mem_of_find?_eq_some (by simpa [outputAt] using ho)
  have hnot : o ∉ w.outputs.erase o := by
    first
      | exact hnd.not_mem_erase
      | exact List.Nodup.not_mem_erase hnd
      | (intro hm; exact (hnd.mem_erase_iff.1 hm).1 rfl)
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
    · first
        | exact List.Nodup.sublist (List.erase_sublist.map _) h2
        | exact List.Nodup.sublist (List.Sublist.map _ (List.erase_sublist _ _)) h2
    · first
        | exact List.nodup_singleton _
        | simp
    · intro a ha b hb hab
      obtain ⟨q, hq, hqa⟩ := List.mem_map.1 ha
      have hb' : b = w.nextRef := by
        first
          | exact List.mem_singleton.1 hb
          | simpa using hb
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

/-- Every fold, mixed insertion and termination selections included. -/
theorem fold_preserves_consistent (w w' : World) (sel : List (Edge × Key))
    (outs : List TxOutput) :
    AppConsistent w → appStep w (.fold sel outs) = .ok w' → AppConsistent w' := by
  intro hc h
  rw [appStep_fold] at h
  cases hf : foldEffect Law.standard w sel outs with
  | error e =>
    rw [hf] at h
    exact Except.noConfusion h
  | ok res =>
    rw [hf] at h
    have hres : res.1 = w' := ProofSupport.ok_inj h
    obtain ⟨w1, t⟩ := res
    obtain ⟨rows, hrows, ht, _, hw1⟩ := (fold_inversion w w1 sel outs t).1 hf
    subst hres
    subst hw1
    exact ProofSupport.fold_consistent_core w hc sel rows t hrows ht

theorem reject_preserves_consistent (w w' : World) (edge : Edge) (key : Key)
    (outs : List TxOutput) :
    AppConsistent w → appStep w (.reject edge key outs) = .ok w' → AppConsistent w' := by
  intro hc h
  change rejectStep w edge key outs = .ok w' at h
  obtain ⟨p, t, _, ht, _, hw⟩ := (reject_inversion w w' edge key outs).1 h
  have hstate : t.state = w.registry := by
    first
      | (cases ht; rfl)
      | (injection ht with h'; subst h'; rfl)
      | (simp only [exitStep, emptyResult] at ht
         injection ht with h'
         subst h'
         rfl)
  subst hw
  obtain ⟨h1, h2, h3, h4, h5⟩ := hc
  refine ⟨?_, h2, ?_, h4, ?_⟩
  · show Singular.Consistent t.state
    rw [hstate]
    exact h1
  · intro o ho
    obtain ⟨g1, g2, g3, g4, g5, g6⟩ := h3 o ho
    refine ⟨g1, g2, g3, g4, ?_, g6⟩
    show trieGet t.state.trie o.envelope.control.key = .known .active
    rw [hstate]
    exact g5
  · intro q hq
    have hq' : q ∈ w.pending := by
      first
        | exact List.mem_of_mem_erase hq
        | exact (List.erase_sublist).subset hq
        | exact (List.erase_sublist _ _).subset hq
    exact h5 q hq'

/-! ## Required properties -/

/-- Authority (any world): an accepted update was signed by the output's
controller. -/
theorem update_requires_controller (w w' : World) (ref : Nat) (succs : List Successor)
    (sigs : List Nat) (o : AppOutput) :
    outputAt w ref = some o → appStep w (.update ref succs sigs) = .ok w' →
      o.envelope.control.controller ∈ sigs := by
  intro ho h
  have bind_ok : ∀ {α β : Type} (x : Except String α) (f : α → Except String β) (b : β),
      x >>= f = Except.ok b → ∃ a, x = Except.ok a ∧ f a = Except.ok b := by
    intro α β x f b hx
    cases x with
    | error e =>
      first
        | exact Except.noConfusion hx
        | cases hx
        | (simp [bind, Except.bind] at hx)
    | ok a => exact ⟨a, rfl, hx⟩
  have ens : ∀ (c : Bool) (why : String) (u : Unit), ensure c why = .ok u → c = true := by
    intro c why u hc
    cases c with
    | false =>
      first
        | exact Except.noConfusion hc
        | (simp [ensure] at hc)
    | true => rfl
  have hupd : ∀ b : Bool, (!Law.standard.checkUpdateSigner || b) = true → b = true := by
    intro b hb
    first
      | (cases b with
          | false => exact absurd hb (by decide)
          | true => rfl)
      | simpa [Law.standard] using hb
  change updateStep Law.standard w ref succs sigs = .ok w' at h
  first
    | unfold updateStep at h
    | simp only [updateStep] at h
    | skip
  simp only [ho] at h
  obtain ⟨_, e1, _⟩ := bind_ok _ _ _ h
  exact List.contains_iff.1 (hupd _ (ens _ _ _ e1))

/-- Custody (reached worlds): after an accepted update the key's token is at this
contract under the same control with at least the protected deposit, every other
live output is unchanged, and the registry is untouched. -/
theorem update_preserves_custody (w w' : World) (ref : Nat) (succs : List Successor)
    (sigs : List Nat) (o : AppOutput) :
    Reachable w → outputAt w ref = some o → appStep w (.update ref succs sigs) = .ok w' →
      ∃ o', outputOfKey w' o.envelope.control.key = some o' ∧
        o'.envelope.control = o.envelope.control ∧ o'.assets = o.assets ∧
        o.envelope.control.deposit ≤ o'.lovelace ∧
        (∀ x ∈ w.outputs, x ≠ o → x ∈ w'.outputs) ∧ w'.registry = w.registry := by
  intro hr ho h
  have hc := reachable_consistent w hr
  change updateStep Law.standard w ref succs sigs = .ok w' at h
  obtain ⟨o0, s, ho0, _, _, haddr, hctrl, hassets, hdep, hw⟩ :=
    (update_inversion w w' ref succs sigs).1 h
  have hoo : o = o0 := Option.some.inj (ho.symm.trans ho0)
  subst hoo
  subst hw
  have hmem := ProofSupport.outputAt_mem w ref o ho
  have hnd := ProofSupport.outputs_nodup w hc
  have hnot : o ∉ w.outputs.erase o := by
    first
      | exact hnd.not_mem_erase
      | exact List.Nodup.not_mem_erase hnd
  refine ⟨⟨w.nextRef, s.address, s.lovelace, s.assets, s.envelope⟩, ?_, hctrl, hassets, hdep, ?_, rfl⟩
  · show (w.outputs.erase o ++ [(⟨w.nextRef, s.address, s.lovelace, s.assets, s.envelope⟩ : AppOutput)]).find?
        (fun x : AppOutput => x.address == appAddress w.app && carriesKey x.assets o.envelope.control.key) =
      some (⟨w.nextRef, s.address, s.lovelace, s.assets, s.envelope⟩ : AppOutput)
    rw [List.find?_append]
    have hnone : (w.outputs.erase o).find?
        (fun x => x.address == appAddress w.app && carriesKey x.assets o.envelope.control.key) =
          none := by
      rw [List.find?_eq_none]
      intro x hx hpx
      have hxm := List.mem_of_mem_erase hx
      simp only [Bool.and_eq_true, beq_iff_eq] at hpx
      have hxk := (ProofSupport.carries_iff w hc x hxm _).1 hpx.2
      have hxo : x = o := hc.2.2.2.1 x hxm o hmem (Or.inl hxk)
      subst hxo
      exact hnot hx
    rw [hnone]
    have hpred : (s.address == appAddress w.app && carriesKey s.assets o.envelope.control.key) =
        true := by
      simp only [Bool.and_eq_true, beq_iff_eq]
      refine ⟨haddr, ?_⟩
      rw [hassets]
      exact (ProofSupport.carries_iff w hc o hmem _).2 rfl
    simp [List.find?, hpred]
  · intro x hx hxo
    exact List.mem_append.2 (Or.inl ((List.mem_erase_of_ne hxo).2 hx))

/-- Payload freedom (any world): whether an update is accepted does not depend
on the successor's payload. -/
theorem update_payload_free (w : World) (ref : Nat) (s : Successor) (sigs : List Nat)
    (p : PlutusData) :
    (appStep w (.update ref [s] sigs)).isOk =
      (appStep w (.update ref [{ s with envelope := { s.envelope with payload := p } }] sigs)).isOk := by
  have bind_ok : ∀ {α β : Type} (x : Except String α) (f : α → Except String β) (b : β),
      x >>= f = Except.ok b → ∃ a, x = Except.ok a ∧ f a = Except.ok b := by
    intro α β x f b hx
    cases x with
    | error e =>
      first
        | exact Except.noConfusion hx
        | cases hx
        | (simp [bind, Except.bind] at hx)
    | ok a => exact ⟨a, rfl, hx⟩
  have bind_ok_intro : ∀ {α β : Type} {x : Except String α} {f : α → Except String β} {a : α}
      {b : β}, x = Except.ok a → f a = Except.ok b → x >>= f = Except.ok b := by
    intro α β x f a b hx hf
    subst hx
    exact hf
  have ens : ∀ (c : Bool) (why : String) (u : Unit), ensure c why = .ok u → c = true := by
    intro c why u hc
    cases c with
    | false =>
      first
        | exact Except.noConfusion hc
        | (simp [ensure] at hc)
    | true => rfl
  have ens_ok : ∀ (c : Bool) (why : String), c = true → ensure c why = Except.ok () := by
    intro c why hc
    subst hc
    rfl
  have isOk_iff : ∀ x : Except String World, x.isOk = true ↔ ∃ a, x = Except.ok a := by
    intro x
    cases x with
    | error e =>
      constructor
      · intro hx
        first
          | exact Bool.noConfusion hx
          | cases hx
          | (simp [Except.isOk, Except.toBool] at hx)
      · intro ⟨_, hx⟩
        exact Except.noConfusion hx
    | ok a => exact ⟨fun _ => ⟨a, rfl⟩, fun _ => rfl⟩
  have fwd : ∀ (succ : Successor) (w1 : World),
      updateStep Law.standard w ref [succ] sigs = Except.ok w1 →
      ∃ o, outputAt w ref = some o ∧
        (!Law.standard.checkUpdateSigner || sigs.contains o.envelope.control.controller) = true ∧
        carriesKey succ.assets o.envelope.control.key = true ∧
        (succ.address == appAddress w.app) = true ∧
        (succ.envelope.control == o.envelope.control) = true ∧
        (succ.assets == o.assets) = true ∧
        decide (o.envelope.control.deposit ≤ succ.lovelace) = true := by
    intro succ w1 h
    first
      | unfold updateStep at h
      | simp only [updateStep] at h
      | skip
    cases ho : outputAt w ref with
    | none =>
      first
        | (simp only [ho] at h; exact Except.noConfusion h)
        | (simp only [ho] at h)
        | (simp [ho] at h)
    | some o =>
      simp only [ho] at h
      obtain ⟨_, e1, h⟩ := bind_ok _ _ _ h
      cases hc : carriesKey succ.assets o.envelope.control.key with
      | false =>
        first
          | (simp only [List.filter, hc] at h; exact Except.noConfusion h)
          | (simp only [List.filter, hc] at h)
          | (simp [List.filter, hc] at h)
      | true =>
        simp only [List.filter, hc] at h
        obtain ⟨_, e2, h⟩ := bind_ok _ _ _ h
        obtain ⟨_, e3, h⟩ := bind_ok _ _ _ h
        obtain ⟨_, e4, h⟩ := bind_ok _ _ _ h
        obtain ⟨_, e5, h⟩ := bind_ok _ _ _ h
        exact ⟨o, rfl, ens _ _ _ e1, hc, ens _ _ _ e2, ens _ _ _ e3, ens _ _ _ e4, ens _ _ _ e5⟩
  have bwd : ∀ succ : Successor,
      (∃ o, outputAt w ref = some o ∧
        (!Law.standard.checkUpdateSigner || sigs.contains o.envelope.control.controller) = true ∧
        carriesKey succ.assets o.envelope.control.key = true ∧
        (succ.address == appAddress w.app) = true ∧
        (succ.envelope.control == o.envelope.control) = true ∧
        (succ.assets == o.assets) = true ∧
        decide (o.envelope.control.deposit ≤ succ.lovelace) = true) →
      (updateStep Law.standard w ref [succ] sigs).isOk = true := by
    rintro succ ⟨o, ho, g1, hc, g2, g3, g4, g5⟩
    refine (isOk_iff _).2 ⟨{ w with
        outputs := (w.outputs.erase o) ++
          [{ ref := w.nextRef, address := succ.address, lovelace := succ.lovelace,
             assets := succ.assets, envelope := succ.envelope }]
        nextRef := w.nextRef + 1 }, ?_⟩
    first
      | unfold updateStep
      | simp only [updateStep]
      | skip
    simp only [ho]
    refine bind_ok_intro (ens_ok _ _ g1) ?_
    simp only [List.filter, hc]
    refine bind_ok_intro (ens_ok _ _ g2) ?_
    refine bind_ok_intro (ens_ok _ _ g3) ?_
    refine bind_ok_intro (ens_ok _ _ g4) ?_
    refine bind_ok_intro (ens_ok _ _ g5) ?_
    rfl
  change (updateStep Law.standard w ref [s] sigs).isOk =
    (updateStep Law.standard w ref [{ s with envelope := { s.envelope with payload := p } }]
      sigs).isOk
  apply Bool.eq_iff_iff.2
  constructor
  · intro hx
    obtain ⟨w1, h1⟩ := (isOk_iff _).1 hx
    have q := fwd s w1 h1
    first
      | exact bwd _ q
      | (obtain ⟨o, g0, g1, g2, g3, g4, g5, g6⟩ := q
         exact bwd _ ⟨o, g0, g1, g2, g3, g4, g5, g6⟩)
  · intro hx
    obtain ⟨w1, h1⟩ := (isOk_iff _).1 hx
    have q := fwd { s with envelope := { s.envelope with payload := p } } w1 h1
    first
      | exact bwd _ q
      | (obtain ⟨o, g0, g1, g2, g3, g4, g5, g6⟩ := q
         exact bwd _ ⟨o, g0, g1, g2, g3, g4, g5, g6⟩)

/-- An update (any world) leaves the registry and the booked requests unchanged. -/
theorem update_keeps_registry (w w' : World) (ref : Nat) (succs : List Successor)
    (sigs : List Nat) :
    appStep w (.update ref succs sigs) = .ok w' → w'.registry = w.registry ∧ w'.pending = w.pending := by
  intro h
  have bind_ok : ∀ {α β : Type} (x : Except String α) (f : α → Except String β) (b : β),
      x >>= f = Except.ok b → ∃ a, x = Except.ok a ∧ f a = Except.ok b := by
    intro α β x f b hx
    cases x with
    | error e =>
      first
        | exact Except.noConfusion hx
        | cases hx
        | (simp [bind, Except.bind] at hx)
    | ok a => exact ⟨a, rfl, hx⟩
  change updateStep Law.standard w ref succs sigs = .ok w' at h
  first
    | unfold updateStep at h
    | simp only [updateStep] at h
    | skip
  repeat' (first
    | exact Except.noConfusion h
    | (obtain ⟨_, _, h⟩ := bind_ok _ _ _ h)
    | (split at h)
    | (simp only at h))
  all_goals first
    | (injection h with h'; subst h'; exact ⟨rfl, rfl⟩)
    | (cases h; exact ⟨rfl, rfl⟩)
    | (subst h; exact ⟨rfl, rfl⟩)

/-- Registry identity (any world): an insertion is booked only when the
application and its envelope name the full state asset the world actually
carries. -/
theorem insertion_requires_registry_identity (w w' : World) (r : Request) (e : Envelope)
    (sigs : List Nat) :
    appStep w (.bookInsert r e sigs) = .ok w' →
      w.app.registry = w.registryAsset ∧ e.control.registry = w.registryAsset := by
  intro h
  have bind_ok : ∀ {α β : Type} (x : Except String α) (f : α → Except String β) (b : β),
      x >>= f = Except.ok b → ∃ a, x = Except.ok a ∧ f a = Except.ok b := by
    intro α β x f b hx
    cases x with
    | error e =>
      first
        | exact Except.noConfusion hx
        | cases hx
        | (simp [bind, Except.bind] at hx)
    | ok a => exact ⟨a, rfl, hx⟩
  have ens : ∀ (c : Bool) (why : String) (u : Unit), ensure c why = .ok u → c = true := by
    intro c why u hc
    cases c with
    | false =>
      first
        | exact Except.noConfusion hc
        | (simp [ensure] at hc)
    | true => rfl
  have hreg : ∀ b : Bool, (!Law.standard.checkRegistryAsset || b) = true → b = true := by
    intro b hb
    first
      | (cases b with
          | false => exact absurd hb (by decide)
          | true => rfl)
      | simpa [Law.standard] using hb
  have beq_sound : ∀ a b : StateAsset, (a == b) = true → a = b := by
    intro a b hab
    first
      | exact eq_of_beq hab
      | (cases a
         cases b
         simp only [reduceBEq, Bool.and_eq_true, beq_iff_eq] at hab
         obtain ⟨h1, h2⟩ := hab
         subst h1
         subst h2
         rfl)
      | (cases a
         cases b
         simp_all [reduceBEq])
  change bookInsertStep Law.standard w r e sigs = .ok w' at h
  first
    | unfold bookInsertStep at h
    | simp only [bookInsertStep] at h
    | skip
  repeat' (first
    | exact Except.noConfusion h
    | (obtain ⟨_, hx, h⟩ := bind_ok _ _ _ h
       have := ens _ _ _ hx
       clear hx)
    | (split at h)
    | (simp only at h))
  all_goals exact ⟨beq_sound _ _ (hreg _ ‹_›), beq_sound _ _ (hreg _ ‹_›)⟩

/-- Insertion binds (reached worlds): each output a fold creates holds exactly
its key's token, the envelope its booking's destination committed to — naming
the actual registry — and exactly the booking's deposit, which is the protected
deposit; the registry's leaf for the key is Active. -/
theorem insertion_binds_envelope (w w' : World) (sel : List (Edge × Key))
    (outs : List TxOutput) (t : Result) (key : Key) :
    Reachable w → foldEffect Law.standard w sel outs = .ok (w', t) →
      (.insertActive, key) ∈ sel →
      ∃ p e o, pendingOf w .insertActive key = some p ∧ p.envelope = some e ∧
        outputOfKey w' key = some o ∧ o.envelope = e ∧ o.address = appAddress w.app ∧
        o.assets = [((.active, key), 1)] ∧ p.request.output = destinationOf w.app e ∧
        e.control.registry = w.registryAsset ∧ e.control.deposit = p.request.deposit ∧
        o.lovelace = p.request.deposit ∧ trieGet w'.registry.trie key = .known .active := by
  intro hr h hsel
  have hc := reachable_consistent w hr
  obtain ⟨rows, hrows, ht, _, hw⟩ := (fold_inversion w w' sel outs t).1 h
  obtain ⟨_, hr2, _⟩ := ProofSupport.rows_spec w sel rows hrows
  obtain ⟨row, hrow, hx⟩ := hr2 _ hsel
  obtain ⟨hpend, hpm, hedge, hk, hcase⟩ := ProofSupport.selectRow_spec w _ row hx
  rcases hcase with ⟨_, _, e, henv, hout, hdep, hreg⟩ | ⟨he, _⟩
  · obtain ⟨o, ho, hoe, hoassets, hlove, haddr⟩ :=
      ProofSupport.createdOutputs_of_row w.app w.nextRef rows row e hrow hedge henv
    obtain ⟨_, _, hfresh, hkeys, _, _⟩ := ProofSupport.fold_shape w hc sel rows t hrows ht
    obtain ⟨hunk, hact, _, _, _, _⟩ := hfresh o ho
    have hek : e.control.key = key := by
      rcases hc.2.2.2.2 row.pending hpm with ⟨_, e', he', _, _, hek', _⟩ | ⟨he, _⟩
      · rw [henv] at he'
        have hee : e = e' := Option.some.inj he'
        subst hee
        rw [hek']
        exact hk
      · rw [hedge] at he
        simp at he
    have hok : o.envelope.control.key = key := by rw [hoe]; exact hek
    subst hw
    refine ⟨row.pending, e, o, hpend, henv, ?_, hoe, haddr, by rw [hoassets, hk], hout, hreg, hdep,
      hlove, by rw [← hok]; exact hact⟩
    show ((w.outputs.filter fun o => !(rows.filterMap (·.spent)).contains o) ++
        createdOutputs w.app w.nextRef rows).find?
        (fun x => x.address == appAddress w.app && carriesKey x.assets key) = some o
    rw [List.find?_append]
    have hnone : (w.outputs.filter fun o => !(rows.filterMap (·.spent)).contains o).find?
        (fun x => x.address == appAddress w.app && carriesKey x.assets key) = none := by
      rw [List.find?_eq_none]
      intro q hq hpq
      have hqm := (List.mem_filter.1 hq).1
      simp only [Bool.and_eq_true, beq_iff_eq] at hpq
      have hqk := (ProofSupport.carries_iff w hc q hqm _).1 hpq.2
      have hqa := (hc.2.2.1 q hqm).2.2.2.2.1
      rw [hqk, ← hok, hunk] at hqa
      exact absurd hqa (by decide)
    rw [hnone]
    cases hf : (createdOutputs w.app w.nextRef rows).find?
        (fun x => x.address == appAddress w.app && carriesKey x.assets key) with
    | none =>
      have := List.find?_eq_none.1 hf o ho
      simp only [Bool.and_eq_true, beq_iff_eq, not_and] at this
      exact absurd ((ProofSupport.carriesKey_single _ _).2 hk) (by
        rw [← hoassets]
        exact this haddr)
    | some x =>
      have hxm := List.mem_of_find?_eq_some hf
      have hpx := List.find?_some hf
      simp only [Bool.and_eq_true, beq_iff_eq] at hpx
      obtain ⟨_, _, _, hxassets, _, _⟩ := hfresh x hxm
      rw [hxassets] at hpx
      have hxk := (ProofSupport.carriesKey_single _ _).1 hpx.2
      have hxo : x = o := ProofSupport.nodup_map_inj _ hkeys x hxm o ho (hxk.trans hok.symm)
      rw [hxo]
      rfl
  · simp at he

/-- Selection names the datum (any world): an insertion the fold selects names
its envelope datum, so a pending insertion naming none is refused before the
registry folds anything. -/
theorem selectRow_requires_named_datum (w : World) (key : Key) (row : FoldRow) :
    selectRow Law.standard w (.insertActive, key) = .ok row →
      row.pending.request.datum.isSome = true := by
  intro h
  exact ProofSupport.selectRow_insert_names_datum w key row h

/-- Inline delivery (reached worlds): after an accepted fold selecting an
insertion, the registry holds that key's active token at an output carrying its
datum inline — the envelope the booking named. -/
theorem insertion_holding_inline (w w' : World) (sel : List (Edge × Key))
    (outs : List TxOutput) (t : Result) (key : Key) :
    Reachable w → foldEffect Law.standard w sel outs = .ok (w', t) →
      (.insertActive, key) ∈ sel →
      ∃ h ∈ w'.registry.held, h.key = key ∧ h.kind = .active ∧ datumFormOf h.datum = .inline := by
  intro hr h hsel
  have hc := reachable_consistent w hr
  obtain ⟨rows, hrows, ht, _, hw⟩ := (fold_inversion w w' sel outs t).1 h
  obtain ⟨hr1, hr2, hE⟩ := ProofSupport.rows_spec w sel rows hrows
  obtain ⟨row, hrow, hx⟩ := hr2 _ hsel
  obtain ⟨_, _, hedge, hk, _⟩ := ProofSupport.selectRow_spec w _ row hx
  have hnd := ProofSupport.selectRow_insert_names_datum w key row hx
  obtain ⟨_, hacts⟩ := foldBatch_inv _ _ _ ht
  have hb : row.pending.request ∈ rows.map (·.pending.request) := List.mem_map.2 ⟨row, hrow, rfl⟩
  have hnoterm : ∀ c ∈ rows.map (·.pending.request), c.edge = .updateTerminal →
      c.key ≠ row.pending.request.key := by
    intro c hcm hce hck
    obtain ⟨row', hrow', rfl⟩ := List.mem_map.1 hcm
    obtain ⟨x, _, hx'⟩ := hr1 row' hrow'
    obtain ⟨_, _, hedge', hk', hcase⟩ := ProofSupport.selectRow_spec w x row' hx'
    rcases hcase with ⟨he, _⟩ | ⟨_, o, ho, _⟩
    · rw [he] at hedge'
      rw [hedge'] at hce
      exact absurd hce (by decide)
    · have hact := (ProofSupport.outputOfKey_consistent w hc _ o ho).2.2
      rw [← hk', hck] at hact
      obtain ⟨_, hkcase⟩ := ProofSupport.foldActions_key row.pending.request.key _ _ _ hacts hE
      have hrec := ProofSupport.edge_mem_key_record _ _ hb
      rw [hedge] at hrec
      rcases hkcase with ⟨e, _⟩ | ⟨_, l, _⟩ | ⟨e, _⟩ | ⟨_, l, _⟩
      · rw [e] at hrec
        exact absurd hrec (by simp)
      · rw [hact] at l
        exact absurd l (by decide)
      · rw [e] at hrec
        exact absurd hrec (by simp)
      · rw [hact] at l
        exact absurd l (by decide)
  obtain ⟨x, hxm, hxk, hxkind, hxd⟩ := ProofSupport.foldActions_insert_holding _ _ _ hacts hE
    row.pending.request hb hedge hnoterm
  subst hw
  refine ⟨x, hxm, by rw [hxk, hk], hxkind, ?_⟩
  rw [hxd]
  cases hdat : row.pending.request.datum <;> simp_all [datumFormOf]

/-- Termination booking (any world) leaves every application output, the
registry and the recorded mint where they were. -/
theorem bookTerminate_keeps_locked (w w' : World) (r : Request) (ref : Nat) (sigs : List Nat) :
    appStep w (.bookTerminate r ref sigs) = .ok w' →
      w'.outputs = w.outputs ∧ w'.registry = w.registry ∧ w'.lastMint = w.lastMint := by
  intro h
  have bind_ok : ∀ {α β : Type} (x : Except String α) (f : α → Except String β) (b : β),
      x >>= f = Except.ok b → ∃ a, x = Except.ok a ∧ f a = Except.ok b := by
    intro α β x f b hx
    cases x with
    | error e =>
      first
        | exact Except.noConfusion hx
        | cases hx
        | (simp [bind, Except.bind] at hx)
    | ok a => exact ⟨a, rfl, hx⟩
  change bookTerminateStep w r ref sigs = .ok w' at h
  first
    | unfold bookTerminateStep at h
    | simp only [bookTerminateStep] at h
    | skip
  repeat' (first
    | exact Except.noConfusion h
    | (obtain ⟨_, _, h⟩ := bind_ok _ _ _ h)
    | (split at h)
    | (simp only at h))
  all_goals first
    | (injection h with h'; subst h'; exact ⟨rfl, rfl, rfl⟩)
    | (cases h; exact ⟨rfl, rfl, rfl⟩)
    | (subst h; exact ⟨rfl, rfl, rfl⟩)

/-- Atomic release and burn (reached worlds): for every selected termination,
the output the fold spends is the key's live output, the fold's own mint is
exactly the registry's summed delta of the selected requests and holds exactly
`-1` of the key's active token, the key is Terminal after the fold, and the key
has no live output after it. Abstract mint only: concrete policy and burn-source
enforcement are later, compiled evidence. -/
theorem release_burns_atomically (w w' : World) (sel : List (Edge × Key))
    (outs : List TxOutput) (t : Result) (key : Key) :
    Reachable w → foldEffect Law.standard w sel outs = .ok (w', t) →
      (.updateTerminal, key) ∈ sel →
      ∃ o, outputOfKey w key = some o ∧ o ∉ w'.outputs ∧
        t.mint = w'.lastMint ∧
        (∃ rows, sel.mapM (selectRow Law.standard w) = .ok rows ∧
          assetSame t.mint (actualMint (rows.map (·.pending.request)))) ∧
        assetKind t.mint (.active, key) = -1 ∧
        trieGet w'.registry.trie key = .known .terminal ∧ outputOfKey w' key = none := by
  intro hr h hsel
  have hc := reachable_consistent w hr
  obtain ⟨rows, hrows, ht, _, hw⟩ := (fold_inversion w w' sel outs t).1 h
  obtain ⟨_, hr2, hE⟩ := ProofSupport.rows_spec w sel rows hrows
  obtain ⟨row, hrow, hx⟩ := hr2 _ hsel
  obtain ⟨_, _, hedge, hk, hcase⟩ := ProofSupport.selectRow_spec w _ row hx
  rcases hcase with ⟨he, _⟩ | ⟨_, o, ho, hsp⟩
  · simp at he
  · obtain ⟨hom, hok, hact⟩ := ProofSupport.outputOfKey_consistent w hc key o ho
    have hosp : o ∈ rows.filterMap (·.spent) := List.mem_filterMap.2 ⟨row, hrow, hsp⟩
    obtain ⟨_, hacts⟩ := foldBatch_inv _ _ _ ht
    obtain ⟨_, hkcase⟩ := ProofSupport.foldActions_key key _ _ _ hacts hE
    have hrec : Edge.updateTerminal ∈
        ((rows.map (·.pending.request)).filter (·.key == key)).map (·.edge) := by
      have := ProofSupport.edge_mem_key_record (rows.map (·.pending.request)) row.pending.request
        (List.mem_map.2 ⟨row, hrow, rfl⟩)
      rw [hedge, hk] at this
      exact this
    obtain ⟨_, _, hfresh, _, _, _⟩ := ProofSupport.fold_shape w hc sel rows t hrows ht
    rcases hkcase with ⟨e, _⟩ | ⟨_, l, _⟩ | ⟨_, _, lterm, hmint⟩ | ⟨_, l, _⟩
    · rw [e] at hrec
      exact absurd hrec (by simp)
    · rw [hact] at l
      exact absurd l (by decide)
    · subst hw
      refine ⟨o, ho, ?_, rfl, ⟨rows, hrows,
        ProofSupport.assetSame_of_eq _ _ (ProofSupport.foldActions_mint _ _ _ hacts)⟩, hmint, lterm,
        ?_⟩
      · intro hmem
        rcases List.mem_append.1 hmem with hkept | hnew
        · have := (List.mem_filter.1 hkept).2
          rw [List.contains_iff_mem.2 hosp] at this
          exact absurd this (by decide)
        · have hlt := (hc.2.2.1 o hom).2.2.2.2.2
          have hge := (ProofSupport.createdOutputs_ref_bounds _ _ _ o hnew).1
          omega
      · show ((w.outputs.filter fun o => !(rows.filterMap (·.spent)).contains o) ++
            createdOutputs w.app w.nextRef rows).find?
            (fun x => x.address == appAddress w.app && carriesKey x.assets key) = none
        rw [List.find?_eq_none]
        intro q hq hpq
        simp only [Bool.and_eq_true, beq_iff_eq] at hpq
        rcases List.mem_append.1 hq with hkept | hnew
        · obtain ⟨hqm, hqn⟩ := List.mem_filter.1 hkept
          have hqk := (ProofSupport.carries_iff w hc q hqm _).1 hpq.2
          have hqo : q = o := hc.2.2.2.1 q hqm o hom (Or.inl (hqk.trans hok.symm))
          subst hqo
          rw [List.contains_iff_mem.2 hosp] at hqn
          exact absurd hqn (by decide)
        · obtain ⟨hunk, _, _, hqassets, _, _⟩ := hfresh q hnew
          rw [hqassets] at hpq
          have hqk := (ProofSupport.carriesKey_single _ _).1 hpq.2
          rw [hqk, hact] at hunk
          exact absurd hunk (by decide)
    · rw [hact] at l
      exact absurd l (by decide)

/-- Only a fold removes an application output (any world): every other accepted
action keeps every live output's key held at this contract. -/
theorem only_fold_releases (w w' : World) (a : AppAction) :
    (∀ sel outs, a ≠ .fold sel outs) → appStep w a = .ok w' →
      ∀ o ∈ w.outputs, ∃ o' ∈ w'.outputs, o'.envelope.control = o.envelope.control ∧
        o'.assets = o.assets := by
  intro hnf h o ho
  cases a with
  | bookInsert r e sigs =>
    obtain ⟨_, _, _, _, _, _, _, _, _, _, _, _, hw⟩ := (bookInsert_inversion w w' r e sigs).1 h
    subst hw
    exact ⟨o, ho, rfl, rfl⟩
  | bookTerminate r ref sigs =>
    obtain ⟨_, _, _, _, _, _, _, _, _, _, _, hw⟩ := (bookTerminate_inversion w w' r ref sigs).1 h
    subst hw
    exact ⟨o, ho, rfl, rfl⟩
  | bookOther r sigs => exact absurd h (bookOther_refused w w' r sigs)
  | update ref succs sigs =>
    change updateStep Law.standard w ref succs sigs = .ok w' at h
    obtain ⟨o0, s, _, _, _, _, hctrl, hassets, _, hw⟩ := (update_inversion w w' ref succs sigs).1 h
    subst hw
    by_cases hx : o = o0
    · subst hx
      exact ⟨⟨w.nextRef, s.address, s.lovelace, s.assets, s.envelope⟩,
        List.mem_append.2 (Or.inr (List.mem_singleton_self _)), hctrl, hassets⟩
    · exact ⟨o, List.mem_append.2 (Or.inl ((List.mem_erase_of_ne hx).2 ho)), rfl, rfl⟩
  | fold sel outs => exact absurd rfl (hnf sel outs)
  | reject edge key outs =>
    change rejectStep w edge key outs = .ok w' at h
    obtain ⟨_, _, _, _, _, hw⟩ := (reject_inversion w w' edge key outs).1 h
    subst hw
    exact ⟨o, ho, rfl, rfl⟩
  | withdraw ref outs => exact absurd h (withdraw_inversion w w' ref outs)

/-- Additive settlement (any world, bound to the actual rows): an accepted fold's
selected rows are those `selectRow` chose; every output they spend was a live
output; its whole duty, the registry's payment for every selected request by its
edge and each spent output's own protected deposit to its own controller, is
paid, and every recipient — the same controller owed several floors included —
receives at least their sum. That the spent outputs are gone afterwards is
`fold_spent_disappears`, which needs a consistent world. -/
theorem fold_settles_additively (w w' : World) (sel : List (Edge × Key))
    (outs : List TxOutput) (t : Result) :
    foldEffect Law.standard w sel outs = .ok (w', t) →
      ∃ rows, sel.mapM (selectRow Law.standard w) = .ok rows ∧
        releases rows = (rows.filterMap (·.spent)).map (fun o =>
          { recipient := .owner o.envelope.control.controller
          , atLeast := o.envelope.control.deposit : Payment }) ∧
        (∀ o ∈ rows.filterMap (·.spent), o ∈ w.outputs) ∧
        ∀ rcp, owedTo rcp (foldPayments rows) ≤
          receivedBy rcp (outs ++ (createdOutputs w.app w.nextRef rows).map (deliveryOf w.app)) := by
  intro h
  obtain ⟨rows, hrows, _, hs, _⟩ := (fold_inversion w w' sel outs t).1 h
  refine ⟨rows, hrows, rfl, ?_, ProofSupport.settle_none_le _ _ hs⟩
  intro o ho
  obtain ⟨row, hr, hsp⟩ := List.mem_filterMap.1 ho
  obtain ⟨x, _, hx⟩ := (ProofSupport.rows_spec w sel rows hrows).1 row hr
  obtain ⟨_, _, _, _, hcase⟩ := ProofSupport.selectRow_spec w x row hx
  rcases hcase with ⟨_, hnone, _⟩ | ⟨_, o', ho', hsp'⟩
  · rw [hnone] at hsp
    exact Option.noConfusion hsp
  · rw [hsp] at hsp'
    have hoo : o = o' := Option.some.inj hsp'
    subst hoo
    exact (ProofSupport.outputOfKey_spec w _ _ ho').1

/-- Spent outputs disappear (consistent worlds): an accepted fold's selected rows
are those `selectRow` chose, and no output they spend is live afterwards. The
premise is consistency, not reachability: in a world whose next reference does
not exceed every live reference, the fold's own fresh outputs can recreate a
spent output. -/
theorem fold_spent_disappears (w w' : World) (sel : List (Edge × Key))
    (outs : List TxOutput) (t : Result) :
    AppConsistent w → foldEffect Law.standard w sel outs = .ok (w', t) →
      ∃ rows, sel.mapM (selectRow Law.standard w) = .ok rows ∧
        ∀ o ∈ rows.filterMap (·.spent), o ∉ w'.outputs := by
  intro hc h
  obtain ⟨rows, hrows, ht, _, hw⟩ := (fold_inversion w w' sel outs t).1 h
  refine ⟨rows, hrows, ?_⟩
  intro o ho hmem
  subst hw
  obtain ⟨_, hspent, _, _, _, _⟩ := ProofSupport.fold_shape w hc sel rows t hrows ht
  rcases List.mem_append.1 hmem with hkept | hnew
  · have := (List.mem_filter.1 hkept).2
    rw [List.contains_iff_mem.2 ho] at this
    exact absurd this (by decide)
  · have hlt := (hc.2.2.1 o (hspent o ho)).2.2.2.2.2
    have hge := (ProofSupport.createdOutputs_ref_bounds _ _ _ o hnew).1
    omega

/-- Every booked request of a reached world is one the application booked. -/
private theorem reachable_pending_booked (w : World) (hr : Reachable w) :
    ∀ p ∈ w.pending, ∃ r sigs, p.request = booked w.app r sigs := by
  induction hr with
  | start app c asset =>
    intro p hp
    simp [genesis] at hp
  | @next v v' a _ hstep ih =>
    intro p hp
    cases a with
    | bookInsert r e sigs =>
      obtain ⟨_, _, _, _, _, _, _, _, _, _, _, _, hv⟩ := (bookInsert_inversion v v' r e sigs).1 hstep
      subst hv
      rcases List.mem_append.1 hp with hold | hnew
      · exact ih p hold
      · rw [List.mem_singleton.1 hnew]
        exact ⟨r, sigs, rfl⟩
    | bookTerminate r ref sigs =>
      obtain ⟨_, _, _, _, _, _, _, _, _, _, _, hv⟩ :=
        (bookTerminate_inversion v v' r ref sigs).1 hstep
      subst hv
      rcases List.mem_append.1 hp with hold | hnew
      · exact ih p hold
      · rw [List.mem_singleton.1 hnew]
        exact ⟨r, sigs, rfl⟩
    | bookOther r sigs => exact absurd hstep (bookOther_refused v v' r sigs)
    | update ref succs sigs =>
      change updateStep Law.standard v ref succs sigs = .ok v' at hstep
      obtain ⟨_, _, _, _, _, _, _, _, _, hv⟩ := (update_inversion v v' ref succs sigs).1 hstep
      subst hv
      exact ih p hp
    | fold sel outs =>
      rw [appStep_fold] at hstep
      cases hf : foldEffect Law.standard v sel outs with
      | error e =>
        rw [hf] at hstep
        exact Except.noConfusion hstep
      | ok res =>
        rw [hf] at hstep
        have hres : res.1 = v' := ProofSupport.ok_inj hstep
        obtain ⟨v1, t⟩ := res
        obtain ⟨_, _, _, _, hv1⟩ := (fold_inversion v v1 sel outs t).1 hf
        subst hres
        subst hv1
        exact ih p (List.mem_filter.1 hp).1
    | reject edge key outs =>
      change rejectStep v edge key outs = .ok v' at hstep
      obtain ⟨_, _, _, _, _, hv⟩ := (reject_inversion v v' edge key outs).1 hstep
      subst hv
      exact ih p (List.mem_of_mem_erase hp)
    | withdraw ref outs => exact absurd hstep (withdraw_inversion v v' ref outs)

/-- Every booked insertion of a reached world carries its own envelope as its
datum. -/
private theorem reachable_pending_carries_envelope (w : World) (hr : Reachable w) :
    ∀ p ∈ w.pending, p.request.edge = .insertActive →
      ∃ e, p.envelope = some e ∧ p.request.datum = some (envelopeHash e) := by
  induction hr with
  | start app c asset =>
    intro p hp
    simp [genesis] at hp
  | @next v v' a _ hstep ih =>
    intro p hp hedge
    cases a with
    | bookInsert r e sigs =>
      obtain ⟨_, _, _, _, _, _, _, _, _, _, hnd, _, hv⟩ := (bookInsert_inversion v v' r e sigs).1 hstep
      subst hv
      rcases List.mem_append.1 hp with hold | hnew
      · exact ih p hold hedge
      · rw [List.mem_singleton.1 hnew]
        exact ⟨e, rfl, hnd⟩
    | bookTerminate r ref sigs =>
      obtain ⟨_, hre, _, _, _, _, _, _, _, _, _, hv⟩ :=
        (bookTerminate_inversion v v' r ref sigs).1 hstep
      subst hv
      rcases List.mem_append.1 hp with hold | hnew
      · exact ih p hold hedge
      · rw [List.mem_singleton.1 hnew] at hedge
        have : r.edge = .insertActive := hedge
        rw [hre] at this
        exact absurd this (by decide)
    | bookOther r sigs => exact absurd hstep (bookOther_refused v v' r sigs)
    | update ref succs sigs =>
      change updateStep Law.standard v ref succs sigs = .ok v' at hstep
      obtain ⟨_, _, _, _, _, _, _, _, _, hv⟩ := (update_inversion v v' ref succs sigs).1 hstep
      subst hv
      exact ih p hp hedge
    | fold sel outs =>
      rw [appStep_fold] at hstep
      cases hf : foldEffect Law.standard v sel outs with
      | error e =>
        rw [hf] at hstep
        exact Except.noConfusion hstep
      | ok res =>
        rw [hf] at hstep
        have hres : res.1 = v' := ProofSupport.ok_inj hstep
        obtain ⟨v1, t⟩ := res
        obtain ⟨_, _, _, _, hv1⟩ := (fold_inversion v v1 sel outs t).1 hf
        subst hres
        subst hv1
        exact ih p (List.mem_filter.1 hp).1 hedge
    | reject edge key outs =>
      change rejectStep v edge key outs = .ok v' at hstep
      obtain ⟨_, _, _, _, _, hv⟩ := (reject_inversion v v' edge key outs).1 hstep
      subst hv
      exact ih p (List.mem_of_mem_erase hp) hedge
    | withdraw ref outs => exact absurd hstep (withdraw_inversion v v' ref outs)

/-- A booking of an insertion at an Active or Terminal key of a reached world
is folded into the registry's `key-exists` refusal. -/
private theorem refused_by_registry (w w₁ : World) (r : Request) (e : Envelope)
    (sigs : List Nat) (outs : List TxOutput) (hr : Reachable w)
    (hleaf : trieGet w.registry.trie r.key = .known .active ∨
      trieGet w.registry.trie r.key = .known .terminal)
    (h1 : appStep w (.bookInsert r e sigs) = .ok w₁) :
    appStep w₁ (.fold [(.insertActive, r.key)] outs) = .error "key-exists" := by
  have hc := reachable_consistent w hr
  obtain ⟨hedge, hpol, _, _, _, _, _, _, _, _, _, _, hw⟩ :=
    (bookInsert_inversion w w₁ r e sigs).1 h1
  have hr1 : Reachable w₁ := Reachable.next hr h1
  have hc1 : AppConsistent w₁ := bookInsert_preserves_consistent w w₁ r e sigs hc h1
  have hnew : (⟨booked w.app r sigs, some e⟩ : Pending) ∈ w₁.pending := by
    rw [hw]
    exact List.mem_append.2 (Or.inr (List.mem_singleton_self _))
  obtain ⟨p0, hp0⟩ : ∃ p0, pendingOf w₁ .insertActive r.key = some p0 := by
    cases hf : pendingOf w₁ .insertActive r.key with
    | none =>
      exfalso
      have := List.find?_eq_none.1 hf _ hnew
      simp [booked, hedge] at this
    | some p0 => exact ⟨p0, rfl⟩
  obtain ⟨hp0m, hp0e, hp0k⟩ := ProofSupport.pendingOf_spec w₁ _ _ p0 hp0
  rcases hc1.2.2.2.2 p0 hp0m with ⟨_, e0, he0, hout0, hdep0, _, hreg0⟩ | ⟨he, _⟩
  · obtain ⟨e1, he1, hnd0⟩ := reachable_pending_carries_envelope w₁ hr1 p0 hp0m hp0e
    rw [he0] at he1
    cases he1
    have hsel : selectRow Law.standard w₁ (.insertActive, r.key) = .ok ⟨p0, none⟩ := by
      unfold selectRow
      simp only [hp0, he0]
      simp [ensure, hout0, hdep0, hreg0, hnd0, Law.standard]
      all_goals rfl
    obtain ⟨r0, sigs0, hreq⟩ := reachable_pending_booked w₁ hr1 p0 hp0m
    have hr0e : r0.edge = .insertActive := by rw [← hp0e, hreq]; rfl
    have hr0k : r0.key = r.key := by rw [← hp0k, hreq]; rfl
    have hreg1 : w₁.registry = w.registry := by rw [hw]
    have happ1 : w₁.app = w.app := by rw [hw]
    have hstep : step w₁.registry p0.request = .error "key-exists" := by
      apply error_of_refusal
      rw [hreq, happ1, hreg1]
      exact ProofSupport.booked_insert_refusal _ _ _ _ hr0e hpol (by rw [hr0k]; exact hleaf)
    have hfb : foldBatch w₁.registry [p0.request] = .error "key-exists" := by
      unfold foldBatch
      simp only [List.isEmpty_cons, Bool.false_eq_true, if_false]
      unfold foldActions
      rw [hstep]
      rfl
    rw [appStep_fold]
    unfold foldEffect
    simp only [List.mapM_cons, List.mapM_nil, hsel]
    simp only [bind, Except.bind, pure, Except.pure, List.map_cons, List.map_nil, hfb]
    rfl
  · rw [hp0e] at he
    exact absurd he (by decide)

/-- Duplicate insertion (reached worlds) is refused by the registry's law, not by
the application: the booking is accepted and the fold refused `key-exists`. -/
theorem duplicate_refused_by_registry (w w₁ : World) (r : Request) (e : Envelope)
    (sigs : List Nat) (outs : List TxOutput) :
    Reachable w → trieGet w.registry.trie r.key = .known .active →
    appStep w (.bookInsert r e sigs) = .ok w₁ →
    appStep w₁ (.fold [(.insertActive, r.key)] outs) = .error "key-exists" := by
  intro hr hact h1
  exact refused_by_registry w w₁ r e sigs outs hr (Or.inl hact) h1

/-- Same-identity resurrection after Terminal (reached worlds) is refused by the
registry's law: the booking is accepted and the fold refused `key-exists`. -/
theorem resurrection_refused_by_registry (w w₁ : World) (r : Request) (e : Envelope)
    (sigs : List Nat) (outs : List TxOutput) :
    Reachable w → trieGet w.registry.trie r.key = .known .terminal →
    appStep w (.bookInsert r e sigs) = .ok w₁ →
    appStep w₁ (.fold [(.insertActive, r.key)] outs) = .error "key-exists" := by
  intro hr hterm h1
  exact refused_by_registry w w₁ r e sigs outs hr (Or.inr hterm) h1

/-- The fold stays permissionless: the application adds no signer to any request
it books (the registry's own `fold_requires_no_signer`). -/
theorem fold_signers_unchanged (r : Request) : requiredSigners r = [] := by
  first
    | rfl
    | simp [requiredSigners]

end OpenDatumApplication.Statements

#print axioms OpenDatumApplication.Statements.bookOther_refused
#print axioms OpenDatumApplication.Statements.appStep_fold
#print axioms OpenDatumApplication.Statements.withdraw_inversion
#print axioms OpenDatumApplication.Statements.fold_signers_unchanged
#print axioms OpenDatumApplication.Statements.bookTerminate_keeps_locked
#print axioms OpenDatumApplication.Statements.update_keeps_registry

#print axioms OpenDatumApplication.Statements.genesis_consistent
#print axioms OpenDatumApplication.Statements.consistent_occurrences_distinct
#print axioms OpenDatumApplication.Statements.duplicate_occurrence_outside_invariant
#print axioms OpenDatumApplication.Statements.insertion_requires_registry_identity

#print axioms OpenDatumApplication.Statements.bookInsert_inversion
#print axioms OpenDatumApplication.Statements.bookTerminate_inversion
#print axioms OpenDatumApplication.Statements.fold_inversion
#print axioms OpenDatumApplication.Statements.update_payload_free

#print axioms OpenDatumApplication.Statements.update_inversion
#print axioms OpenDatumApplication.Statements.reject_inversion
#print axioms OpenDatumApplication.Statements.update_requires_controller

#print axioms OpenDatumApplication.Statements.bookInsert_preserves_consistent
#print axioms OpenDatumApplication.Statements.bookTerminate_preserves_consistent

#print axioms OpenDatumApplication.Statements.reject_preserves_consistent

#print axioms OpenDatumApplication.Statements.update_preserves_consistent

#print axioms OpenDatumApplication.PlutusData.beq_iff_eq
#print axioms OpenDatumApplication.instLawfulBEqPlutusData
#print axioms OpenDatumApplication.instDecidableEqPlutusData
#print axioms OpenDatumApplication.instLawfulBEqStateAsset
#print axioms OpenDatumApplication.instLawfulBEqControl
#print axioms OpenDatumApplication.instLawfulBEqEnvelope
#print axioms OpenDatumApplication.instLawfulBEqAppOutput

#print axioms OpenDatumApplication.Statements.appStep_preserves_consistent
#print axioms OpenDatumApplication.Statements.reachable_consistent
#print axioms OpenDatumApplication.Statements.appConsistentB_iff
#print axioms OpenDatumApplication.Statements.fold_preserves_consistent
#print axioms OpenDatumApplication.Statements.update_preserves_custody
#print axioms OpenDatumApplication.Statements.insertion_binds_envelope
#print axioms OpenDatumApplication.Statements.release_burns_atomically
#print axioms OpenDatumApplication.Statements.only_fold_releases
#print axioms OpenDatumApplication.Statements.fold_settles_additively
#print axioms OpenDatumApplication.Statements.fold_spent_disappears
#print axioms OpenDatumApplication.Statements.duplicate_refused_by_registry
#print axioms OpenDatumApplication.Statements.resurrection_refused_by_registry

#print axioms OpenDatumApplication.Statements.selectRow_requires_named_datum
#print axioms OpenDatumApplication.Statements.insertion_holding_inline
