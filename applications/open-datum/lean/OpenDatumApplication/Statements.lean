import OpenDatumApplication.Model
import OpenDatumApplication.Driver
import OpenDatumApplication.ProofSupport

/-! MODEL/STATEMENTS checkpoint. Reopened proofs are intentionally STATED.
The compiled axiom table, not this prose, establishes status. Inversions cover
arbitrary worlds and retain both directions. Preservation takes independent
consistency, while lifecycle guarantees take actual application reachability.
Root abstract holdings are registration snapshots; current payload/value/ref
are observed only in application outputs. No theorem equates the two UTxOs.
No theorem here accepts a ledger implementation, funding availability or fees
at booking. Termination donation is held minus tip, without a protected floor.
-/
namespace OpenDatumApplication.Statements
open Singular OpenDatumApplication

/-- Exact application guards, then the unmodified root admission and effect. -/
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
  sorry

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
  sorry

theorem bookOther_refused (r : Request) : bookOtherStep r = .error "app-edge-not-certified" := by
  rfl

theorem update_inversion (w w' : World) (ref : Nat) (ss : List Successor) (sigs : List Nat) :
    updateStep Law.standard w ref ss sigs = .ok w' ↔
      ∃ o s, outputAt w ref = some o ∧ o.envelope.control.controller ∈ sigs ∧
        ss.filter (fun x => carriesKey x.assets o.envelope.control.key) = [s] ∧
        s.address = appAddress w.app ∧ s.envelope.control = o.envelope.control ∧ s.assets = o.assets ∧
        o.envelope.control.deposit ≤ s.lovelace ∧
        w' = { w with outputs := w.outputs.erase o ++ [{ ref := w.nextRef, address := s.address,           lovelace := s.lovelace, assets := s.assets, envelope := s.envelope, registered := o.registered }],           nextRef := w.nextRef + 1 } := by
  sorry

theorem selectRow_inversion (w : World) (ref : OutRef) (row : FoldRow) :
    selectRow Law.standard w ref = .ok row ↔
      (∃ b p, foldMemberAt w.economic ref = some (.registration b) ∧ pendingOf w ref = some p ∧
        insertionBinding Law.standard w b.request p.envelope = true ∧ row = ⟨.registration b, some p.envelope⟩) ∨
      (∃ b, foldMemberAt w.economic ref = some (.termination b) ∧ row = ⟨.termination b, none⟩) := by
  sorry

theorem fold_inversion (w w' : World) (u : EconomicUtxo) (tx : EconomicTransaction) :
    foldEffect Law.standard w u tx = .ok w' ↔
      ∃ rows economic, (selectedReferences w tx).mapM (selectRow Law.standard w) = .ok rows ∧
        Singular.foldAccepted w.economic u tx = .ok economic ∧
        w' = { w with economic, outputs := w.outputs ++ createdOutputs w.app w.nextRef rows,           pending := w.pending.filter (fun p => !inputsContainReference tx.transaction.inputs p.reference),           nextRef := w.nextRef + (createdOutputs w.app w.nextRef rows).length } := by
  sorry

theorem appStep_fold (w : World) (u : EconomicUtxo) (tx : EconomicTransaction) :
    appStep w (.fold u tx) = foldEffect Law.standard w u tx := by
  rfl

theorem reject_inversion (w w' : World) (u : EconomicUtxo) (r : Rejection) :
    rejectStep w u r = .ok w' ↔
      ∃ economic, rejectionAccepted w.economic u r = .ok economic ∧
        w' = { w with economic, pending := w.pending.filter fun p => !(r.members.any fun m => m.1 == p.reference) } := by
  sorry

theorem withdraw_inversion (w : World) (ref : Nat) (outs : List TxOutput) :
    withdrawStep w ref outs =
      if (outputAt w ref).isSome then .error "no-withdrawal-path" else .error "no-application-output" := by
  sorry

theorem genesis_consistent (app : App) (c : Config) (asset : StateAsset) :
    AppConsistent (genesis app c asset) := by
  sorry

theorem appStep_preserves_consistent (w w' : World) (a : AppAction) (hc : AppConsistent w)
    (accepted : appStep w a = .ok w') : AppConsistent w' := by
  sorry

theorem reachable_consistent (w : World) (reached : Reachable w) : AppConsistent w := by
  sorry

theorem consistent_occurrences_distinct (w : World) (hc : AppConsistent w) :
    (w.outputs.map (·.ref)).Nodup := by
  sorry

theorem duplicate_occurrence_outside_invariant (w : World) (o : AppOutput) (mem : o ∈ w.outputs) :
    ¬ AppConsistent { w with outputs := o :: w.outputs } := by
  sorry

theorem appConsistentB_iff (w : World) : Driver.appConsistentB w = true ↔ AppConsistent w := by
  sorry

theorem bookInsert_preserves_consistent (w w' : World) (b : RegistrationBooking) (e : Envelope)
    (sigs : List Nat) (hc : AppConsistent w) (accepted : bookInsertStep Law.standard w b e sigs = .ok w') :
    AppConsistent w' := by
  sorry

theorem bookTerminate_preserves_consistent (w w' : World) (b : TerminationBooking) (ref added : Nat)
    (sigs : List Nat) (hc : AppConsistent w) (accepted : bookTerminateStep Law.standard w b ref added sigs = .ok w') :
    AppConsistent w' := by
  sorry

theorem update_preserves_consistent (w w' : World) (ref : Nat) (ss : List Successor) (sigs : List Nat)
    (hc : AppConsistent w) (accepted : updateStep Law.standard w ref ss sigs = .ok w') : AppConsistent w' := by
  sorry

theorem fold_preserves_consistent (w w' : World) (u : EconomicUtxo) (tx : EconomicTransaction)
    (hc : AppConsistent w) (accepted : foldEffect Law.standard w u tx = .ok w') : AppConsistent w' := by
  sorry

theorem reject_preserves_consistent (w w' : World) (u : EconomicUtxo) (r : Rejection)
    (hc : AppConsistent w) (accepted : rejectStep w u r = .ok w') : AppConsistent w' := by
  sorry

theorem update_requires_controller (w w' : World) (ref : Nat) (ss : List Successor) (sigs : List Nat)
    (accepted : appStep w (.update ref ss sigs) = .ok w') :
    ∃ o, outputAt w ref = some o ∧ o.envelope.control.controller ∈ sigs := by
  sorry

theorem update_preserves_custody (w w' : World) (ref : Nat) (ss : List Successor) (sigs : List Nat)
    (accepted : appStep w (.update ref ss sigs) = .ok w') :
    ∃ o next, outputAt w ref = some o ∧ next ∈ w'.outputs ∧ next.address = appAddress w.app ∧
      next.assets = o.assets ∧ next.envelope.control = o.envelope.control ∧
      next.registered = o.registered ∧ o.envelope.control.deposit ≤ next.lovelace ∧
      next.ref = w.nextRef ∧ w'.outputs = w.outputs.erase o ++ [next] := by
  sorry

/-- Every Plutus payload is allowed, with no restriction on its structure. -/
theorem update_payload_free (w : World) (ref : Nat) (o : AppOutput) (payload : PlutusData)
    (found : outputAt w ref = some o) (holds : carriesKey o.assets o.envelope.control.key = true)
    (amount : Nat) (floor : o.envelope.control.deposit ≤ amount) :
    ∃ w', appStep w (.update ref [{ address := appAddress w.app, lovelace := amount, assets := o.assets,       envelope := { o.envelope with payload } }] [o.envelope.control.controller]) = .ok w' ∧
      ∃ next ∈ w'.outputs, next.envelope.payload = payload := by
  sorry

theorem update_keeps_registry (w w' : World) (ref : Nat) (ss : List Successor) (sigs : List Nat)
    (accepted : appStep w (.update ref ss sigs) = .ok w') :
    w'.economic = w.economic ∧ w'.pending = w.pending := by
  sorry

theorem insertion_requires_registry_identity (w w' : World) (b : RegistrationBooking) (e : Envelope)
    (sigs : List Nat) (accepted : appStep w (.bookInsert b e sigs) = .ok w') :
    w.app.registry = w.registryAsset ∧ e.control.registry = w.registryAsset ∧
      w.registryAsset.policy = w.registry.config.stateToken.policy ∧
      w.registryAsset.assetName = w.registry.config.stateToken.name := by
  sorry

theorem insertion_binds_envelope (w w' : World) (b : RegistrationBooking) (e : Envelope) (sigs : List Nat)
    (accepted : appStep w (.bookInsert b e sigs) = .ok w') :
    b.request.destination = destinationOf w.app e ∧ b.request.datum = some (envelopeHash e) ∧
      b.request.carrierAda = e.control.deposit ∧ e.control.controller = b.request.refundAddress ∧
      e.control.key = b.request.key ∧ e.control.activePolicy = w.registry.config.activePolicy := by
  sorry

theorem selectRow_requires_named_datum (w : World) (ref : OutRef) (row : FoldRow) (b : RegistrationBooking)
    (selected : selectRow Law.standard w ref = .ok row) (registration : row.member = .registration b) :
    ∃ e, row.envelope = some e ∧ b.request.datum = some (envelopeHash e) ∧
      b.request.destination = destinationOf w.app e := by
  sorry

theorem insertion_holding_inline (w w' : World) (u : EconomicUtxo) (tx : EconomicTransaction)
    (accepted : appStep w (.fold u tx) = .ok w') (b : RegistrationBooking)
    (selected : FoldMember.registration b ∈ foldMembers w.economic tx) :
    ∃ e o, pendingOf w b.request.reference = some ⟨b.request.reference, e⟩ ∧ o ∈ tx.outputs ∧
      o.output.datum = .inline ∧ o.output.datumValue = some (envelopeHash e) ∧
      o.output.address = some (destinationOf w.app e) ∧ o.output.lovelace = e.control.deposit ∧
      o.singularTags = [w.registry.config.singularTag b.request.key] := by
  sorry

/-- Replaces the false old statement that booking keeps custody locked. -/
theorem bookTerminate_transfers_custody (w w' : World) (b : TerminationBooking) (ref added : Nat)
    (sigs : List Nat) (reached : Reachable w) (accepted : appStep w (.bookTerminate b ref added sigs) = .ok w') :
    ∃ o, outputAt w ref = some o ∧ o ∉ w'.outputs ∧ (outputOfKey w' b.request.key).isNone = true ∧
      b ∈ w'.economic.terminations ∧ w'.registry.trie = w.registry.trie ∧
      w'.economic.treasury = w.economic.treasury := by
  sorry

theorem termination_fold_burns_atomically (w w' : World) (u : EconomicUtxo) (tx : EconomicTransaction)
    (b : TerminationBooking) (reached : Reachable w) (accepted : appStep w (.fold u tx) = .ok w')
    (selected : FoldMember.termination b ∈ foldMembers w.economic tx) :
    trieGet w'.registry.trie b.request.key = .known .terminal ∧
      b ∉ w'.economic.terminations ∧ (outputOfKey w' b.request.key).isNone = true ∧
      (((tx.singularMint.filter (fun p => p.1 == w.registry.config.singularTag b.request.key)).map Prod.snd).sum = -1) ∧
      requestTagsBurned u tx = true := by
  sorry

/-- Updates replace an occurrence but keep the key in custody. Only termination
booking removes a live key; a fold never requires or releases that live output. -/
theorem only_termination_booking_transfers_custody (w w' : World) (a : AppAction) (key : Key)
    (reached : Reachable w) (accepted : appStep w a = .ok w')
    (before : (outputOfKey w key).isSome = true) (after : (outputOfKey w' key).isNone = true) :
    ∃ b ref added sigs, a = .bookTerminate b ref added sigs ∧ b.request.key = key := by
  sorry

/-- Exact gross allocation, with ordinary fee funding; no named payee or profit. -/
theorem fold_routes_economics (w w' : World) (u : EconomicUtxo) (tx : EconomicTransaction)
    (reached : Reachable w) (accepted : appStep w (.fold u tx) = .ok w') :
    balanced u.ledger tx.transaction = true ∧
      outputLovelace ((economicSpent u tx).filter (fun o => o.output.stateTokens > 0) |>.map (·.output)) =
        outputLovelace (tx.outputs.filter (fun o => o.output.stateTokens > 0) |>.map (·.output)) ∧
      tx.transaction.donation = (foldObligations (foldMembers w.economic tx)).donation ∧
      (tx.outputs.filter (fun o => !o.singularTags.isEmpty) |>.map (·.output.lovelace)).sum =
        (foldObligations (foldMembers w.economic tx)).carriers ∧
      foldOrdinaryLovelace tx.outputs + tx.transaction.fee =
        foldOrdinaryLovelace (economicSpent u tx) + (foldObligations (foldMembers w.economic tx)).tips ∧
      tx.transaction.fee ≤ foldOrdinaryLovelace (economicSpent u tx) ∧
      w'.economic.treasury = w.economic.treasury + tx.transaction.donation ∧ requestTagsBurned u tx = true := by
  sorry

theorem fold_consumed_requests_disappear (w w' : World) (u : EconomicUtxo) (tx : EconomicTransaction)
    (accepted : appStep w (.fold u tx) = .ok w') :
    ∀ ref ∈ selectedReferences w tx, (foldMemberAt w'.economic ref).isNone = true ∧
      (pendingOf w' ref).isNone = true := by
  sorry

theorem duplicate_refused_by_registry (w : World) (u : EconomicUtxo) (tx : EconomicTransaction)
    (reached : Reachable w) (b : RegistrationBooking)
    (selected : FoldMember.registration b ∈ foldMembers w.economic tx)
    (active : trieGet w.registry.trie b.request.key = .known .active) :
    ∃ why, appStep w (.fold u tx) = .error why := by
  sorry

theorem resurrection_refused_by_registry (w : World) (u : EconomicUtxo) (tx : EconomicTransaction)
    (reached : Reachable w) (b : RegistrationBooking)
    (selected : FoldMember.registration b ∈ foldMembers w.economic tx)
    (terminal : trieGet w.registry.trie b.request.key = .known .terminal) :
    ∃ why, appStep w (.fold u tx) = .error why := by
  sorry

theorem fold_requires_no_application_signature (w : World) (u : EconomicUtxo) (tx : EconomicTransaction)
    (signers : List Nat) :
    appStep w (.fold u { tx with transaction := { tx.transaction with signers } }) = appStep w (.fold u tx) := by
  sorry

theorem registration_tag_binds_nonce (w w' : World) (b : RegistrationBooking) (e : Envelope) (sigs : List Nat)
    (accepted : appStep w (.bookInsert b e sigs) = .ok w') :
    ∃ tag, b.request.contents.applicationTags = [tag] ∧ tag.policy = w.registry.config.applicationPolicy ∧
      tag.edge = .insertActive ∧ tag.key = b.request.key ∧ tag.owner = b.request.refundAddress ∧
      tag.destination = b.request.destination ∧
      tag.assetName = applicationTagAssetName b.request.key b.request.refundAddress b.request.destination b.request.nonce ∧
      b.applicationTagsMinted = [tag] := by
  sorry

theorem termination_has_no_application_tag_or_clock (w w' : World) (b : TerminationBooking) (ref added : Nat)
    (sigs : List Nat) (accepted : appStep w (.bookTerminate b ref added sigs) = .ok w') :
    b.request.contents.applicationTags = [] ∧ b.request.refundAddress = none ∧ b.request.submittedAt = none ∧
      b.request.singularTags = [w.registry.config.singularTag b.request.key] ∧
      b.request.contents.trieReadyTags = [b.request.trieReadyTag w.registry.config] := by
  sorry

/-- All actual value goes into the request. The equation allocates zero of V to
controller refund or surplus routing. It does not prohibit unrelated ordinary
payments to the controller address, which booking does not model. -/
theorem termination_booking_has_no_controller_payout (w w' : World) (b : TerminationBooking) (ref added : Nat)
    (sigs : List Nat) (accepted : appStep w (.bookTerminate b ref added sigs) = .ok w') :
    ∃ o, outputAt w ref = some o ∧ b.request.contents.lovelace = o.lovelace + added ∧
      w'.outputs = w.outputs.erase o ∧ w'.economic.treasury = w.economic.treasury := by
  sorry

theorem termination_booking_value_transfer (w w' : World) (b : TerminationBooking) (ref added : Nat)
    (sigs : List Nat) (accepted : appStep w (.bookTerminate b ref added sigs) = .ok w') :
    ∃ o, outputAt w ref = some o ∧ b.request.contents.lovelace = o.lovelace + added ∧
      b.request.contents.lovelace = b.request.declaredTip + b.request.carrierAda ∧
      w.registry.config.minimumTip ≤ b.request.declaredTip := by
  sorry

theorem pending_termination_cannot_be_rebooked_or_updated (w : World) (b : TerminationBooking)
    (reached : Reachable w) (pending : b ∈ w.economic.terminations) :
    (outputOfKey w b.request.key).isNone = true ∧
      ∀ next ref added sigs, next.request.key = b.request.key →
        ∃ why, appStep w (.bookTerminate next ref added sigs) = .error why := by
  sorry

theorem application_root_world_correspondence (w : World) (reached : Reachable w) :
    Singular.WorldReachable w.economic ∧ CustodyCorrespondence w := by
  sorry

theorem application_supply_spans_custody_and_pending (w : World) (reached : Reachable w) (key : Key) :
    (w.outputs.filter (fun o => o.envelope.control.key == key)).length + carriedSingularCount w.economic key =
      if trieGet w.registry.trie key = .known .active then 1 else 0 := by
  sorry

/-- The selected termination's contribution is H-T; total donation also includes
other selected requests. The theorem deliberately imposes no protected floor. -/
theorem termination_fold_donates_held_minus_tip (w w' : World) (u : EconomicUtxo) (tx : EconomicTransaction)
    (b : TerminationBooking) (accepted : appStep w (.fold u tx) = .ok w')
    (selected : FoldMember.termination b ∈ foldMembers w.economic tx) :
    (FoldMember.termination b).donation = b.request.contents.lovelace - b.request.declaredTip ∧
      tx.transaction.donation = ((foldMembers w.economic tx).map FoldMember.donation).sum ∧
      w'.economic.treasury = w.economic.treasury + tx.transaction.donation := by
  sorry

/-- No expiry predicate for a termination at fold, and no expiry rejection. -/
theorem termination_has_no_expiry (w : World) (b : TerminationBooking) (interval : Interval) :
    foldMemberRefusal w.registry.config interval (.termination b) = none ∧
      terminationRejectionGround w.economic b.request .expired = some "reject-termination-no-expiry" := by
  sorry

theorem selected_request_refs_distinct (w w' : World) (u : EconomicUtxo) (tx : EconomicTransaction)
    (accepted : appStep w (.fold u tx) = .ok w') : (selectedReferences w tx).Nodup := by
  sorry

/-- All pending terminations survive every accepted rejection, regardless of
which unrelated registrations it lawfully consumes. -/
theorem rejection_preserves_pending_terminations (w w' : World) (u : EconomicUtxo) (r : Rejection)
    (accepted : appStep w (.reject u r) = .ok w') :
    w'.economic.terminations = w.economic.terminations ∧ w'.outputs = w.outputs := by
  sorry
theorem registration_allocations_are_distinct (w w' : World) (b : RegistrationBooking) (e : Envelope)
    (sigs : List Nat) (accepted : appStep w (.bookInsert b e sigs) = .ok w') :
    b.request.contents.lovelace = b.request.registrationCost + b.request.declaredTip + b.request.carrierAda ∧
      b.request.registrationCost = w.registry.config.registrationCost ∧
      b.request.carrierAda = e.control.deposit ∧ w.registry.config.minimumTip ≤ b.request.declaredTip := by
  sorry

end OpenDatumApplication.Statements
