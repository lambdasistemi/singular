import Singular.Lemmas
import Singular.Driver
import Singular.Economics
import Singular.Statements.Preservation
import Singular.Statements.Inversions

/-! The complete registration transaction proposition without a tip-cover premise. -/

namespace Singular.Statements

/-- **#173 registration-transaction-and-keyed-mint** — the transaction an admitted `insertActive` builds.

The conclusion is one equation on the transaction `txOf` constructs from the
executed step, so every clause quantifies over a built value rather than over a
nullary constant. It spends two inputs — the registry's single state UTxO under
an inline datum, and a request UTxO carrying exactly one approval and the
declared input lovelace — and produces exactly two outputs: the state UTxO
moved, still carrying one state token under an inline datum, whose eight-field
configuration differs from the input's in the root alone and whose root commits
the map the fold produced; and a destination output routed to the address the
request named, presenting the very commitment the approval the fold verified
carries, holding exactly one active token and the deposit, and carrying the
datum the request named — inline when it names one, none when it names none, as
the chain requires. The
mint is `+1` at `(activePolicy, key)` and nothing else, the transaction's one
payment is that deposit, to the destination, and the signer set is empty.

No signature is required, stated as invariance of the whole transaction under
the approval's signature set. A second `insertActive` at the same key builds no
transaction at all: it is refused `key-exists`. The open application is
unparameterised and admits every tuple, and cross-registry separation is a named
non-goal — registries pinning the same open policy reach the same verdict on the
same approval. -/
theorem insert_active_transaction_row (s : RegistryState) (r : Request) (t : Result)
    (ap : Approval) (lovelace : Nat) (h : Reachable s) (he : r.edge = .insertActive)
    (hap : r.approval = some ap) (hok : step s r = .ok t) :
    txOf s r lovelace =
      .ok { inputs :=
              [ { role := .state, datum := .inline, stateTokens := 1
                , approvals := 0, lovelace := 0 }
              , { role := .request, datum := .inline, stateTokens := 0
                , approvals := 1, lovelace := lovelace } ]
          , outputs :=
              [ { role := .state, datum := .inline, address := none, stateTokens := 1
                , config := some t.state.config, commitment := none, assets := []
                , stateToken := some t.state.config.stateToken }
              , { role := .destination, datum := datumFormOf r.datum
                , address := some r.output
                , stateTokens := 0, config := none, commitment := some ap.assetName
                , assets := [((.active, r.key), 1)], lovelace := r.deposit, datumValue := r.datum } ]
          , mint := [((.active, r.key), 1)]
          , signers := []
          , refunds := [(r.output, r.deposit)] } ∧
    destinationDatumBinds r = true ∧
    onlyRootChanged s.config t.state.config = true ∧
    t.state.config.root = rootOf t.state.trie ∧
    t.state.custody = s.custody ∧
    kindCount t.state .active r.key = 1 ∧
    ({ key := r.key, kind := .active, output := r.output
      , datum := r.datum } : Holding) ∈ t.state.held ∧
    kindPolicy s.config .active = s.config.activePolicy ∧
    tokenAssetName .active r.key = r.key ∧
    openPolicyParameters = [] ∧
    (∀ sigs : List (List Nat),
        txOf s { r with approval := some { ap with signatures := sigs } } lovelace
          = txOf s r lovelace) ∧
    (∀ r₂ : Request, r₂.edge = .insertActive → r₂.key = r.key →
        admitsFor t.state.config r₂ r₂.approval = true →
        txOf t.state r₂ lovelace = .error "key-exists") ∧
    (∀ (c : Config) (q : Request), admitsFor c q (some (openApproval c q)) = true) ∧
    (∀ (c₁ c₂ : Config) (q : Request) (a : Option Approval),
        c₁.applicationPolicy = c₂.applicationPolicy →
        admitsFor c₁ q a = admitsFor c₂ q a) := by
  obtain ⟨hfree, ⟨ap', hap', hpol, hedge, hkey, hown, hdst, hasset⟩, htrie, hcfg, hcust,
    hheld, hmint, hpaid⟩ := (insert_active_inversion s r t he).mp hok
  have hapeq : ap' = ap := Option.some.inj (hap'.symm.trans hap)
  rw [hapeq] at hpol hedge hkey hown hdst hasset
  have hadmits : ∀ (c : Config) (q : Request), admitsFor c q (some (openApproval c q)) = true := by
    intro c q
    unfold admitsFor openApproval
    cases hq : q.edge <;> simp [hq, requestDestination, approvalAssetName]
  have hcross : ∀ (c₁ c₂ : Config) (q : Request) (a : Option Approval),
      c₁.applicationPolicy = c₂.applicationPolicy → admitsFor c₁ q a = admitsFor c₂ q a := by
    intro c₁ c₂ q a hc
    unfold admitsFor
    cases q.edge <;> cases a <;> simp [hc]
  have hbind : datumHash (destinationDatum r) = ap.assetName := by
    unfold datumHash destinationDatum
    rw [hasset, hedge, hkey, hown, hdst]
  have hzero : kindCount s .active r.key = 0 := by
    obtain ⟨hle, hiff⟩ := active_witness_unique s h r.key
    rcases Nat.lt_or_ge (kindCount s .active r.key) 1 with hlt | hge
    · omega
    · exfalso
      have h1 : kindCount s .active r.key = 1 := by omega
      rw [hfree] at hiff
      exact Leaf.noConfusion (hiff.mp h1)
  have hcount : kindCount t.state .active r.key = 1 := by
    unfold kindCount
    rw [hheld, countHeld_cons]
    simp only [beq_self_eq_true, Bool.and_self, if_pos]
    have hz : (s.held.filter fun x => x.key == r.key && x.kind == TokenKind.active).length = 0 := hzero
    omega
  have hstep : ∀ sigs : List (List Nat),
      step s { r with approval := some { ap with signatures := sigs } } = .ok t := by
    intro sigs
    refine (insert_active_inversion s _ t (by simpa using he)).mpr ?_
    refine ⟨by simpa using hfree,
      ⟨{ ap with signatures := sigs }, rfl, by simpa using hpol, by simpa using hedge,
        by simpa using hkey, by simpa using hown, by simpa using hdst, by simpa using hasset⟩,
      by simpa using htrie, by simpa using hcfg, hcust, by simpa using hheld,
      by simpa using hmint, hpaid⟩
  have hsecond : ∀ r₂ : Request, r₂.edge = .insertActive → r₂.key = r.key →
      admitsFor t.state.config r₂ r₂.approval = true →
      step t.state r₂ = .error "key-exists" := by
    intro r₂ he₂ hk₂ hadm₂
    have hbefore : trieGet t.state.trie r₂.key = .known .active := by
      rw [hk₂, htrie, trieGet_set_eq]
    cases hopt : r₂.approval with
    | none =>
      rw [hopt] at hadm₂
      unfold admitsFor at hadm₂
      simp at hadm₂
    | some a₂ =>
      have hadm₂' : admitsFor t.state.config r₂ (some a₂) = true := by rw [← hopt]; exact hadm₂
      have hpol₂ : a₂.policy = t.state.config.applicationPolicy := by
        unfold admitsFor at hadm₂'
        simp only [Bool.and_eq_true, beq_iff_eq] at hadm₂'
        exact hadm₂'.1.1.1.1.1
      refine error_of_refusal _ _ _ ?_
      unfold refusal
      simp only [he₂, allowed, hopt, hbefore, hadm₂', hpol₂, bne_self_eq_false, Bool.not_true,
        Bool.false_eq_true, if_false, reduceIte]
      simp
  -- the transaction itself
  have hdest : requestDestination r = r.output := by
    unfold requestDestination; simp [he]
  have happrovals : approvalsIn r = 1 := by rw [approvalsIn, hap]; rfl
  have hrouted : routedPayment t r .requestOutput = [((TokenKind.active, r.key), 1)] := by
    unfold routedPayment mintRoutedTo; rw [hmint]; simp [route] <;> decide
  have hcage : txCageOutputs t r = [] := by
    unfold txCageOutputs routedPayment mintRoutedTo; rw [hmint]; simp [route] <;> decide
  have hburn : txBurnInputs s t r = [] := by
    unfold txBurnInputs; rw [hmint]; simp
  have htx : txOf s r lovelace =
      .ok { inputs :=
              [ { role := .state, datum := .inline, stateTokens := 1
                , approvals := 0, lovelace := 0 }
              , { role := .request, datum := .inline, stateTokens := 0
                , approvals := 1, lovelace := lovelace } ]
          , outputs :=
              [ { role := .state, datum := .inline, address := none, stateTokens := 1
                , config := some t.state.config, commitment := none, assets := []
                , stateToken := some t.state.config.stateToken }
              , { role := .destination, datum := datumFormOf r.datum
                , address := some r.output
                , stateTokens := 0, config := none, commitment := some ap.assetName
                , assets := [((.active, r.key), 1)], lovelace := r.deposit, datumValue := r.datum } ]
          , mint := [((.active, r.key), 1)]
          , signers := []
          , refunds := [(r.output, r.deposit)] } := by
    rw [txOf_of_step_ok s r lovelace t hok]
    simp [he, obligations, owedTo, ownerOutputs, paymentPaid, txStateOutput,
      txDestinationOutputs, deliveredDatum, hcage, hburn, happrovals, hdest, hrouted, hbind, hpaid, hmint,
      requiredSigners, registryDatumForm, registryStateTokens]
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
        .requestOutput = [((TokenKind.active, r.key), 1)] := by
      unfold routedPayment mintRoutedTo; rw [hmint]; simp [route] <;> decide
    have hc : txCageOutputs t { r with approval := some { ap with signatures := sigs } } = [] := by
      unfold txCageOutputs routedPayment mintRoutedTo; rw [hmint]; simp [route] <;> decide
    have hbi : txBurnInputs s t { r with approval := some { ap with signatures := sigs } } = [] := by
      unfold txBurnInputs; rw [hmint]; simp
    have hb : datumHash (destinationDatum
        { r with approval := some { ap with signatures := sigs } }) = ap.assetName := by
      unfold datumHash destinationDatum
      simp only [hd]
      rw [hasset, hedge, hkey, hown, hdst, hdest]
    simp only [txStateOutput, txDestinationOutputs, deliveredDatum, hc, hbi, ha, hd, hr, hb, hpaid, hmint,
      requiredSigners, registryDatumForm, registryStateTokens]
    simp [he, obligations, owedTo, ownerOutputs, paymentPaid, requestDestination]
  have hsecondtx : ∀ r₂ : Request, r₂.edge = .insertActive → r₂.key = r.key →
      admitsFor t.state.config r₂ r₂.approval = true →
      txOf t.state r₂ lovelace = .error "key-exists" := by
    intro r₂ he₂ hk₂ hadm₂
    exact txOf_of_step_error _ _ _ _ (hsecond r₂ he₂ hk₂ hadm₂)
  exact ⟨htx,
    by simp [destinationDatumBinds, hap, hbind],
    by simp [onlyRootChanged, hcfg], by rw [hcfg, htrie], hcust, hcount,
    by rw [hheld]; exact List.mem_cons_self,
    rfl, rfl, rfl, hsigtx, hsecondtx, hadmits, hcross⟩


end Singular.Statements
