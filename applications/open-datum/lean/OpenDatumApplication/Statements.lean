import OpenDatumApplication.Model

/-! # The open-datum application's intended statements and inversions

STATED, UNPROVED. Every declaration below ends in `sorry` on purpose: this is
the MODEL+STATEMENTS+INVERSIONS phase, and the statements are submitted for
independent review before any proof. `#print axioms` reports `sorryAx` for each
of them; none is evidence of anything until proved with its statement
unchanged.

The registry's own theorems are imported, not restated; where a statement
relies on one it names it. -/

namespace OpenDatumApplication.Statements

open Singular
open OpenDatumApplication

/-! ## Public inversions: each accepted branch, exactly -/

/-- An accepted insertion booking is exactly: the guards hold, and the booked
request, with this application's approval and the edge's claimed delta, is
appended with the envelope. Nothing else changes. -/
theorem bookInsert_inversion (w w' : World) (r : Request) (e : Envelope)
    (sigs : List Nat) :
    bookInsertStep w r e sigs = .ok w' ↔
      (r.edge = .insertActive ∧ w.registry.config.applicationPolicy = w.app.policy ∧
        e.control.version = envelopeVersion ∧ e.control.registry = w.app.registry ∧
        e.control.activePolicy = w.registry.config.activePolicy ∧ e.control.key = r.key ∧
        e.control.controller = r.owner ∧ e.control.controller ∈ sigs ∧
        r.output = destinationOf w.app e ∧ e.control.deposit = r.deposit ∧
        w' = { w with pending := w.pending ++ [{ request := booked w.app r sigs
                                                , envelope := some e }] }) := by
  sorry

/-- An accepted insertion fold is exactly the registry's accepted
`insertActive` exit of the booked request, and one new output at this contract
holding the key's token, the request's deposit and the bound envelope. -/
theorem foldInsert_inversion (w w' : World) (key : Key) :
    foldInsertStep w key = .ok w' ↔
      ∃ p e t, pendingOf w .insertActive key = some p ∧ p.envelope = some e ∧
        exitStep w.registry (.fold .insertActive) p.request = .ok t ∧
        w' = { w with registry := t.state
                    , outputs := w.outputs ++ [AppOutput.mk w.nextRef (appAddress w.app) p.request.deposit [((.active, key), 1)] e]
                    , pending := w.pending.erase p, nextRef := w.nextRef + 1 } := by
  sorry

/-- An accepted update is exactly: the controller signed, one proposed output
carries the token, at this contract, with the same control, the same assets and
at least the deposit; it replaces the spent output. -/
theorem update_inversion (w w' : World) (ref : Nat) (succs : List Successor)
    (sigs : List Nat) :
    updateStep w ref succs sigs = .ok w' ↔
      ∃ o s, outputAt w ref = some o ∧
        o.envelope.control.controller ∈ sigs ∧
        succs.filter (fun x => carriesKey x.assets o.envelope.control.key) = [s] ∧
        s.address = appAddress w.app ∧ s.envelope.control = o.envelope.control ∧
        s.assets = o.assets ∧ o.envelope.control.deposit ≤ s.lovelace ∧
        w' = { w with outputs := (w.outputs.erase o) ++
                        [{ ref := w.nextRef, address := s.address, lovelace := s.lovelace
                         , assets := s.assets, envelope := s.envelope }]
                    , nextRef := w.nextRef + 1 } := by
  sorry

/-- An accepted termination booking is exactly: the guards hold and the booked
request is appended; the outputs, and so the token and deposit, are unchanged. -/
theorem bookTerminate_inversion (w w' : World) (r : Request) (ref : Nat)
    (sigs : List Nat) :
    bookTerminateStep w r ref sigs = .ok w' ↔
      ∃ o, r.edge = .updateTerminal ∧ w.registry.config.applicationPolicy = w.app.policy ∧
        outputAt w ref = some o ∧ o.address = appAddress w.app ∧ carriesKey o.assets r.key ∧
        o.envelope.control.key = r.key ∧ o.envelope.control.registry = w.app.registry ∧
        r.owner = o.envelope.control.controller ∧ o.envelope.control.controller ∈ sigs ∧
        r.output = 0 ∧
        w' = { w with pending := w.pending ++ [{ request := booked w.app r sigs
                                                , envelope := none }] } := by
  sorry

/-- An accepted release is exactly: a nonempty fold of `updateTerminal` on this
application's registry, each key's booked request and live output with matching
controller, the registry's accepted batch fold of those requests, and outputs
settling the concatenated registry payments and deposit releases. -/
theorem foldRelease_inversion (w w' : World) (keys : List Key) (exit : Exit)
    (outs : List TxOutput) :
    foldReleaseStep w keys exit outs = .ok w' ↔
      ∃ (rows : List (Pending × AppOutput)) (t : Result), keys ≠ [] ∧ exit = .fold .updateTerminal ∧ w.registryAsset = w.app.registry ∧
        rows.map (fun x : Pending × AppOutput => x.1.request.key) = keys ∧
        (∀ x ∈ rows, pendingOf w .updateTerminal x.1.request.key = some x.1 ∧
          outputOfKey w x.1.request.key = some x.2 ∧
          x.1.request.owner = x.2.envelope.control.controller) ∧
        foldBatch w.registry (rows.map (·.1.request)) = .ok t ∧
        settle (registryPayments exit (rows.map (·.1.request)) ++
          (rows.map (·.2)).map releaseOf) outs = none ∧
        w' = { w with registry := t.state
                    , outputs := w.outputs.filter fun o => !(rows.map (·.2)).contains o
                    , pending := w.pending.filter fun p => !(rows.map (·.1)).contains p } := by
  sorry

/-- No withdrawal is ever accepted. -/
theorem withdraw_inversion (w w' : World) (ref : Nat) (outs : List TxOutput) :
    withdrawStep w ref outs ≠ .ok w' := by
  sorry

/-! ## Required properties -/

/-- Authority: an accepted update was signed by the output's controller. -/
theorem update_requires_controller (w w' : World) (ref : Nat) (succs : List Successor)
    (sigs : List Nat) (o : AppOutput) :
    outputAt w ref = some o → updateStep w ref succs sigs = .ok w' →
      o.envelope.control.controller ∈ sigs := by
  sorry

/-- Custody: after an accepted update the key's token is still at this contract,
under the same control, with at least the protected deposit, and no other live
output of the contract changed. -/
theorem update_preserves_custody (w w' : World) (ref : Nat) (succs : List Successor)
    (sigs : List Nat) (o : AppOutput) :
    outputAt w ref = some o → updateStep w ref succs sigs = .ok w' →
      ∃ o', outputOfKey w' o.envelope.control.key = some o' ∧
        o'.envelope.control = o.envelope.control ∧ o'.assets = o.assets ∧
        o.envelope.control.deposit ≤ o'.lovelace ∧
        (∀ x ∈ w.outputs, x ≠ o → x ∈ w'.outputs) ∧ w'.registry = w.registry := by
  sorry

/-- Payload freedom: whether an update is accepted does not depend on the
successor's payload. -/
theorem update_payload_free (w : World) (ref : Nat) (s : Successor) (sigs : List Nat)
    (p : PlutusData) :
    (updateStep w ref [s] sigs).isOk =
      (updateStep w ref [{ s with envelope := { s.envelope with payload := p } }] sigs).isOk := by
  sorry

/-- An update leaves the registry commitment unchanged: the payload is not the
registry's. -/
theorem update_keeps_registry (w w' : World) (ref : Nat) (succs : List Successor)
    (sigs : List Nat) :
    updateStep w ref succs sigs = .ok w' → w'.registry = w.registry := by
  sorry

/-- Insertion binds: the delivered output carries exactly the envelope the
approval's destination committed to, its deposit equals the insertion request's,
and the registry's leaf for the key is Active. -/
theorem insertion_binds_envelope (w w' : World) (key : Key) :
    foldInsertStep w key = .ok w' →
      ∃ o, outputOfKey w' key = some o ∧ o.address = appAddress w.app ∧
        (∃ p, pendingOf w .insertActive key = some p ∧ p.envelope = some o.envelope ∧
          p.request.output = destinationOf w.app o.envelope ∧
          o.envelope.control.deposit = p.request.deposit ∧
          o.lovelace = p.request.deposit) ∧
        trieGet w'.registry.trie key = .known .active := by
  sorry

/-- Termination booking leaves every application output, and so every token
and deposit, where it was. -/
theorem bookTerminate_keeps_locked (w w' : World) (r : Request) (ref : Nat) (sigs : List Nat) :
    bookTerminateStep w r ref sigs = .ok w' → w'.outputs = w.outputs ∧ w'.registry = w.registry := by
  sorry

/-- Release is atomic with the registry's retirement: every released key is
Terminal after the fold and its active token is burned in the fold's own mint. -/
theorem release_is_terminal_fold (w w' : World) (keys : List Key) (exit : Exit)
    (outs : List TxOutput) :
    foldReleaseStep w keys exit outs = .ok w' →
      exit = .fold .updateTerminal ∧
      ∀ key ∈ keys, trieGet w'.registry.trie key = .known .terminal ∧
        outputOfKey w' key = none := by
  sorry

/-- No other exit releases: a reject, a retract, a `deleteActive` or any other
fold of booked requests spending application outputs is refused. -/
theorem release_only_updateTerminal (w : World) (keys : List Key) (exit : Exit)
    (outs : List TxOutput) :
    exit ≠ .fold .updateTerminal → (foldReleaseStep w keys exit outs).isOk = false := by
  sorry

/-- Additive settlement: an accepted release pays every controller at least the
sum of the registry's payments owed to it and the deposits released to it. -/
theorem release_settles_additively (w w' : World) (keys : List Key) (exit : Exit)
    (outs : List TxOutput) :
    foldReleaseStep w keys exit outs = .ok w' →
      ∃ rows : List (Pending × AppOutput),
        rows.map (fun x => x.1.request.key) = keys ∧
        ∀ c, owedTo (.owner c)
            (registryPayments exit (rows.map (·.1.request)) ++ (rows.map (·.2)).map releaseOf)
          ≤ receivedBy (.owner c) outs := by
  sorry

/-- Duplicate insertion is refused by the registry's law, not by the
application: the booking is accepted, and the fold is refused `key-exists`. -/
theorem duplicate_refused_by_registry (w w₁ : World) (r : Request) (e : Envelope)
    (sigs : List Nat) :
    trieGet w.registry.trie r.key = .known .active →
    bookInsertStep w r e sigs = .ok w₁ →
    foldInsertStep w₁ r.key = .error "key-exists" := by
  sorry

/-- Same-identity resurrection after Terminal is refused by the registry's law:
the booking is accepted, and the fold is refused `key-exists`. -/
theorem resurrection_refused_by_registry (w w₁ : World) (r : Request) (e : Envelope)
    (sigs : List Nat) :
    trieGet w.registry.trie r.key = .known .terminal →
    bookInsertStep w r e sigs = .ok w₁ →
    foldInsertStep w₁ r.key = .error "key-exists" := by
  sorry

/-- The fold stays permissionless: the application adds no signer to a
registry fold (the registry's own `fold_requires_no_signer`). -/
theorem fold_signers_unchanged (r : Request) : requiredSigners r = [] := by
  sorry

/-! ## Reached counterexamples the statements must survive

Concrete scenarios live in the driver corpus (`OpenDatumApplication.Driver`),
each executed through `appStep`: a payment meeting the registry's floor and the
release's floor separately but not their sum is refused `deposit-returned`, and
two releases to one controller in one fold owe the sum of four floors. -/

end OpenDatumApplication.Statements
