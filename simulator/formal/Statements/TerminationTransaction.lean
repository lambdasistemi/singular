import Singular.Lemmas
import Singular.Driver
import Singular.Economics
import Singular.Statements.Preservation
import Singular.Statements.Inversions

/-! The complete termination transaction proposition without a tip-cover premise. -/

namespace Singular.Statements

/-- **#177 retirement-transaction-and-burn-source** — the transaction an admitted `updateTerminal` builds.

Retirement is the first edge whose mint is negative, so it is the first whose
tokens have to come from somewhere. The conclusion is one equation on the value
`txOf` constructs from the executed step. It spends three inputs — the
registry's single state UTxO under an inline datum; a request UTxO carrying
exactly one approval and the declared input lovelace; and the witness UTxO
holding this key's one active token, spent so the burn has a source — and
produces two outputs: the state UTxO moved, still carrying one state token under
an inline datum, whose eight-field configuration differs from the input's in the
root alone and whose root commits a map where the key now reads `Terminal`; and
an output paying the request's owner the deposit back, since a retirement
delivers nothing, with no datum and naming the approval it returns. There is no
destination output: a burn routes no token to the requester (#304). The mint is `-1` at
`(activePolicy, key)` and nothing else, the transaction's one payment is that
deposit, to the owner, and the signer set is empty.

The burned token is this key's own: before the fold the key has exactly one
active witness and after it has none, and the asset the witness input carries is
the `(active, key)` the mint destroys — not another key's token, and not a burn
with nothing to burn.

No signature is required, stated as invariance of the whole transaction under
the approval's signature set. Retirement completes: a second `updateTerminal` at
the same key builds no transaction, it is refused `terminal-immutable`. None
exists for a key that reads `Unknown` (`key-unknown`) or one only witnessed
absent (`not-booked`); each refusal is stated over an arbitrary state and
exhibited at the very state of this fold with that key's leaf moved, so no arm
is vacuous. The `token-missing` guard is exhibited the same way, at this state
with its held witnesses removed. That last one is a guard against an unreachable
state rather than a story: under `Reachable`, `biconditional_supply_sync` makes
a `Known Active` leaf and exactly one outstanding active token the same fact. -/
theorem update_terminal_transaction_row (s : RegistryState) (r : Request) (t : Result)
    (ap : Approval) (lovelace : Nat) (h : Reachable s) (he : r.edge = .updateTerminal)
    (hap : r.approval = some ap) (hok : step s r = .ok t) :
    txOf s r lovelace =
      .ok { inputs :=
              [ { role := .state, datum := .inline, stateTokens := 1
                , approvals := 0, lovelace := 0, assets := [] }
              , { role := .request, datum := .inline, stateTokens := 0
                , approvals := 1, lovelace := lovelace, assets := [] }
              , { role := .witness, datum := heldDatum s r.key .active, stateTokens := 0
                , approvals := 0, lovelace := 0
                , assets := [((.active, r.key), 1)]
                , datumValue := heldValue s r.key .active } ]
          , outputs :=
              [ { role := .state, datum := .inline, address := none, stateTokens := 1
                , config := some t.state.config, commitment := none, assets := []
                , stateToken := some t.state.config.stateToken }
              , { role := .owner, datum := .none, address := some r.owner
                , stateTokens := 0, config := none, commitment := some ap.assetName
                , assets := [], lovelace := r.deposit } ]
          , mint := [((.active, r.key), -1)]
          , signers := []
          , refunds := [(r.owner, r.deposit)] } ∧
    kindCount s .active r.key = 1 ∧
    (∃ w ∈ s.held, w.key = r.key ∧ w.kind = .active) ∧
    kindCount t.state .active r.key = 0 ∧
    destinationDatumBinds r = true ∧
    onlyRootChanged s.config t.state.config = true ∧
    t.state.config.root = rootOf t.state.trie ∧
    trieGet t.state.trie r.key = .known .terminal ∧
    t.state.custody = s.custody ∧
    kindPolicy s.config .active = s.config.activePolicy ∧
    tokenAssetName .active r.key = r.key ∧
    (∀ sigs : List (List Nat),
        txOf s { r with approval := some { ap with signatures := sigs } } lovelace
          = txOf s r lovelace) ∧
    (∀ r₂ : Request, r₂.edge = .updateTerminal → r₂.key = r.key →
        admitsFor t.state.config r₂ r₂.approval = true →
        txOf t.state r₂ lovelace = .error "terminal-immutable") ∧
    (∀ (s' : RegistryState) (r' : Request), r'.edge = .updateTerminal →
        trieGet s'.trie r'.key = .unknown →
        admitsFor s'.config r' r'.approval = true →
        txOf s' r' lovelace = .error "key-unknown") ∧
    (∀ (s' : RegistryState) (r' : Request), r'.edge = .updateTerminal →
        trieGet s'.trie r'.key = .known .absent →
        admitsFor s'.config r' r'.approval = true →
        txOf s' r' lovelace = .error "not-booked") ∧
    (∀ (s' : RegistryState) (r' : Request), r'.edge = .updateTerminal →
        trieGet s'.trie r'.key = .known .active →
        s'.held.any (fun x => x.key == r'.key && x.kind == .active) = false →
        admitsFor s'.config r' r'.approval = true →
        txOf s' r' lovelace = .error "token-missing") ∧
    txOf { s with trie := trieErase s.trie r.key } r lovelace
      = .error "key-unknown" ∧
    txOf { s with trie := trieSet s.trie r.key (.known .absent) } r lovelace
      = .error "not-booked" ∧
    txOf { s with held := [] } r lovelace = .error "token-missing" := by
  obtain ⟨hbefore, hpres, ⟨ap', hap', hpol, hedge, hkey, hown, hdst, hasset⟩, htrie, hcfg,
    hcust, hheld, hmint, hpaid⟩ := (update_terminal_inversion s r t he).mp hok
  have hapeq : ap' = ap := Option.some.inj (hap'.symm.trans hap)
  rw [hapeq] at hpol hedge hkey hown hdst hasset
  -- admission, reassembled so the refusal rows can be stated at other states
  have hadm : admitsFor s.config r r.approval = true := by
    unfold admitsFor
    rw [hap]
    simp only [he]
    simp only [Bool.and_eq_true, beq_iff_eq]
    exact ⟨⟨⟨⟨⟨hpol, by rw [hedge, he]⟩, hkey⟩, hown⟩, hdst⟩, hasset⟩
  -- the complement of the updateTerminal row, computed once
  have hrefusalOf : ∀ (s' : RegistryState) (r' : Request), r'.edge = .updateTerminal →
      admitsFor s'.config r' r'.approval = true →
      refusal s' r' =
        (match trieGet s'.trie r'.key with
         | .unknown => some "key-unknown"
         | .known .absent => some "not-booked"
         | .known .terminal => some "terminal-immutable"
         | .known .active =>
             if s'.held.any (fun x => x.key == r'.key && x.kind == .active) then none
             else some "token-missing") := by
    intro s' r' he' hadm'
    cases hb : trieGet s'.trie r'.key <;>
      (try (rename_i st; cases st)) <;>
      cases hap₂ : r'.approval <;>
      cases hac : s'.held.any (fun x => x.key == r'.key && x.kind == .active) <;>
      simp +decide [refusal, he', hb, hap₂, hac, admitsFor] at hadm' ⊢ <;>
      grind
  have hrefuseTx : ∀ (s' : RegistryState) (r' : Request) (why : String),
      refusal s' r' = some why → txOf s' r' lovelace = .error why := by
    intro s' r' why hr
    exact txOf_of_step_error _ _ _ _ (error_of_refusal _ _ _ hr)
  -- the source of the burn: the key's unique active witness
  have hone : kindCount s .active r.key = 1 := (active_witness_unique s h r.key).2.mpr hbefore
  have hwitness : ∃ w ∈ s.held, w.key = r.key ∧ w.kind = .active := by
    obtain ⟨w, hw, hcond⟩ := List.any_eq_true.mp hpres
    obtain ⟨h1, h2⟩ := Bool.and_eq_true_iff.mp hcond
    exact ⟨w, hw, by simpa using h1, by simpa using h2⟩
  have hgone : kindCount t.state .active r.key = 0 := by
    unfold kindCount
    rw [hheld]
    exact countHeld_filter_active_zero s.held r.key
  have hterminal : trieGet t.state.trie r.key = .known .terminal := by
    rw [htrie, trieGet_set_eq]
  -- the transaction itself
  have hdest : requestDestination r = r.output := by
    unfold requestDestination; simp [he]
  have happrovals : approvalsIn r = 1 := by rw [approvalsIn, hap]; rfl
  have hbind : datumHash (destinationDatum r) = ap.assetName := by
    unfold datumHash destinationDatum
    rw [hasset, hedge, hkey, hown, hdst]
  have hrouted : routedPayment t r .requestOutput = [] := by
    unfold routedPayment mintRoutedTo; rw [hmint]; simp [route]
  have hcage : txCageOutputs t r = [] := by
    unfold txCageOutputs routedPayment mintRoutedTo; rw [hmint]; simp [route]
  have hburn : txBurnInputs s t r =
      [ { role := .witness, datum := heldDatum s r.key .active, stateTokens := 0
        , approvals := 0, lovelace := 0
        , assets := [((TokenKind.active, r.key), 1)]
        , datumValue := heldValue s r.key .active } ] := by
    unfold txBurnInputs; rw [hmint]; simp [route, burnSourceRole, burnSourceDatum, burnSourceValue]
  have htx : txOf s r lovelace =
      .ok { inputs :=
              [ { role := .state, datum := .inline, stateTokens := 1
                , approvals := 0, lovelace := 0, assets := [] }
              , { role := .request, datum := .inline, stateTokens := 0
                , approvals := 1, lovelace := lovelace, assets := [] }
              , { role := .witness, datum := heldDatum s r.key .active, stateTokens := 0
                , approvals := 0, lovelace := 0
                , assets := [((.active, r.key), 1)]
                , datumValue := heldValue s r.key .active } ]
          , outputs :=
              [ { role := .state, datum := .inline, address := none, stateTokens := 1
                , config := some t.state.config, commitment := none, assets := []
                , stateToken := some t.state.config.stateToken }
              , { role := .owner, datum := .none, address := some r.owner
                , stateTokens := 0, config := none, commitment := some ap.assetName
                , assets := [], lovelace := r.deposit } ]
          , mint := [((.active, r.key), -1)]
          , signers := []
          , refunds := [(r.owner, r.deposit)] } := by
    rw [txOf_of_step_ok s r lovelace t hok]
    simp [he, hap, obligations, owedTo, ownerOutputs, paymentPaid, txStateOutput,
      txDestinationOutputs, hcage, hburn, happrovals, hdest, hrouted, hpaid, hmint,
      requiredSigners, registryDatumForm, registryStateTokens]
  -- no signature is read
  have hstep : ∀ sigs : List (List Nat),
      step s { r with approval := some { ap with signatures := sigs } } = .ok t := by
    intro sigs
    refine (update_terminal_inversion s _ t (by simpa using he)).mpr ?_
    refine ⟨by simpa using hbefore, by simpa using hpres,
      ⟨{ ap with signatures := sigs }, rfl, by simpa using hpol, by simpa using hedge,
        by simpa using hkey, by simpa using hown, by simpa using hdst, by simpa using hasset⟩,
      by simpa using htrie, by simpa using hcfg, hcust, by simpa using hheld,
      by simpa using hmint, hpaid⟩
  have hsigtx : ∀ sigs : List (List Nat),
      txOf s { r with approval := some { ap with signatures := sigs } } lovelace
        = txOf s r lovelace := by
    intro sigs
    rw [htx, txOf_of_step_ok _ _ lovelace t (hstep sigs)]
    have ha : approvalsIn { r with approval := some { ap with signatures := sigs } } = 1 := by
      rw [approvalsIn]; rfl
    have hd : requestDestination { r with approval := some { ap with signatures := sigs } }
        = r.output := by unfold requestDestination; simp [he]
    have hr : routedPayment t { r with approval := some { ap with signatures := sigs } }
        .requestOutput = [] := by
      unfold routedPayment mintRoutedTo; rw [hmint]; simp [route]
    have hc : txCageOutputs t { r with approval := some { ap with signatures := sigs } } = [] := by
      unfold txCageOutputs routedPayment mintRoutedTo; rw [hmint]; simp [route]
    have hbi : txBurnInputs s t { r with approval := some { ap with signatures := sigs } } =
        [ { role := .witness, datum := heldDatum s r.key .active, stateTokens := 0
          , approvals := 0, lovelace := 0
          , assets := [((TokenKind.active, r.key), 1)]
          , datumValue := heldValue s r.key .active } ] := by
      unfold txBurnInputs; rw [hmint]; simp [route, burnSourceRole, burnSourceDatum, burnSourceValue]
    have hb : datumHash (destinationDatum
        { r with approval := some { ap with signatures := sigs } }) = ap.assetName := by
      unfold datumHash destinationDatum
      simp only [hd]
      rw [hasset, hedge, hkey, hown, hdst, hdest]
    simp only [txStateOutput, txDestinationOutputs, hc, hbi, ha, hd, hr, hb, hpaid, hmint,
      requiredSigners, registryDatumForm, registryStateTokens]
    simp [he, obligations, owedTo, ownerOutputs, paymentPaid]
  -- retirement completes, and the two leaves that never admit it
  have himmutable : ∀ r₂ : Request, r₂.edge = .updateTerminal → r₂.key = r.key →
      admitsFor t.state.config r₂ r₂.approval = true →
      txOf t.state r₂ lovelace = .error "terminal-immutable" := by
    intro r₂ he₂ hk₂ hadm₂
    refine hrefuseTx _ _ _ ?_
    rw [hrefusalOf t.state r₂ he₂ hadm₂, hk₂, hterminal]
  have hunknown : ∀ (s' : RegistryState) (r' : Request), r'.edge = .updateTerminal →
      trieGet s'.trie r'.key = .unknown →
      admitsFor s'.config r' r'.approval = true →
      txOf s' r' lovelace = .error "key-unknown" := by
    intro s' r' he' hl hadm'
    exact hrefuseTx _ _ _ (by rw [hrefusalOf s' r' he' hadm', hl])
  have hnotbooked : ∀ (s' : RegistryState) (r' : Request), r'.edge = .updateTerminal →
      trieGet s'.trie r'.key = .known .absent →
      admitsFor s'.config r' r'.approval = true →
      txOf s' r' lovelace = .error "not-booked" := by
    intro s' r' he' hl hadm'
    exact hrefuseTx _ _ _ (by rw [hrefusalOf s' r' he' hadm', hl])
  have hmissing : ∀ (s' : RegistryState) (r' : Request), r'.edge = .updateTerminal →
      trieGet s'.trie r'.key = .known .active →
      s'.held.any (fun x => x.key == r'.key && x.kind == .active) = false →
      admitsFor s'.config r' r'.approval = true →
      txOf s' r' lovelace = .error "token-missing" := by
    intro s' r' he' hl hno hadm'
    refine hrefuseTx _ _ _ ?_
    rw [hrefusalOf s' r' he' hadm', hl]
    simp [hno]
  exact ⟨htx, hone, hwitness, hgone,
    by simp [destinationDatumBinds, hap, hbind],
    by simp [onlyRootChanged, hcfg], by rw [hcfg, htrie], hterminal, hcust, rfl, rfl,
    hsigtx, himmutable, hunknown, hnotbooked, hmissing,
    hunknown _ r he (by simp) hadm,
    hnotbooked _ r he (by simp) hadm,
    hmissing _ r he (by simpa using hbefore) (by simp) (by simpa using hadm)⟩


end Singular.Statements
