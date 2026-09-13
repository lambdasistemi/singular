import RejectedFoldGate
import Singular.Model

set_option autoImplicit false

namespace Corr

/-! General transition correspondence (NOTE-035): an independent
inductive relation over ordered `(FoldItem, Kind)` sequences plus batch
hypotheses, with frame lemmas, both correspondence directions, and the
mutant correspondence-level control. Owned candidate scope; the accepted
model is imported, never modified. No `sorryAx`/`admit` anywhere. -/

open Singular
open RejectedFold (Kind TxContext FundingRecord RefundOutput
  ConsumerEvidence CustodyBinding CandState CandResult TxContext
  decidesRejectable decidesPhase1 rangeValid refundFloor sumInputs hasDup
  e17Consumer go payRefund removeRequest lookupFunding candFold candFoldInner finish)
open RejectedFoldGate (cOut i8 refund8 evOk tip500 ctxMain)

/-- One step of the independent relation. Each constructor mirrors one
`go` code branch with the same equations — but no constructor calls
`candFold`/`go`; the relation stands on its own. -/
inductive StepCorr : CandState → TxContext → Nat → FoldItem → Kind →
    List RefundOutput → CandState → List Delta → List Nat →
    List RefundOutput → List RefundOutput → Prop where
  | processed (s ctx tip it f t outs r)
      (hpres : s.base.requests.find? (fun q => q.id == it.request) = some r)
      (hfund : s.funding.find? (fun g => g.requestId == it.request) = some f)
      (hfloor : ¬ f.inputLovelace < tip)
      (hphase : decidesPhase1 ctx f.submittedAt = true)
      (hfold : foldOne s.base it = .ok t) :
      StepCorr s ctx tip it .processed outs
        { s with base := t.state } t.logical [it.request] [] outs
  | rejectedFree (s ctx tip it f outs r)
      (hpres : s.base.requests.find? (fun q => q.id == it.request) = some r)
      (hfund : s.funding.find? (fun g => g.requestId == it.request) = some f)
      (hfloor : ¬ f.inputLovelace < tip)
      (hreject : decidesRejectable ctx f.submittedAt = true)
      (hheld : r.held = none)
      (hzero : (f.inputLovelace == 0) = true) :
      StepCorr s ctx tip it .rejected outs
        { s with base := { s.base with requests := s.base.requests.filter (fun q => q.id != it.request) } }
        [] [it.request] [] outs
  | rejectedPaid (s ctx tip it f outs r o rest)
      (hpres : s.base.requests.find? (fun q => q.id == it.request) = some r)
      (hfund : s.funding.find? (fun g => g.requestId == it.request) = some f)
      (hfloor : ¬ f.inputLovelace < tip)
      (hreject : decidesRejectable ctx f.submittedAt = true)
      (hheld : r.held = none)
      (houts : outs = o :: rest)
      (hrec : (o.recipient != f.owner) = false)
      (hflr : ¬ (o.lovelace : Int) < refundFloor f.inputLovelace tip)
      (hnz : (f.inputLovelace == 0) = false) :
      StepCorr s ctx tip it .rejected (o :: rest)
        { s with base := { s.base with requests := s.base.requests.filter (fun q => q.id != it.request) } }
        [] [it.request] [o] rest
  | custodyFree (s ctx tip it f outs r h bc)
      (hpres : s.base.requests.find? (fun q => q.id == it.request) = some r)
      (hfund : s.funding.find? (fun g => g.requestId == it.request) = some f)
      (hfloor : ¬ f.inputLovelace < tip)
      (hreject : decidesRejectable ctx f.submittedAt = true)
      (hheld : r.held = some h)
      (hfind : s.custody.find? (fun b =>
        b.requestId == it.request && b.rep == h) = some bc)
      (hzero : (f.inputLovelace == 0) = true) :
      StepCorr s ctx tip it .rejected outs
        { s with base := { s.base with requests := s.base.requests.filter (fun q => q.id != it.request) } }
        [] [it.request] [] outs
  | custodyPaid (s ctx tip it f outs r o rest h bc)
      (hpres : s.base.requests.find? (fun q => q.id == it.request) = some r)
      (hfund : s.funding.find? (fun g => g.requestId == it.request) = some f)
      (hfloor : ¬ f.inputLovelace < tip)
      (hreject : decidesRejectable ctx f.submittedAt = true)
      (hheld : r.held = some h)
      (hfind : s.custody.find? (fun b =>
        b.requestId == it.request && b.rep == h) = some bc)
      (houts : outs = o :: rest)
      (hrec : (o.recipient != f.owner) = false)
      (hflr : ¬ (o.lovelace : Int) < refundFloor f.inputLovelace tip)
      (hnz : (f.inputLovelace == 0) = false) :
      StepCorr s ctx tip it .rejected (o :: rest)
        { s with base := { s.base with requests := s.base.requests.filter (fun q => q.id != it.request) } }
        [] [it.request] [o] rest

/-- Ordered batch relation: threads state, logical, removed, paid and
the refund stream left-to-right. -/
inductive BatchCorr : CandState → TxContext → Nat → List FoldItem →
    List Kind → List RefundOutput → CandState → List Delta → List Nat →
    List RefundOutput → List RefundOutput → Prop where
  | done (s ctx tip outs) :
      BatchCorr s ctx tip [] [] outs s [] [] [] outs
  | step (s ctx tip it its k ks outs s1 l1 r1 p1 outs1
      s' log rem paid outs') :
      StepCorr s ctx tip it k outs s1 l1 r1 p1 outs1 →
      BatchCorr s1 ctx tip its ks outs1 s' log rem paid outs' →
      BatchCorr s ctx tip (it :: its) (k :: ks) outs s'
        (l1 ++ log) (r1 ++ rem) (p1 ++ paid) outs'

/-- Batch-level hypotheses, each mirroring one `candFoldInner` check as
a Boolean equation. No caller Bool certifies anything: every field is
discharged from state/batch data in the proofs. -/
structure BatchHyps (tip : Nat) (ctx : TxContext)
    (contract : ConsumerEvidence → Bool) (ev : ConsumerEvidence)
    (s : CandState) (items : List FoldItem) (kinds : List Kind)
    (custodySpent : List Nat) : Prop where
  contractHolds : contract ev = true
  nonempty : items ≠ []
  countEq : kinds.length = items.length
  nodupItems : hasDup (items.map fun it => it.request) = false
  rangeOk : rangeValid ctx = true
  nodupFunding : hasDup (s.funding.map fun f => f.requestId) = false
  nodupCustody : hasDup (s.custody.map fun b => b.requestId) = false
  usedMem : ((items.map fun it => it.request).all fun id =>
    (!(s.base.requests.any fun r => r.id == id)) ||
    s.base.used.contains id) = true
  custodyUnspent : (s.custody.any fun b =>
    custodySpent.contains b.custodian) = false

/-- Full correspondence: hypotheses + ordered derivation + exact output
exhaustion + registry-derived conservation. -/
structure FullCorr (tip : Nat) (ctx : TxContext)
    (contract : ConsumerEvidence → Bool) (ev : ConsumerEvidence)
    (fee extraInputs extraOutputs : Nat) (s : CandState)
    (items : List FoldItem) (kinds : List Kind) (custodySpent : List Nat)
    (outs : List RefundOutput) (s' : CandState) (log : List Delta)
    (rem : List Nat) (paid : List RefundOutput) : Prop where
  hyps : BatchHyps tip ctx contract ev s items kinds custodySpent
  batch : BatchCorr s ctx tip items kinds outs s' log rem paid []
  conserve : ∃ reqInputs : Nat,
    sumInputs s'.funding rem 0 = .ok reqInputs ∧
    (reqInputs + extraInputs ==
      (paid.foldl (fun acc o => acc + o.lovelace) 0) + extraOutputs + fee) = true

/-- Executable-`all` bridge (one direction, proved): from a true `all`
equation to per-element facts. Used to discharge per-item premises from
batch hypotheses. -/
theorem all_true_of_mem {α : Type} {p : α → Bool} {l : List α}
    (h : l.all p = true) {x : α} (hx : x ∈ l) : p x = true := by
  induction l with
  | nil => simp at hx
  | cons y ys ih =>
    have h2 : p y = true ∧ ys.all p = true := by simpa using h
    cases hx with
    | head => exact h2.1
    | tail _ hmem => exact ih h2.2 hmem

/-- Absence is preserved across all-rejected derivations (no step adds
request rows; rejected steps only filter). Processed constructors are
killed vacuously by the all-rejected kinds hypothesis — no `foldOne`
internals needed. -/
theorem batch_absence_preserved_allrej
    {s ctx tip items kinds outs s' log rem paid outs'}
    (d : BatchCorr s ctx tip items kinds outs s' log rem paid outs')
    (hre : ∀ k ∈ kinds, k = .rejected) (id : Nat)
    (habs : id ∉ s.base.requests.map (fun r => r.id)) :
    id ∉ s'.base.requests.map (fun r => r.id) := by
  induction d
  case done => exact habs
  case step s ctx tip it its k ks outs s1 l1 r1 p1 outs1
      s' log rem paid outs' hstep tail ih =>
    have hk : k = .rejected := hre k (List.mem_cons.mpr (Or.inl rfl))
    have hre' : ∀ k_1 ∈ ks, k_1 = .rejected :=
      fun a ha => hre a (List.mem_cons.mpr (Or.inr ha))
    cases hstep with
    | processed =>
      exact absurd hk (by decide)
    | rejectedFree =>
      have h1 : id ∉ ((s.base.requests.filter
        (fun q => q.id != it.request)).map (fun r => r.id)) := by
        simp only [List.mem_map] at habs ⊢
        intro hx
        obtain ⟨x, hmem, heq⟩ := hx
        have hmem' : x ∈ s.base.requests := by
          simp only [List.mem_filter] at hmem
          exact hmem.1
        exact habs ⟨x, hmem', heq⟩
      exact ih hre' h1
    | rejectedPaid =>
      have h1 : id ∉ ((s.base.requests.filter
        (fun q => q.id != it.request)).map (fun r => r.id)) := by
        simp only [List.mem_map] at habs ⊢
        intro hx
        obtain ⟨x, hmem, heq⟩ := hx
        have hmem' : x ∈ s.base.requests := by
          simp only [List.mem_filter] at hmem
          exact hmem.1
        exact habs ⟨x, hmem', heq⟩
      exact ih hre' h1
    | custodyFree =>
      have h1 : id ∉ ((s.base.requests.filter
        (fun q => q.id != it.request)).map (fun r => r.id)) := by
        simp only [List.mem_map] at habs ⊢
        intro hx
        obtain ⟨x, hmem, heq⟩ := hx
        have hmem' : x ∈ s.base.requests := by
          simp only [List.mem_filter] at hmem
          exact hmem.1
        exact habs ⟨x, hmem', heq⟩
      exact ih hre' h1
    | custodyPaid =>
      have h1 : id ∉ ((s.base.requests.filter
        (fun q => q.id != it.request)).map (fun r => r.id)) := by
        simp only [List.mem_map] at habs ⊢
        intro hx
        obtain ⟨x, hmem, heq⟩ := hx
        have hmem' : x ∈ s.base.requests := by
          simp only [List.mem_filter] at hmem
          exact hmem.1
        exact habs ⟨x, hmem', heq⟩
      exact ih hre' h1

/-- Removed ids are absent post-run (all-rejected fragment): combines
definitional filter-removal at each step with preservation above. -/
theorem batch_removed_absent_allrej
    {s ctx tip items kinds outs s' log rem paid outs'}
    (d : BatchCorr s ctx tip items kinds outs s' log rem paid outs')
    (hre : ∀ k ∈ kinds, k = .rejected) {id : Nat} (hmem : id ∈ rem) :
    id ∉ s'.base.requests.map (fun r => r.id) := by
  induction d
  case done => simp at hmem
  case step s ctx tip it its k ks outs s1 l1 r1 p1 outs1
      s' log rem paid outs' hstep tail ih =>
    have hk : k = .rejected := hre k (List.mem_cons.mpr (Or.inl rfl))
    have hre' : ∀ k_1 ∈ ks, k_1 = .rejected :=
      fun a ha => hre a (List.mem_cons.mpr (Or.inr ha))
    cases hstep with
    | processed =>
      exact absurd hk (by decide)
    | rejectedFree =>
      simp only [List.mem_append, List.mem_singleton] at hmem
      obtain rfl | hmem := hmem
      ·
        have h1 : it.request ∉ ((s.base.requests.filter
          (fun q => q.id != it.request)).map (fun r => r.id)) := by
          simp only [List.mem_map]
          intro hx
          obtain ⟨x, hmem, heq⟩ := hx
          have hne : x.id ≠ it.request := by
            simp only [List.mem_filter] at hmem
            simpa using hmem.2
          exact hne heq
        exact batch_absence_preserved_allrej tail hre' _ h1
      · exact ih hre' hmem
    | rejectedPaid =>
      simp only [List.mem_append, List.mem_singleton] at hmem
      obtain rfl | hmem := hmem
      ·
        have h1 : it.request ∉ ((s.base.requests.filter
          (fun q => q.id != it.request)).map (fun r => r.id)) := by
          simp only [List.mem_map]
          intro hx
          obtain ⟨x, hmem, heq⟩ := hx
          have hne : x.id ≠ it.request := by
            simp only [List.mem_filter] at hmem
            simpa using hmem.2
          exact hne heq
        exact batch_absence_preserved_allrej tail hre' _ h1
      · exact ih hre' hmem
    | custodyFree =>
      simp only [List.mem_append, List.mem_singleton] at hmem
      obtain rfl | hmem := hmem
      ·
        have h1 : it.request ∉ ((s.base.requests.filter
          (fun q => q.id != it.request)).map (fun r => r.id)) := by
          simp only [List.mem_map]
          intro hx
          obtain ⟨x, hmem, heq⟩ := hx
          have hne : x.id ≠ it.request := by
            simp only [List.mem_filter] at hmem
            simpa using hmem.2
          exact hne heq
        exact batch_absence_preserved_allrej tail hre' _ h1
      · exact ih hre' hmem
    | custodyPaid =>
      simp only [List.mem_append, List.mem_singleton] at hmem
      obtain rfl | hmem := hmem
      ·
        have h1 : it.request ∉ ((s.base.requests.filter
          (fun q => q.id != it.request)).map (fun r => r.id)) := by
          simp only [List.mem_map]
          intro hx
          obtain ⟨x, hmem, heq⟩ := hx
          have hne : x.id ≠ it.request := by
            simp only [List.mem_filter] at hmem
            simpa using hmem.2
          exact hne heq
        exact batch_absence_preserved_allrej tail hre' _ h1
      · exact ih hre' hmem

/-- Mutant correspondence-level control: no full correspondence exists
for the mutant's EXECUTED shape (post ids `[8, 7]` with removed `[8]`
— the kill-gate fact). The general removed-absent frame rejects the
retained row for the intended reason. -/
theorem mutant_retained_row_rejected (post : CandState)
    (hids : post.base.requests.map (fun r => r.id) = [8, 7]) :
    ¬ FullCorr tip500 ctxMain e17Consumer evOk 0 0 500
      cOut [i8] [.rejected] [] [refund8] post [] [8] [refund8] := by
  intro h
  have hre : ∀ k ∈ ([.rejected] : List Kind), k = .rejected := by decide
  have habs := batch_removed_absent_allrej h.batch hre (by decide : 8 ∈ ([8] : List Nat))
  rw [hids] at habs
  exact habs (by decide : 8 ∈ ([8, 7] : List Nat))

/-- DIR-B worker: any related derivation is returned by `go` with the
same accumulators threaded. Induction on the derivation; each step
rewrites the code path with the constructor equations. -/
theorem dirB_go (tip : Nat) (ctx : TxContext) (s : CandState)
    (items : List FoldItem) (kinds : List Kind) (outs : List RefundOutput)
    (s' : CandState) (log : List Delta) (rem : List Nat)
    (paid outs' : List RefundOutput) (log0 : List Delta)
    (rem0 : List Nat) (paid0 : List RefundOutput)
    (d : BatchCorr s ctx tip items kinds outs s' log rem paid outs') :
    go tip ctx s items kinds outs log0 rem0 paid0 =
      .ok (s', log0 ++ log, rem0 ++ rem, paid0 ++ paid, outs') := by
  revert log0 rem0 paid0
  induction d with
  | done => intro log0 rem0 paid0; simp [go]
  | step s ctx tip it its k ks outs s1 l1 r1 p1 outs1
      s' log rem paid outs' hstep tail ih =>
    intro log0 rem0 paid0
    cases hstep with
    | processed f t outs r hpres hfund hfloor hphase hfold =>
      simp [go, lookupFunding, hpres, hfund, hfloor, hphase, hfold, ih, List.append_assoc]
    | rejectedFree f outs r hpres hfund hfloor hreject hheld hzero =>
      simp [go, lookupFunding, hpres, hfund, hfloor, hreject, hheld, payRefund, removeRequest,
        hzero, ih, List.append_assoc]
    | rejectedPaid f outs r o rest hpres hfund hfloor hreject hheld houts hrec hflr hnz =>
      have hnz' : ¬ (f.inputLovelace == 0) = true := by
        simp [hnz]
      have hrec' : (o.recipient != f.owner) = false := by simp [hrec]
      simp [go, lookupFunding, hpres, hfund, hfloor, hreject, hheld, payRefund, removeRequest,
        hnz', houts, hrec', hflr, ih, List.append_assoc]
    | custodyFree f outs r h bc hpres hfund hfloor hreject hheld hfind hzero =>
      simp [go, lookupFunding, hpres, hfund, hfloor, hreject, hheld, hfind, payRefund, removeRequest,
        hzero, ih, List.append_assoc]
    | custodyPaid f outs r o rest h bc hpres hfund hfloor hreject hheld hfind houts hrec hflr hnz =>
      have hnz' : ¬ (f.inputLovelace == 0) = true := by
        simp [hnz]
      have hrec' : (o.recipient != f.owner) = false := by simp [hrec]
      simp [go, lookupFunding, hpres, hfund, hfloor, hreject, hheld, hfind, payRefund, removeRequest,
        hnz', houts, hrec', hflr, ih, List.append_assoc]

/-- DIR-B top: any fully related batch is returned by `candFold`. -/
theorem dirB_top (tip : Nat) (ctx : TxContext)
    (contract : ConsumerEvidence → Bool) (ev : ConsumerEvidence)
    (fee extraInputs extraOutputs : Nat) (s : CandState)
    (items : List FoldItem) (kinds : List Kind) (custodySpent : List Nat)
    (outs : List RefundOutput) (s' : CandState) (log : List Delta)
    (rem : List Nat) (paid : List RefundOutput)
    (h : FullCorr tip ctx contract ev fee extraInputs extraOutputs
      s items kinds custodySpent outs s' log rem paid) :
    candFold tip contract ev ctx fee extraInputs extraOutputs
      s items kinds custodySpent outs =
      .ok { state := s', logical := log, removed := rem, refunds := paid } := by
  obtain ⟨hyps, batch, conserve⟩ := h
  obtain ⟨reqInputs, hsum, harith⟩ := conserve
  have hgo := dirB_go tip ctx s items kinds outs s' log rem paid [] [] [] [] batch
  simp only [candFold, candFoldInner, hyps.contractHolds, hyps.countEq,
    hyps.nodupItems, hyps.rangeOk, hyps.nodupFunding, hyps.nodupCustody,
    hyps.usedMem, hyps.custodyUnspent, hgo, finish, hsum, harith,
    if_true, if_false, Bool.not_true, Bool.not_false, Bool.false_eq_true,
    List.append_assoc]

/-- DIR-A worker: any successful `go` run exhibits the independent
ordered relation with exact accumulators. Induction on items; each
leaf inverts one code branch and assembles the matching constructor. -/
theorem dirA_go (tip : Nat) (ctx : TxContext) (s : CandState)
    (items : List FoldItem) (kinds : List Kind) (outs : List RefundOutput)
    (log0 : List Delta) (rem0 : List Nat) (paid0 : List RefundOutput)
    (s' : CandState) (log' : List Delta) (rem' : List Nat)
    (paid' outs'' : List RefundOutput)
    (h : go tip ctx s items kinds outs log0 rem0 paid0 =
      .ok (s', log', rem', paid', outs'')) :
    ∃ l1 r1 p1, log' = log0 ++ l1 ∧ rem' = rem0 ++ r1 ∧ paid' = paid0 ++ p1 ∧
      BatchCorr s ctx tip items kinds outs s' l1 r1 p1 outs'' := by
  revert h
  revert kinds s outs log0 rem0 paid0
  induction items with
  | nil =>
    intro s kinds outs log0 rem0 paid0 h
    cases kinds with
    | nil =>
      simp [go] at h
      obtain ⟨rfl, rfl, rfl, rfl, rfl⟩ := h
      exact ⟨[], [], [], by simp, by simp, by simp, BatchCorr.done _ _ _ _⟩
    | cons k ks => simp [go] at h
  | cons it its ih =>
    intro s kinds outs log0 rem0 paid0 h
    cases kinds with
    | nil => simp [go] at h
    | cons k ks =>
      cases hfind : s.base.requests.find? (fun r => r.id == it.request) with
      | none => simp [go, hfind] at h
      | some r =>
        cases hfund : lookupFunding s it.request with
        | none => simp [go, hfind, hfund] at h
        | some f =>
          by_cases htf : f.inputLovelace < tip
          · simp [go, hfind, hfund, htf] at h
          · cases k with
            | processed =>
              by_cases hph : decidesPhase1 ctx f.submittedAt = true
              · cases hfold : foldOne s.base it with
                | error m => simp [go, hfind, hfund, htf, hph, hfold] at h
                | ok t =>
                  simp [go, hfind, hfund, htf, hph, hfold] at h
                  obtain ⟨l1, r1, p1, hl1, hr1, hp1, dtail⟩ := ih _ _ _ _ _ _ h
                  exact ⟨t.logical ++ l1, [it.request] ++ r1, p1,
                    by rw [hl1, List.append_assoc],
                    by rw [hr1, List.append_assoc], hp1,
                    BatchCorr.step _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ (StepCorr.processed s ctx tip it f t outs r
                      hfind hfund htf hph hfold) dtail⟩
              · simp [go, hfind, hfund, htf, hph] at h; cases h
            | rejected =>
              by_cases hrj : decidesRejectable ctx f.submittedAt = true
              · cases hheld : r.held with
                | none =>
                  cases hz : (f.inputLovelace == 0) with
                  | true =>
                    simp [go, hfind, hfund, htf, hrj, hheld, hz, payRefund] at h
                    obtain ⟨l1, r1, p1, hl1, hr1, hp1, dtail⟩ := ih _ _ _ _ _ _ h
                    exact ⟨[] ++ l1, [it.request] ++ r1, [] ++ p1,
                      by simp [hl1], by simp [hr1], by simp [hp1],
                      BatchCorr.step _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ (StepCorr.rejectedFree s ctx tip it f outs r
                        hfind hfund htf hrj hheld hz) dtail⟩
                  | false =>
                    cases houts : outs with
                    | nil =>
                      simp [go, hfind, hfund, htf, hrj, hheld, hz, houts, payRefund] at h
                      cases h
                    | cons o rest =>
                      cases hrec : (o.recipient != f.owner) with
                      | true =>
                        simp [go, hfind, hfund, htf, hrj, hheld, hz, houts, payRefund, hrec] at h
                        cases h
                      | false =>
                        by_cases hflr : (o.lovelace : Int) < refundFloor f.inputLovelace tip
                        · simp [go, hfind, hfund, htf, hrj, hheld, hz, houts, payRefund, hrec, hflr] at h
                          cases h
                        · simp [go, hfind, hfund, htf, hrj, hheld, hz, houts, payRefund,
                            hrec, hflr] at h
                          obtain ⟨l1, r1, p1, hl1, hr1, hp1, dtail⟩ := ih _ _ _ _ _ _ h
                          exact ⟨[] ++ l1, [it.request] ++ r1, [o] ++ p1,
                            by simp [hl1], by simp [hr1], by simp [hp1],
                            BatchCorr.step _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ (StepCorr.rejectedPaid s ctx tip it f outs r o rest
                              hfind hfund htf hrj hheld houts
                              hrec hflr hz) dtail⟩
                | some hh =>
                  cases hfc : s.custody.find? (fun b =>
                    b.requestId == it.request && b.rep == hh) with
                  | none =>
                    simp [go, hfind, hfund, htf, hrj, hheld, hfc] at h
                    cases h
                  | some bc =>
                    cases hz : (f.inputLovelace == 0) with
                    | true =>
                      simp [go, hfind, hfund, htf, hrj, hheld, hfc, hz, payRefund] at h
                      obtain ⟨l1, r1, p1, hl1, hr1, hp1, dtail⟩ := ih _ _ _ _ _ _ h
                      exact ⟨[] ++ l1, [it.request] ++ r1, [] ++ p1,
                        by simp [hl1], by simp [hr1], by simp [hp1],
                        BatchCorr.step _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ (StepCorr.custodyFree s ctx tip it f outs r hh bc
                          hfind hfund htf hrj hheld hfc hz) dtail⟩
                    | false =>
                      cases houts : outs with
                      | nil =>
                        simp [go, hfind, hfund, htf, hrj, hheld, hfc, hz, houts, payRefund] at h
                        cases h
                      | cons o rest =>
                        cases hrec : (o.recipient != f.owner) with
                        | true =>
                          simp [go, hfind, hfund, htf, hrj, hheld, hfc, hz, houts, payRefund,
                            hrec] at h
                          cases h
                        | false =>
                          by_cases hflr : (o.lovelace : Int) < refundFloor f.inputLovelace tip
                          · simp [go, hfind, hfund, htf, hrj, hheld, hfc, hz, houts, payRefund,
                              hrec, hflr] at h
                            cases h
                          · simp [go, hfind, hfund, htf, hrj, hheld, hfc, hz, houts,
                              payRefund, hrec, hflr] at h
                            obtain ⟨l1, r1, p1, hl1, hr1, hp1, dtail⟩ := ih _ _ _ _ _ _ h
                            exact ⟨[] ++ l1, [it.request] ++ r1, [o] ++ p1,
                              by simp [hl1], by simp [hr1], by simp [hp1],
                              BatchCorr.step _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ (StepCorr.custodyPaid s ctx tip it f outs r o rest hh bc
                                hfind hfund htf hrj hheld hfc houts
                                hrec hflr hz) dtail⟩
              · simp [go, hfind, hfund, htf, hrj] at h; cases h
