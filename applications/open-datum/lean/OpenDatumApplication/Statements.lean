import OpenDatumApplication.Model
import OpenDatumApplication.Driver

/-! # The open-datum application's intended statements and inversions

Six declarations were previously proved. This bounded slice targets four further unchanged declarations; the other22 remain UNPROVED. Only captured #print axioms results establish each target's proof status; the current ledger remains a historical statement-phase artifact.

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
        r.output = destinationOf w.app e ∧ e.control.deposit = r.deposit ∧
        w' = { w with pending := w.pending ++ [⟨booked w.app r sigs, some e⟩] }) := by
  sorry

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
  sorry

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
  sorry

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
  sorry

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
  sorry

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
  sorry

/-- Every reached world is consistent. -/
theorem reachable_consistent (w : World) : Reachable w → AppConsistent w := by
  sorry

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
  sorry

/-! ### Preservation, constructor by constructor

`bookOther` and `withdraw` accept nothing (`bookOther_refused`,
`withdraw_inversion`), so they have no preservation obligation. -/

theorem bookInsert_preserves_consistent (w w' : World) (r : Request) (e : Envelope)
    (sigs : List Nat) :
    AppConsistent w → appStep w (.bookInsert r e sigs) = .ok w' → AppConsistent w' := by
  sorry

theorem bookTerminate_preserves_consistent (w w' : World) (r : Request) (ref : Nat)
    (sigs : List Nat) :
    AppConsistent w → appStep w (.bookTerminate r ref sigs) = .ok w' → AppConsistent w' := by
  sorry

theorem update_preserves_consistent (w w' : World) (ref : Nat) (succs : List Successor)
    (sigs : List Nat) :
    AppConsistent w → appStep w (.update ref succs sigs) = .ok w' → AppConsistent w' := by
  sorry

/-- Every fold, mixed insertion and termination selections included. -/
theorem fold_preserves_consistent (w w' : World) (sel : List (Edge × Key))
    (outs : List TxOutput) :
    AppConsistent w → appStep w (.fold sel outs) = .ok w' → AppConsistent w' := by
  sorry

theorem reject_preserves_consistent (w w' : World) (edge : Edge) (key : Key)
    (outs : List TxOutput) :
    AppConsistent w → appStep w (.reject edge key outs) = .ok w' → AppConsistent w' := by
  sorry

/-! ## Required properties -/

/-- Authority (any world): an accepted update was signed by the output's
controller. -/
theorem update_requires_controller (w w' : World) (ref : Nat) (succs : List Successor)
    (sigs : List Nat) (o : AppOutput) :
    outputAt w ref = some o → appStep w (.update ref succs sigs) = .ok w' →
      o.envelope.control.controller ∈ sigs := by
  sorry

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
  sorry

/-- Payload freedom (any world): whether an update is accepted does not depend
on the successor's payload. -/
theorem update_payload_free (w : World) (ref : Nat) (s : Successor) (sigs : List Nat)
    (p : PlutusData) :
    (appStep w (.update ref [s] sigs)).isOk =
      (appStep w (.update ref [{ s with envelope := { s.envelope with payload := p } }] sigs)).isOk := by
  sorry

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
  sorry

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
  sorry

/-- Only a fold removes an application output (any world): every other accepted
action keeps every live output's key held at this contract. -/
theorem only_fold_releases (w w' : World) (a : AppAction) :
    (∀ sel outs, a ≠ .fold sel outs) → appStep w a = .ok w' →
      ∀ o ∈ w.outputs, ∃ o' ∈ w'.outputs, o'.envelope.control = o.envelope.control ∧
        o'.assets = o.assets := by
  sorry

/-- Additive settlement (any world, bound to the actual rows): an accepted fold's
selected rows are those `selectRow` chose; its whole duty, the registry's payment
for every selected request by its edge and each spent output's own protected
deposit to its own controller, is paid, and every recipient — the same
controller owed several floors included — receives at least their sum. -/
theorem fold_settles_additively (w w' : World) (sel : List (Edge × Key))
    (outs : List TxOutput) (t : Result) :
    foldEffect Law.standard w sel outs = .ok (w', t) →
      ∃ rows, sel.mapM (selectRow Law.standard w) = .ok rows ∧
        releases rows = (rows.filterMap (·.spent)).map (fun o =>
          { recipient := .owner o.envelope.control.controller
          , atLeast := o.envelope.control.deposit : Payment }) ∧
        (∀ o ∈ rows.filterMap (·.spent), o ∈ w.outputs ∧ o ∉ w'.outputs) ∧
        ∀ rcp, owedTo rcp (foldPayments rows) ≤
          receivedBy rcp (outs ++ (createdOutputs w.app w.nextRef rows).map (deliveryOf w.app)) := by
  sorry

/-- Duplicate insertion (reached worlds) is refused by the registry's law, not by
the application: the booking is accepted and the fold refused `key-exists`. -/
theorem duplicate_refused_by_registry (w w₁ : World) (r : Request) (e : Envelope)
    (sigs : List Nat) (outs : List TxOutput) :
    Reachable w → trieGet w.registry.trie r.key = .known .active →
    appStep w (.bookInsert r e sigs) = .ok w₁ →
    appStep w₁ (.fold [(.insertActive, r.key)] outs) = .error "key-exists" := by
  sorry

/-- Same-identity resurrection after Terminal (reached worlds) is refused by the
registry's law: the booking is accepted and the fold refused `key-exists`. -/
theorem resurrection_refused_by_registry (w w₁ : World) (r : Request) (e : Envelope)
    (sigs : List Nat) (outs : List TxOutput) :
    Reachable w → trieGet w.registry.trie r.key = .known .terminal →
    appStep w (.bookInsert r e sigs) = .ok w₁ →
    appStep w₁ (.fold [(.insertActive, r.key)] outs) = .error "key-exists" := by
  sorry

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
