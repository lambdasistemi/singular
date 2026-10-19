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
  exact ProofSupport.bookInsert_inversion w w' b e sigs

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
  exact ProofSupport.bookTerminate_inversion w w' b ref added sigs

theorem bookOther_refused (r : Request) : bookOtherStep r = .error "app-edge-not-certified" := by
  rfl

theorem update_inversion (w w' : World) (ref : Nat) (ss : List Successor) (sigs : List Nat) :
    updateStep Law.standard w ref ss sigs = .ok w' ↔
      ∃ o s, outputAt w ref = some o ∧ o.envelope.control.controller ∈ sigs ∧
        ss.filter (fun x => carriesKey x.assets o.envelope.control.key) = [s] ∧
        s.address = appAddress w.app ∧ s.envelope.control = o.envelope.control ∧ s.assets = o.assets ∧
        o.envelope.control.deposit ≤ s.lovelace ∧
        w' = { w with outputs := w.outputs.erase o ++ [{ ref := w.nextRef, address := s.address,           lovelace := s.lovelace, assets := s.assets, envelope := s.envelope, registered := o.registered }],           nextRef := w.nextRef + 1 } := by
  exact ProofSupport.update_inversion w w' ref ss sigs

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

theorem fold_inversion (w w' : World) (u : EconomicUtxo) (tx : EconomicTransaction) :
    foldEffect Law.standard w u tx = .ok w' ↔
      ∃ rows economic, (selectedReferences w tx).mapM (selectRow Law.standard w) = .ok rows ∧
        Singular.foldAccepted w.economic u tx = .ok economic ∧
        applicationFoldTimingRefusal w.economic tx = none ∧
        w' = { w with economic, outputs := w.outputs ++ createdOutputs w.app w.nextRef rows,           pending := w.pending.filter (fun p => !inputsContainReference tx.transaction.inputs p.reference),           nextRef := w.nextRef + (createdOutputs w.app w.nextRef rows).length } := by
  exact ProofSupport.fold_inversion w w' u tx

theorem appStep_fold (w : World) (u : EconomicUtxo) (tx : EconomicTransaction) :
    appStep w (.fold u tx) = foldEffect Law.standard w u tx := by
  rfl

theorem reject_inversion (w w' : World) (u : EconomicUtxo) (r : Rejection) :
    rejectStep w u r = .ok w' ↔
      ∃ economic, rejectionAccepted w.economic u r = .ok economic ∧
        w' = { w with economic, pending := w.pending.filter fun p => !(r.members.any fun m => m.1 == p.reference) } := by
  exact ProofSupport.reject_inversion w w' u r

theorem withdraw_inversion (w : World) (ref : Nat) (outs : List TxOutput) :
    withdrawStep w ref outs =
      if (outputAt w ref).isSome then .error "no-withdrawal-path" else .error "no-application-output" := by
  unfold withdrawStep
  cases h : outputAt w ref <;> simp

theorem genesis_consistent (app : App) (c : Config) (asset : StateAsset) :
    AppConsistent (genesis app c asset) := by
  have hc := Singular.reachable_consistent _ (Singular.Reachable.initial c)
  simpa [AppConsistent, genesis, foldProjectedRegistry, World.registry, CustodyCorrespondence] using hc

theorem appStep_preserves_consistent (w w' : World) (a : AppAction) (hc : AppConsistent w)
    (accepted : appStep w a = .ok w') : AppConsistent w' := by
  cases a with
  | bookInsert b e sigs => exact ProofSupport.insertion_consistent w w' b e sigs hc accepted
  | bookTerminate b ref added sigs => exact ProofSupport.termination_consistent w w' b ref added sigs hc accepted
  | update ref ss sigs => exact ProofSupport.update_consistent w w' ref ss sigs hc accepted
  | fold u tx => exact ProofSupport.fold_consistent w w' u tx hc accepted
  | reject u r => exact ProofSupport.rejection_consistent w w' u r hc accepted
  | bookOther r sigs => cases accepted
  | withdraw ref outs =>
    change withdrawStep w ref outs = .ok w' at accepted
    unfold withdrawStep at accepted
    cases found : outputAt w ref <;> simp [found] at accepted

theorem reachable_consistent (w : World) (reached : Reachable w) : AppConsistent w := by
  induction reached with
  | initial app c asset => exact genesis_consistent app c asset
  | @next before after action reached accepted ih => exact appStep_preserves_consistent before after action ih accepted

theorem consistent_occurrences_distinct (w : World) (hc : AppConsistent w) :
    (w.outputs.map (·.ref)).Nodup := by
  exact hc.2.1

theorem duplicate_occurrence_outside_invariant (w : World) (o : AppOutput) (mem : o ∈ w.outputs) :
    ¬ AppConsistent { w with outputs := o :: w.outputs } := by
  intro hc
  have hn := hc.2.1
  simp only [List.map_cons, List.nodup_cons] at hn
  exact hn.1 (List.mem_map.mpr ⟨o, mem, rfl⟩)

theorem appConsistentB_iff (w : World) : Driver.appConsistentB w = true ↔ AppConsistent w := by
  simp [Driver.appConsistentB,Driver.appConsistentBWith,AppConsistent,CustodyCorrespondence,
    ProofSupport.root_bool_consistent,List.all_eq_true,List.any_eq_true,and_assoc]
  grind

theorem bookInsert_preserves_consistent (w w' : World) (b : RegistrationBooking) (e : Envelope)
    (sigs : List Nat) (hc : AppConsistent w) (accepted : bookInsertStep Law.standard w b e sigs = .ok w') :
    AppConsistent w' := by
  exact ProofSupport.insertion_consistent w w' b e sigs hc accepted

theorem bookTerminate_preserves_consistent (w w' : World) (b : TerminationBooking) (ref added : Nat)
    (sigs : List Nat) (hc : AppConsistent w) (accepted : bookTerminateStep Law.standard w b ref added sigs = .ok w') :
    AppConsistent w' := by
  exact ProofSupport.termination_consistent w w' b ref added sigs hc accepted

theorem update_preserves_consistent (w w' : World) (ref : Nat) (ss : List Successor) (sigs : List Nat)
    (hc : AppConsistent w) (accepted : updateStep Law.standard w ref ss sigs = .ok w') : AppConsistent w' := by
  exact ProofSupport.update_consistent w w' ref ss sigs hc accepted

theorem fold_preserves_consistent (w w' : World) (u : EconomicUtxo) (tx : EconomicTransaction)
    (hc : AppConsistent w) (accepted : foldEffect Law.standard w u tx = .ok w') : AppConsistent w' := by
  exact ProofSupport.fold_consistent w w' u tx hc accepted

theorem reject_preserves_consistent (w w' : World) (u : EconomicUtxo) (r : Rejection)
    (hc : AppConsistent w) (accepted : rejectStep w u r = .ok w') : AppConsistent w' := by
  exact ProofSupport.rejection_consistent w w' u r hc accepted

theorem update_requires_controller (w w' : World) (ref : Nat) (ss : List Successor) (sigs : List Nat)
    (accepted : appStep w (.update ref ss sigs) = .ok w') :
    ∃ o, outputAt w ref = some o ∧ o.envelope.control.controller ∈ sigs := by
  obtain ⟨o, s, found, signer, rest⟩ := (update_inversion w w' ref ss sigs).mp accepted
  exact ⟨o, found, signer⟩

theorem update_preserves_custody (w w' : World) (ref : Nat) (ss : List Successor) (sigs : List Nat)
    (accepted : appStep w (.update ref ss sigs) = .ok w') :
    ∃ o next, outputAt w ref = some o ∧ next ∈ w'.outputs ∧ next.address = appAddress w.app ∧
      next.assets = o.assets ∧ next.envelope.control = o.envelope.control ∧
      next.registered = o.registered ∧ o.envelope.control.deposit ≤ next.lovelace ∧
      next.ref = w.nextRef ∧ w'.outputs = w.outputs.erase o ++ [next] := by
  obtain ⟨o,s,found,signer,card,address,control,assets,floor,effect⟩ := (update_inversion w w' ref ss sigs).mp accepted
  subst w'
  refine ⟨o, ⟨w.nextRef,s.address,s.lovelace,s.assets,s.envelope,o.registered⟩, found, ?_, address, assets, control, rfl, floor, rfl, rfl⟩
  simp

/-- Every Plutus payload is allowed, with no restriction on its structure. -/
theorem update_payload_free (w : World) (ref : Nat) (o : AppOutput) (payload : PlutusData)
    (found : outputAt w ref = some o) (holds : carriesKey o.assets o.envelope.control.key = true)
    (amount : Nat) (floor : o.envelope.control.deposit ≤ amount) :
    ∃ w', appStep w (.update ref [{ address := appAddress w.app, lovelace := amount, assets := o.assets,       envelope := { o.envelope with payload } }] [o.envelope.control.controller]) = .ok w' ∧
      ∃ next ∈ w'.outputs, next.envelope.payload = payload := by
  let s : Successor := ⟨appAddress w.app, amount, o.assets, { o.envelope with payload }⟩
  let next : AppOutput := ⟨w.nextRef,s.address,s.lovelace,s.assets,s.envelope,o.registered⟩
  let after : World := { w with outputs := w.outputs.erase o ++ [next], nextRef := w.nextRef + 1 }
  refine ⟨after, ?_, next, ?_, rfl⟩
  · apply (update_inversion w after ref [s] [o.envelope.control.controller]).mpr
    refine ⟨o,s,found,by simp,?_,rfl,rfl,rfl,floor,rfl⟩
    simp [s, holds]
  · simp [after]

theorem update_keeps_registry (w w' : World) (ref : Nat) (ss : List Successor) (sigs : List Nat)
    (accepted : appStep w (.update ref ss sigs) = .ok w') :
    w'.economic = w.economic ∧ w'.pending = w.pending := by
  obtain ⟨o,s,found,signer,card,address,control,assets,floor,effect⟩ := (update_inversion w w' ref ss sigs).mp accepted
  subst w'
  exact ⟨rfl,rfl⟩

theorem insertion_requires_registry_identity (w w' : World) (b : RegistrationBooking) (e : Envelope)
    (sigs : List Nat) (accepted : appStep w (.bookInsert b e sigs) = .ok w') :
    w.app.registry = w.registryAsset ∧ e.control.registry = w.registryAsset ∧
      w.registryAsset.policy = w.registry.config.stateToken.policy ∧
      w.registryAsset.assetName = w.registry.config.stateToken.name := by
  have h := (bookInsert_inversion w w' b e sigs).mp accepted
  exact ⟨h.2.1,h.2.2.1,h.2.2.2.1,h.2.2.2.2.1⟩

theorem insertion_binds_envelope (w w' : World) (b : RegistrationBooking) (e : Envelope) (sigs : List Nat)
    (accepted : appStep w (.bookInsert b e sigs) = .ok w') :
    b.request.destination = destinationOf w.app e ∧ b.request.datum = some (envelopeHash e) ∧
      b.request.carrierAda = e.control.deposit ∧ e.control.controller = b.request.refundAddress ∧
      e.control.key = b.request.key ∧ e.control.activePolicy = w.registry.config.activePolicy := by
  obtain ⟨pin,app,reg,pol,name,ver,active,key,ctrl,sig,dest,datum,deposit,rest⟩ := (bookInsert_inversion w w' b e sigs).mp accepted
  exact ⟨dest,datum,deposit.symm,ctrl,key,active⟩

theorem selectRow_requires_named_datum (w : World) (ref : OutRef) (row : FoldRow) (b : RegistrationBooking)
    (selected : selectRow Law.standard w ref = .ok row) (registration : row.member = .registration b) :
    ∃ e, row.envelope = some e ∧ b.request.datum = some (envelopeHash e) ∧
      b.request.destination = destinationOf w.app e := by
  rcases (selectRow_inversion w ref row).mp selected with ⟨booking,p,hm,hp,binding,effect⟩ | ⟨booking,hm,effect⟩
  · subst row
    cases registration
    simp only [insertionBinding, Law.standard, Bool.and_eq_true, Bool.not_true, Bool.false_or, beq_iff_eq] at binding
    exact ⟨p.envelope,rfl,binding.1.2,binding.1.1.2⟩
  · subst row
    cases registration

theorem insertion_holding_inline (w w' : World) (u : EconomicUtxo) (tx : EconomicTransaction)
    (accepted : appStep w (.fold u tx) = .ok w') (b : RegistrationBooking)
    (selected : FoldMember.registration b ∈ foldMembers w.economic tx) :
    ∃ e o, pendingOf w b.request.reference = some ⟨b.request.reference, e⟩ ∧ o ∈ tx.outputs ∧
      o.output.datum = .inline ∧ o.output.datumValue = some (envelopeHash e) ∧
      o.output.address = some (destinationOf w.app e) ∧ o.output.lovelace = e.control.deposit ∧
      o.singularTags = [w.registry.config.singularTag b.request.key] := by
  obtain ⟨rows,economic,selection,root,timing,effect⟩ := (fold_inversion w w' u tx).mp accepted
  obtain ⟨input,inputMem,chosen⟩ := List.mem_filterMap.mp selected
  cases href : input.ref with
  | none => simp [href] at chosen
  | some reference =>
    have lookup : foldMemberAt w.economic reference = some (.registration b) := by simpa [href] using chosen
    have bookingRef := ProofSupport.registration_at_reference lookup
    have selectedRef : reference ∈ selectedReferences w tx := by
      apply List.mem_filterMap.mpr
      exact ⟨input,inputMem,Option.filter_eq_some_iff.mpr ⟨href,by rw [lookup]; rfl⟩⟩
    obtain ⟨row,rowMem,rowAccepted⟩ := ProofSupport.mapM_ok_mem _ selection selectedRef
    rcases (selectRow_inversion w reference row).mp rowAccepted with ⟨booking,p,hm,hp,binding,rowEffect⟩ | ⟨booking,hm,rowEffect⟩
    · have same : booking = b := by rw [lookup] at hm; simpa using hm.symm
      subst booking
      have pendingRef : p.reference = reference := by simpa using List.find?_some hp
      simp only [insertionBinding,Law.standard,Bool.and_eq_true,Bool.not_true,Bool.false_or,beq_iff_eq] at binding
      obtain ⟨_,result,_,routing,_⟩ := Singular.foldAccepted_checks root
      obtain ⟨out,outMem,datumForm,datumValue,destination,value,tags⟩ := ProofSupport.registration_carrier_details ((Singular.foldRouting_partitions routing).2.1 (.registration b) selected)
      refine ⟨p.envelope,out,?_,outMem,?_,datumValue.trans binding.1.2,?_,value.trans binding.2.symm,tags⟩
      · rw [bookingRef]
        cases p with
        | mk ref envelope =>
          simp only at pendingRef
          subst ref
          exact hp
      · simpa [binding.1.2,datumFormOf] using datumForm
      · rw [destination,binding.1.1.2]
    · rw [lookup] at hm
      cases hm

/-- Replaces the false old statement that booking keeps custody locked. -/
theorem bookTerminate_transfers_custody (w w' : World) (b : TerminationBooking) (ref added : Nat)
    (sigs : List Nat) (reached : Reachable w) (accepted : appStep w (.bookTerminate b ref added sigs) = .ok w') :
    ∃ o, outputAt w ref = some o ∧ o ∉ w'.outputs ∧ (outputOfKey w' b.request.key).isNone = true ∧
      b ∈ w'.economic.terminations ∧ w'.registry.trie = w.registry.trie ∧
      w'.economic.treasury = w.economic.treasury := by
  have hc := reachable_consistent w reached
  have after := ProofSupport.termination_consistent w w' b ref added sigs hc accepted
  obtain ⟨o,economic,found,_,_,_,_,_,_,_,_,_,_,_,_,_,root,effect⟩ := (bookTerminate_inversion w w' b ref added sigs).mp accepted
  have economicEffect := (ProofSupport.bookTermination_checks root).2
  have queued : b ∈ w'.economic.terminations := by rw [effect,economicEffect]; simp
  have missing := ProofSupport.output_key_none w' b.request.key after (ProofSupport.pending_key_not_output w' after b queued)
  have distinct : w.outputs.Nodup := List.Pairwise.of_map (·.ref) (fun a b h eq => h (congrArg AppOutput.ref eq)) hc.2.1
  refine ⟨o,found,?_,missing,queued,?_,?_⟩
  · rw [effect]; exact distinct.not_mem_erase
  · rw [effect,economicEffect]; rfl
  · rw [effect,economicEffect]

theorem termination_fold_burns_atomically (w w' : World) (u : EconomicUtxo) (tx : EconomicTransaction)
    (b : TerminationBooking) (reached : Reachable w) (accepted : appStep w (.fold u tx) = .ok w')
    (selected : FoldMember.termination b ∈ foldMembers w.economic tx) :
    trieGet w'.registry.trie b.request.key = .known .terminal ∧
      b ∉ w'.economic.terminations ∧ (outputOfKey w' b.request.key).isNone = true ∧
      (((tx.singularMint.filter (fun p => p.1 == w.registry.config.singularTag b.request.key)).map Prod.snd).sum = -1) ∧
      requestTagsBurned u tx = true := by
  have hc := reachable_consistent w reached
  have after := ProofSupport.fold_consistent w w' u tx hc accepted
  obtain ⟨rows,economic,selection,root,timing,effect⟩ := (fold_inversion w w' u tx).mp accepted
  obtain ⟨terminal,mint⟩ := ProofSupport.folded_termination_result w hc u tx economic root b selected
  have terminalAfter : trieGet w'.registry.trie b.request.key = .known .terminal := by rw [effect]; exact terminal
  have spent := (Singular.foldMembers_termination selected).2
  have removed : b ∉ w'.economic.terminations := by
    rw [effect,(Singular.foldAccepted_pending root).2]
    intro member
    have kept := (List.mem_filter.mp member).2
    simp [spent] at kept
  have missing := ProofSupport.output_key_none w' b.request.key after (by
    intro o member same
    have active := ProofSupport.output_key_active w' after o member
    rw [same,terminalAfter] at active
    contradiction)
  obtain ⟨_,result,_,routing,_⟩ := Singular.foldAccepted_checks root
  exact ⟨terminalAfter,removed,missing,mint,(Singular.foldRouting_accounting routing).2.2.2⟩

/-- Updates replace an occurrence but keep the key in custody. Only termination
booking removes a live key; a fold never requires or releases that live output. -/
theorem only_termination_booking_transfers_custody (w w' : World) (a : AppAction) (key : Key)
    (reached : Reachable w) (accepted : appStep w a = .ok w')
    (before : (outputOfKey w key).isSome = true) (after : (outputOfKey w' key).isNone = true) :
    ∃ b ref added sigs, a = .bookTerminate b ref added sigs ∧ b.request.key = key := by
  have missing : outputOfKey w' key = none := by simpa using after
  have forbidden := List.find?_eq_none.mp missing
  cases found : outputOfKey w key with
  | none => simp [found] at before
  | some old =>
    have oldMem := List.mem_of_find?_eq_some found
    have holds := List.find?_some found
    cases a with
    | bookInsert b e sigs =>
      obtain ⟨_,_,_,_,_,_,_,_,_,_,_,_,_,economic,root,effect⟩ := (bookInsert_inversion w w' b e sigs).mp accepted
      subst w'
      exact False.elim (forbidden old oldMem holds)
    | bookTerminate b ref added sigs =>
      obtain ⟨o,economic,lookup,_,_,_,_,assets,_,_,_,_,_,_,_,_,root,effect⟩ := (bookTerminate_inversion w w' b ref added sigs).mp accepted
      by_cases same : old = o
      · subst old
        have carrying : carriesKey o.assets key = true := by simp only [Bool.and_eq_true] at holds; exact holds.2
        rw [assets] at carrying
        exact ⟨b,ref,added,sigs,rfl,(ProofSupport.carriesKey_single _ _).mp carrying⟩
      · subst w'
        exact False.elim (forbidden old ((List.mem_erase_of_ne same).mpr oldMem) holds)
    | update ref ss sigs =>
      obtain ⟨o,s,lookup,_,_,address,control,assets,_,effect⟩ := (update_inversion w w' ref ss sigs).mp accepted
      subst w'
      by_cases same : old = o
      · subst old
        have carrying : carriesKey o.assets key = true := by simp only [Bool.and_eq_true] at holds; exact holds.2
        let next : AppOutput := ⟨w.nextRef,s.address,s.lovelace,s.assets,s.envelope,o.registered⟩
        exact False.elim (forbidden next (List.mem_append_right _ (List.mem_singleton_self _)) (by simpa [next,address,assets] using carrying))
      · exact False.elim (forbidden old (List.mem_append_left _ ((List.mem_erase_of_ne same).mpr oldMem)) holds)
    | fold u tx =>
      obtain ⟨rows,economic,_,_,_,effect⟩ := (fold_inversion w w' u tx).mp accepted
      subst w'
      exact False.elim (forbidden old (List.mem_append_left _ oldMem) holds)
    | reject u r =>
      obtain ⟨economic,_,effect⟩ := (reject_inversion w w' u r).mp accepted
      subst w'
      exact False.elim (forbidden old oldMem holds)
    | bookOther r sigs => cases accepted
    | withdraw ref outs =>
      change withdrawStep w ref outs = .ok w' at accepted
      unfold withdrawStep at accepted
      cases lookup : outputAt w ref <;> simp [lookup] at accepted

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
  obtain ⟨rows,economic,selection,root,timing,effect⟩ := (fold_inversion w w' u tx).mp accepted
  subst w'
  simpa [foldStateLovelace,foldCarrierLovelace,outputLovelace,List.map_map] using Singular.Statements.fold_routes_every_amount w.economic economic (ProofSupport.root_reachable w reached) u tx root

theorem fold_consumed_requests_disappear (w w' : World) (u : EconomicUtxo) (tx : EconomicTransaction)
    (accepted : appStep w (.fold u tx) = .ok w') :
    ∀ ref ∈ selectedReferences w tx, (foldMemberAt w'.economic ref).isNone = true ∧
      (pendingOf w' ref).isNone = true := by
  obtain ⟨rows,economic,selection,root,timing,effect⟩ := (fold_inversion w w' u tx).mp accepted
  intro ref selected
  obtain ⟨i,hi,chosen⟩ := List.mem_filterMap.mp selected
  have href := Option.eq_some_of_filter_eq_some chosen
  have spent : inputsContainReference tx.transaction.inputs ref = true := by
    apply List.any_eq_true.mpr
    exact ⟨i,hi,by simp [href]⟩
  have reg : (economic.pending.find? (fun b => b.request.reference == ref)) = none := by
    rw [(Singular.foldAccepted_pending root).1]
    apply List.find?_eq_none.mpr
    intro b hb same
    have eq : b.request.reference = ref := beq_iff_eq.mp same
    have filtered := (List.mem_filter.mp hb).2
    simp [eq,spent] at filtered
  have term : (economic.terminations.find? (fun b => b.request.reference == ref)) = none := by
    rw [(Singular.foldAccepted_pending root).2]
    apply List.find?_eq_none.mpr
    intro b hb same
    have eq : b.request.reference = ref := beq_iff_eq.mp same
    have filtered := (List.mem_filter.mp hb).2
    simp [eq,spent] at filtered
  subst w'
  constructor
  · simp [foldMemberAt,reg,term]
  · have metadataNone : (w.pending.filter (fun p => !inputsContainReference tx.transaction.inputs p.reference)).find? (fun p => p.reference == ref) = none := by
      apply List.find?_eq_none.mpr
      intro p hp same
      have eq : p.reference = ref := beq_iff_eq.mp same
      have filtered := (List.mem_filter.mp hp).2
      simp [eq,spent] at filtered
    simp only [pendingOf,metadataNone]
    rfl

theorem duplicate_refused_by_registry (w : World) (u : EconomicUtxo) (tx : EconomicTransaction)
    (reached : Reachable w) (b : RegistrationBooking)
    (selected : FoldMember.registration b ∈ foldMembers w.economic tx)
    (active : trieGet w.registry.trie b.request.key = .known .active) :
    ∃ why, appStep w (.fold u tx) = .error why := by
  cases result : appStep w (.fold u tx) with
  | error why => exact ⟨why,rfl⟩
  | ok after =>
    obtain ⟨rows,economic,_,root,_,_⟩ := (fold_inversion w after u tx).mp result
    have unknown := ProofSupport.folded_registration_was_unknown root selected
    rw [active] at unknown
    contradiction

theorem resurrection_refused_by_registry (w : World) (u : EconomicUtxo) (tx : EconomicTransaction)
    (reached : Reachable w) (b : RegistrationBooking)
    (selected : FoldMember.registration b ∈ foldMembers w.economic tx)
    (terminal : trieGet w.registry.trie b.request.key = .known .terminal) :
    ∃ why, appStep w (.fold u tx) = .error why := by
  cases result : appStep w (.fold u tx) with
  | error why => exact ⟨why,rfl⟩
  | ok after =>
    obtain ⟨rows,economic,_,root,_,_⟩ := (fold_inversion w after u tx).mp result
    have unknown := ProofSupport.folded_registration_was_unknown root selected
    rw [terminal] at unknown
    contradiction

theorem fold_requires_no_application_signature (w : World) (u : EconomicUtxo) (tx : EconomicTransaction)
    (signers : List Nat) :
    appStep w (.fold u { tx with transaction := { tx.transaction with signers } }) = appStep w (.fold u tx) := by
  rfl

theorem registration_tag_binds_nonce (w w' : World) (b : RegistrationBooking) (e : Envelope) (sigs : List Nat)
    (accepted : appStep w (.bookInsert b e sigs) = .ok w') :
    ∃ tag, b.request.contents.applicationTags = [tag] ∧ tag.policy = w.registry.config.applicationPolicy ∧
      tag.edge = .insertActive ∧ tag.key = b.request.key ∧ tag.owner = b.request.refundAddress ∧
      tag.destination = b.request.destination ∧
      tag.assetName = applicationTagAssetName b.request.key b.request.refundAddress b.request.destination b.request.nonce ∧
      b.applicationTagsMinted = [tag] := by
  obtain ⟨_,_,_,_,_,_,_,_,_,_,_,_,_,economic,root,effect⟩ := (bookInsert_inversion w w' b e sigs).mp accepted
  obtain ⟨contents,minted⟩ := ProofSupport.registration_admitted (ProofSupport.book_checks root).1
  simp only [exactContents, Bool.and_eq_true, decide_eq_true_eq] at contents
  have shape := contents.1.1
  cases tags : b.request.contents.applicationTags with
  | nil => simp [registrationContentsShape,tags] at shape
  | cons tag rest =>
    cases rest with
    | nil =>
      simp only [registrationContentsShape,tags,Bool.and_eq_true] at shape
      have h := shape.2
      simp only [registrationApplicationTagValid,decide_eq_true_eq] at h
      exact ⟨tag,rfl,h.1,h.2.1,h.2.2.1,h.2.2.2.1,h.2.2.2.2.1,h.2.2.2.2.2,by simpa [tags] using minted⟩
    | cons other rest => simp [registrationContentsShape,tags] at shape

theorem termination_has_no_application_tag_or_clock (w w' : World) (b : TerminationBooking) (ref added : Nat)
    (sigs : List Nat) (accepted : appStep w (.bookTerminate b ref added sigs) = .ok w') :
    b.request.contents.applicationTags = [] ∧ b.request.refundAddress = none ∧ b.request.submittedAt = none ∧
      b.request.singularTags = [w.registry.config.singularTag b.request.key] ∧
      b.request.contents.trieReadyTags = [b.request.trieReadyTag w.registry.config] := by
  obtain ⟨o,economic,found,pin,policy,name,address,assets,key,registry,active,snapshot,signer,destination,custody,value,root,effect⟩ := (bookTerminate_inversion w w' b ref added sigs).mp accepted
  have contents := (Singular.Statements.termination_booking_has_exact_contents w.registry b (ProofSupport.bookTermination_checks root).1).2.2.2.2.2.2.2.2
  simp only [terminationExactContents, terminationContentsShape, Bool.and_eq_true, decide_eq_true_eq] at contents
  exact ⟨contents.1.2.2.2.2,contents.1.2.2.1,contents.1.2.2.2.1,contents.2.2.1,contents.2.2.2.2⟩

/-- All actual value goes into the request. The equation allocates zero of V to
controller refund or surplus routing. It does not prohibit unrelated ordinary
payments to the controller address, which booking does not model. -/
theorem termination_booking_has_no_controller_payout (w w' : World) (b : TerminationBooking) (ref added : Nat)
    (sigs : List Nat) (accepted : appStep w (.bookTerminate b ref added sigs) = .ok w') :
    ∃ o, outputAt w ref = some o ∧ b.request.contents.lovelace = o.lovelace + added ∧
      w'.outputs = w.outputs.erase o ∧ w'.economic.treasury = w.economic.treasury := by
  obtain ⟨o,economic,found,pin,policy,name,address,assets,key,registry,active,snapshot,signer,destination,custody,value,root,effect⟩ := (bookTerminate_inversion w w' b ref added sigs).mp accepted
  have economicEffect := (ProofSupport.bookTermination_checks root).2
  subst w'
  refine ⟨o,found,value,rfl,?_⟩
  rw [economicEffect]

theorem termination_booking_value_transfer (w w' : World) (b : TerminationBooking) (ref added : Nat)
    (sigs : List Nat) (accepted : appStep w (.bookTerminate b ref added sigs) = .ok w') :
    ∃ o, outputAt w ref = some o ∧ b.request.contents.lovelace = o.lovelace + added ∧
      b.request.contents.lovelace = b.request.declaredTip + b.request.carrierAda ∧
      w.registry.config.minimumTip ≤ b.request.declaredTip := by
  obtain ⟨o,economic,found,pin,policy,name,address,assets,key,registry,active,snapshot,signer,destination,custody,value,root,effect⟩ := (bookTerminate_inversion w w' b ref added sigs).mp accepted
  have contents := (Singular.Statements.termination_booking_has_exact_contents w.registry b (ProofSupport.bookTermination_checks root).1).2.2.2.2.2.2.2.2
  simp only [terminationExactContents, terminationContentsShape, Bool.and_eq_true, decide_eq_true_eq] at contents
  exact ⟨o,found,value,contents.2.2.2.1,contents.1.1⟩

theorem pending_termination_cannot_be_rebooked_or_updated (w : World) (b : TerminationBooking)
    (reached : Reachable w) (pending : b ∈ w.economic.terminations) :
    (outputOfKey w b.request.key).isNone = true ∧
      ∀ next ref added sigs, next.request.key = b.request.key →
        ∃ why, appStep w (.bookTerminate next ref added sigs) = .error why := by
  have hc := reachable_consistent w reached
  refine ⟨ProofSupport.output_key_none w b.request.key hc (ProofSupport.pending_key_not_output w hc b pending),?_⟩
  intro next ref added sigs same
  cases result : appStep w (.bookTerminate next ref added sigs) with
  | error why => exact ⟨why,rfl⟩
  | ok after =>
    obtain ⟨o,economic,found,_,_,_,_,_,key,rest⟩ := (bookTerminate_inversion w after next ref added sigs).mp result
    have ne := ProofSupport.pending_key_not_output w hc b pending o (List.mem_of_find?_eq_some found)
    exact False.elim (ne (key.trans same))

theorem application_root_world_correspondence (w : World) (reached : Reachable w) :
    Singular.WorldReachable w.economic ∧ CustodyCorrespondence w := by
  exact ⟨ProofSupport.root_reachable w reached,(reachable_consistent w reached).2.2.2.2.1⟩

theorem application_supply_spans_custody_and_pending (w : World) (reached : Reachable w) (key : Key) :
    (w.outputs.filter (fun o => o.envelope.control.key == key)).length + carriedSingularCount w.economic key =
      if trieGet w.registry.trie key = .known .active then 1 else 0 := by
  have hc := reachable_consistent w reached
  rw [ProofSupport.output_count_eq_kind w hc key]
  exact (ProofSupport.consistent_world_supply w hc).1 key

/-- The selected termination's contribution is H-T; total donation also includes
other selected requests. The theorem deliberately imposes no protected floor. -/
theorem termination_fold_donates_held_minus_tip (w w' : World) (u : EconomicUtxo) (tx : EconomicTransaction)
    (b : TerminationBooking) (accepted : appStep w (.fold u tx) = .ok w')
    (selected : FoldMember.termination b ∈ foldMembers w.economic tx) :
    (FoldMember.termination b).donation = b.request.contents.lovelace - b.request.declaredTip ∧
      tx.transaction.donation = ((foldMembers w.economic tx).map FoldMember.donation).sum ∧
      w'.economic.treasury = w.economic.treasury + tx.transaction.donation := by
  obtain ⟨rows,economic,selection,root,timing,effect⟩ := (fold_inversion w w' u tx).mp accepted
  obtain ⟨prerequisite,result,registry,routing,economicEffect⟩ := Singular.foldAccepted_checks root
  have donation := (Singular.foldRouting_accounting routing).1
  subst w'
  rw [economicEffect]
  exact ⟨rfl,donation,rfl⟩

/-- No expiry predicate for a termination at fold, and no expiry rejection. -/
theorem termination_has_no_expiry (w : World) (b : TerminationBooking) (interval : Interval) :
    foldMemberRefusal w.registry.config interval (.termination b) = none ∧
      terminationRejectionGround w.economic b.request .expired = some "reject-termination-no-expiry" ∧
      terminationFoldTiming w.economic interval b = none ∧
      (∀ u tx after, Singular.foldAccepted w.economic u tx = .ok after →
        applicationFoldDecision w.economic u tx = .ok after) ∧
      (∀ u rejection, Singular.rejectionAccepted w.economic u rejection = .error "reject-termination-no-expiry" →
        applicationRejectionDecision w.economic u rejection = .error "reject-termination-no-expiry") := by
  refine ⟨rfl, rfl, rfl, ?_, ?_⟩
  · intro u tx after accepted
    rw [ProofSupport.fold_decision_eq_root]
    exact accepted
  · intro u rejection accepted
    exact accepted

theorem termination_fold_timing_equivalent_root (world : Singular.World) (interval : Interval)
    (booking : TerminationBooking) :
    terminationFoldTiming world interval booking =
      Singular.foldMemberRefusal world.registry.config interval (.termination booking) := by
  rfl

theorem application_fold_decision_equivalent_root (world : Singular.World) (u : EconomicUtxo)
    (tx : EconomicTransaction) :
    applicationFoldDecision world u tx = Singular.foldAccepted world u tx := by
  exact ProofSupport.fold_decision_eq_root world u tx

theorem application_rejection_decision_equivalent_root (world : Singular.World) (u : EconomicUtxo)
    (rejection : Rejection) :
    applicationRejectionDecision world u rejection = Singular.rejectionAccepted world u rejection := by
  rfl

theorem selected_request_refs_distinct (w w' : World) (u : EconomicUtxo) (tx : EconomicTransaction)
    (accepted : appStep w (.fold u tx) = .ok w') : (selectedReferences w tx).Nodup := by
  obtain ⟨rows,economic,selection,root,timing,effect⟩ := (fold_inversion w w' u tx).mp accepted
  have distinct := (Singular.foldPrerequisite_observations (Singular.foldAccepted_checks root).1).2.1
  unfold selectedReferences
  apply List.Pairwise.filterMap _ ?_ (List.pairwise_map.mp distinct)
  intro a a' ne ref href ref' href' eq
  apply ne
  have ha := Option.eq_some_of_filter_eq_some href
  have hb := Option.eq_some_of_filter_eq_some href'
  rw [ha,hb,eq]

/-- All pending terminations survive every accepted rejection, regardless of
which unrelated registrations it lawfully consumes. -/
theorem rejection_preserves_pending_terminations (w w' : World) (u : EconomicUtxo) (r : Rejection)
    (accepted : appStep w (.reject u r) = .ok w') :
    w'.economic.terminations = w.economic.terminations ∧ w'.outputs = w.outputs := by
  obtain ⟨economic,root,effect⟩ := (reject_inversion w w' u r).mp accepted
  have economicEffect := Singular.rejectionAccepted_effect root
  subst w'
  rw [economicEffect]
  exact ⟨rfl,rfl⟩
theorem registration_allocations_are_distinct (w w' : World) (b : RegistrationBooking) (e : Envelope)
    (sigs : List Nat) (accepted : appStep w (.bookInsert b e sigs) = .ok w') :
    b.request.contents.lovelace = b.request.registrationCost + b.request.declaredTip + b.request.carrierAda ∧
      b.request.registrationCost = w.registry.config.registrationCost ∧
      b.request.carrierAda = e.control.deposit ∧ w.registry.config.minimumTip ≤ b.request.declaredTip := by
  obtain ⟨_,_,_,_,_,_,_,_,_,_,_,_,deposit,economic,root,effect⟩ := (bookInsert_inversion w w' b e sigs).mp accepted
  have contents := (ProofSupport.registration_admitted (ProofSupport.book_checks root).1).1
  simp only [exactContents, registrationContentsShape, Bool.and_eq_true, decide_eq_true_eq] at contents
  exact ⟨contents.1.2,contents.1.1.1.2.1,deposit.symm,contents.1.1.1.2.2.1⟩


/-- Exact dispatcher calls under the supplied law. These additive obligations
remain STATED at this checkpoint; proofs require a separate release. -/
theorem appStepWith_bookInsert (law : Law) (w : World) (b : RegistrationBooking)
    (e : Envelope) (sigs : List Nat) :
    appStepWith law w (.bookInsert b e sigs) = bookInsertStep law w b e sigs := by
  rfl

theorem appStepWith_bookTerminate (law : Law) (w : World) (b : TerminationBooking)
    (ref added : Nat) (sigs : List Nat) :
    appStepWith law w (.bookTerminate b ref added sigs) = bookTerminateStep law w b ref added sigs := by
  rfl

theorem appStepWith_bookOther (law : Law) (w : World) (r : Request) (sigs : List Nat) :
    appStepWith law w (.bookOther r sigs) = bookOtherStep r := by
  rfl

theorem appStepWith_update (law : Law) (w : World) (ref : Nat)
    (successors : List Successor) (sigs : List Nat) :
    appStepWith law w (.update ref successors sigs) = updateStep law w ref successors sigs := by
  rfl

theorem appStepWith_fold (law : Law) (w : World) (u : EconomicUtxo) (tx : EconomicTransaction) :
    appStepWith law w (.fold u tx) = foldEffect law w u tx := by
  rfl

theorem appStepWith_reject (law : Law) (w : World) (u : EconomicUtxo) (r : Rejection) :
    appStepWith law w (.reject u r) = rejectStep w u r := by
  rfl

theorem appStepWith_withdraw (law : Law) (w : World) (ref : Nat) (outputs : List TxOutput) :
    appStepWith law w (.withdraw ref outputs) = withdrawStep w ref outputs := by
  rfl

end OpenDatumApplication.Statements
