import Singular.Model

namespace RejectedFold

/-! Executable rejected-fold refinement candidate (NOTE-030/A-006).

Conservative extension over the ACCEPTED model (`lean/Singular/Model.lean`,
imported never modified): per-item processed/rejected disposition with
explicit timing witnesses, funding/refund observations, a parametric
consumer contract, and explicit custody bindings. NOT adopted; candidate
scope only. Finite checks demonstrate; quantified/proof obligations stay
open (see results receipt).

Allocation-source rule (A-006 review): owner, input lovelace and timing
are bound ONCE in candidate state keyed by request id; batch items carry
only the `FoldItem` identity. A caller cannot choose a convenient
recipient/value/floor — recipient and floor derive from the registry
binding, and a missing/duplicate binding refuses. Refund outputs remain
CHECKED observations, never evidence.

Deliberately absent by construction: no burn-as-rejection transition
(custody burn/completion is a separate effect, D5/D3 debt); no value
plane in the accepted sense — funding/refund/tip/fee are candidate-level
Nat observations checked against mechanical floors, and conservation is
an explicit aggregate obligation, not ledger semantics. -/

open Singular

/-- Processed keeps `foldOne`; rejected consumes with no logical delta. -/
inductive Kind where
  | processed
  | rejected
  deriving Repr, BEq, DecidableEq

/-- Observed validity window + the request/state times it is judged
against. Mirrors `in_phase1` (entirely-before) and `is_rejectable`
(entirely-after threshold / entirely-before submitted) mechanically on
Int — no Bool-mapping ambiguity. -/
structure TimingWitness where
  submittedAt : Int
  processTime : Int
  retractTime : Int
  rangeLower : Int
  rangeUpper : Option Int
  deriving Repr, BEq, DecidableEq

def rejectThreshold (t : TimingWitness) : Int :=
  t.submittedAt + t.processTime + t.retractTime - 1

def decidesRejectable (t : TimingWitness) : Bool :=
  t.rangeLower > rejectThreshold t ||
  match t.rangeUpper with
  | some u => u < t.submittedAt
  | none => false

def decidesPhase1 (t : TimingWitness) : Bool :=
  match t.rangeUpper with
  | some u => u < t.submittedAt + t.processTime
  | none => false

/-- Funding registry entry: the allocation source for one request id.
Bound at admission (candidate-run discipline), unique per id, persisted
past consumption as the audit trail. The owner is ledger-observed
funding metadata — NEVER `proposal.refundAddress` (the distinct
cancellation obligation, A-006.4). -/
structure FundingRecord where
  requestId : Nat
  owner : Nat
  inputLovelace : Nat
  timing : TimingWitness
  deriving Repr, BEq, DecidableEq

/-- Observed refund output: recipient credential + lovelace. These are
CHECKED observations, never caller-supplied evidence of correctness. -/
structure RefundOutput where
  recipient : Nat
  lovelace : Nat
  deriving Repr, BEq, DecidableEq

/-- Parametric consumer contract evidence. The candidate names the
interface; instantiations are separate (E17 below, bounded). -/
structure ConsumerEvidence where
  pinWithdrawalPresent : Bool
  spentStatesNonempty : Bool
  fundedGeTip : Bool
  mintLineageOk : Bool
  deriving Repr, BEq, DecidableEq

/-- Explicit request/custody association (NOTE-126 rule): a separately
identified custody identity holding the pending representative for one
request id. Never derived from `RequestDatum` (which has no held
field). -/
structure CustodyBinding where
  requestId : Nat
  rep : Representative
  custodian : Nat
  deriving Repr, BEq, DecidableEq

/-- Candidate state: accepted base + explicit funding registry + explicit
custody extension. Enforced at every batch entry (`candFoldInner`) and
exit (`finish`): funding ids unique; custody request ids unique;
every custody request id funding-bound; funding ids monotone across the
fold (consumed ids keep their records as the audit trail). Custodians
may repeat (shared script). Admission discipline populating the
registry is run-level debt (see results receipt). -/
structure CandState where
  base : State
  funding : List FundingRecord
  custody : List CustodyBinding
  deriving Repr, BEq, DecidableEq

structure CandResult where
  state : CandState
  logical : List Delta
  removed : List Nat
  refunds : List RefundOutput
  deriving Repr, BEq, DecidableEq

/-- E17 current `consumer()` instantiation — BOUNDED naming evidence
only (A-006.5): mirrors `check_requests` (spent state, funding ≥ tip)
+ `check_rep_mints` (lineage) at candidate abstraction. The bound
14a64a4 KERI adapter/consumer and the final compositor are separate
MANDATORY debt — no instantiation provided here. -/
def e17Consumer : ConsumerEvidence → Bool :=
  fun ev => ev.pinWithdrawalPresent && ev.spentStatesNonempty &&
    ev.fundedGeTip && ev.mintLineageOk

/-- Abstract identity tag for the E17 retirement-custody layout (Case-T
demos). A tag, not a script hash — hash binding is D6 debt. -/
def retirementCustodian : Nat := 6100

/-- Per-asset zero-net predicate for the zero-net batch demo
(fold-based: no termination proof needed). -/
def netSumsZero (ds : List Delta) : Bool :=
  let totals := ds.foldl (fun (acc : List (Representative × Int)) d =>
    match acc.find? (fun p => p.1 == d.asset) with
    | none => (d.asset, d.quantity) :: acc
    | some _ => acc.map fun p =>
        if p.1 == d.asset then (p.1, p.2 + d.quantity) else p) []
  totals.all fun p => p.2 == 0

/-- Duplicate-id detector (explicit Bool recursion: no instance risk). -/
def hasDup : List Nat → Bool
  | [] => false
  | x :: xs => xs.contains x || hasDup xs

def refundFloor (inputLovelace tip : Nat) : Int :=
  (inputLovelace : Int) - (tip : Int)

private def removeRequest (s : CandState) (id : Nat) : CandState :=
  { s with base := { s.base with
    requests := s.base.requests.filter (fun r => r.id != id) } }

def lookupFunding (s : CandState) (id : Nat) : Option FundingRecord :=
  s.funding.find? (fun f => f.requestId == id)

/-- Refund leg: recipient equals the REGISTRY-bound owner with the
mechanical input-minus-tip floor. Zero-value inputs accrue nothing
(compiled mirror) and pop no output. Returns the updated state,
remaining outputs, removals and paid refunds. Placed before the worker
(Lean needs def-before-use; it does not recurse). -/
def payRefund (tip : Nat) (s : CandState) (f : FundingRecord) (it : FoldItem)
    (outs : List RefundOutput) (rem : List Nat) (paid : List RefundOutput) :
    Except String (CandState × List RefundOutput × List Nat × List RefundOutput) :=
  if f.inputLovelace == 0 then
    .ok (removeRequest s it.request, outs, rem ++ [it.request], paid)
  else match outs with
  | [] => .error "refund-missing"
  | o :: outs' =>
    if o.recipient != f.owner then .error "refund-recipient"
    else if (o.lovelace : Int) < refundFloor f.inputLovelace tip then
      .error "refund-underpayment"
    else .ok (removeRequest s it.request, outs', rem ++ [it.request],
      paid ++ [o])

/-- Threaded worker: funding/timing looked up by request id (never
caller-supplied); request-row-only removal for rejected (never
`consume` — applications/custody untouched by construction). -/
def go (tip : Nat) (s : CandState) : List FoldItem → List Kind →
    List RefundOutput → List Delta → List Nat → List RefundOutput →
    Except String (CandState × List Delta × List Nat × List RefundOutput × List RefundOutput)
  | [], [], outs, log, rem, paid => .ok (s, log, rem, paid, outs)
  | [], _ :: _, _, _, _, _ => .error "action-count-mismatch"
  | _ :: _, [], _, _, _, _ => .error "action-count-mismatch"
  | it :: its, k :: ks, outs, log, rem, paid =>
    match s.base.requests.find? (fun r => r.id == it.request) with
    | none => .error "request-unavailable"
    | some r =>
      match lookupFunding s it.request with
      | none => .error "funding-unbound"
      | some f =>
        match k with
        | .processed =>
          if !decidesPhase1 f.timing then .error "process-timing"
          else match foldOne s.base it with
               | .error m => .error ("foldOne: " ++ m)
               | .ok t => go tip { s with base := t.state } its ks outs
                   (log ++ t.logical) (rem ++ [it.request]) paid
        | .rejected =>
          if !decidesRejectable f.timing then .error "reject-timing"
          else match r.held with
               | some h =>
                 match s.custody.find? (fun b =>
                   b.requestId == it.request && b.rep == h) with
                 | none => .error "custody-unbound"
                 | some _ =>
                   match payRefund tip s f it outs rem paid with
                   | .error m => .error m
                   | .ok (s', outs', rem', paid') =>
                     go tip s' its ks outs' log rem' paid'
               | none =>
                 match payRefund tip s f it outs rem paid with
                 | .error m => .error m
                 | .ok (s', outs', rem', paid') =>
                   go tip s' its ks outs' log rem' paid'

/-- Registry-sum over removed ids (post-state funding persists past
consumption, so the sum derives from bound metadata, never caller
totals). Missing binding is loud (`funding-dropped`), never silent. -/
def sumInputs : List FundingRecord → List Nat → Nat → Except String Nat
  | _, [], acc => .ok acc
  | funding, id :: ids, acc =>
    match funding.find? (fun f => f.requestId == id) with
    | none => .error "funding-dropped"
    | some f => sumInputs funding ids (acc + f.inputLovelace)

/-- Post-threading gate (factored out so the batch fold stays shallow):
exact output exhaustion, funding monotonicity, registry-derived
conservation. `outs` names EXACTLY the refund stream (no change
outputs inside it); leftovers refuse as surplus. -/
def finish (preFund : List Nat) (fee extraInputs extraOutputs : Nat)
    (res : Except String (CandState × List Delta × List Nat × List RefundOutput × List RefundOutput)) :
    Except String CandResult :=
  match res with
  | .error m => .error m
  | .ok (s', log, rem, paid, rest) =>
    match rest with
    | _ :: _ => .error "surplus-refund"
    | [] =>
      if !(preFund.all fun id =>
        ((s'.funding.map fun f => f.requestId).contains id)) then
        .error "funding-dropped"
      else match sumInputs s'.funding rem 0 with
      | .error m => .error m
      | .ok reqInputs =>
        let refundsTotal := paid.foldl (fun acc o => acc + o.lovelace) 0
        if reqInputs + extraInputs == refundsTotal + extraOutputs + fee then
          .ok { state := s', logical := log, removed := rem, refunds := paid }
        else .error "conservation"

/-- Inner batch fold (contract already checked): match-first structure
so refusal lemmas hold definitionally. Enforced entry invariants:
funding unique per id, custody unique per request id, every custody
request id funding-bound. -/
def candFoldInner (tip fee extraInputs extraOutputs : Nat) (s : CandState)
    (items : List FoldItem) (kinds : List Kind) (custodySpent : List Nat)
    (outs : List RefundOutput) : Except String CandResult :=
  match items with
  | [] => .error "empty-batch"
  | _ :: _ =>
    if h : kinds.length = items.length then
      if !hasDup (items.map (fun it => it.request)) then
        if !hasDup (s.funding.map (fun f => f.requestId)) then
          if !hasDup (s.custody.map (fun b => b.requestId)) then
            if (s.custody.all fun b =>
              ((s.funding.map fun f => f.requestId).contains b.requestId)) then
              if s.custody.any (fun b => custodySpent.contains b.custodian) then
                .error "custody-spent"
              else finish (s.funding.map fun f => f.requestId)
                fee extraInputs extraOutputs
                (go tip s items kinds outs [] [] [])
            else .error "custody-unassociated"
          else .error "custody-duplicate"
        else .error "funding-duplicate"
      else .error "duplicate-item"
    else .error "action-count-mismatch"

/-- Candidate batch fold: contract gate, then inner rules. `fee` burns,
`extraInputs` funds (state input + visible funding), `extraOutputs`
absorbs change — three distinct observed roles cross-checked against
the registry-derived request sum. There is deliberately NO caller
input-total parameter: totals cannot substitute for registry-bound
inputs. -/
def candFold (tip : Nat) (contract : ConsumerEvidence → Bool)
    (ev : ConsumerEvidence) (fee extraInputs extraOutputs : Nat) (s : CandState)
    (items : List FoldItem) (kinds : List Kind) (custodySpent : List Nat)
    (outs : List RefundOutput) : Except String CandResult :=
  if !contract ev then .error "consumer-contract"
  else candFoldInner tip fee extraInputs extraOutputs s items kinds custodySpent outs

/-- Empty batches refuse (definitionally: match-first). -/
theorem empty_batch_refuses (tip fee extraInputs extraOutputs : Nat) (s : CandState)
    (kinds : List Kind) (custodySpent : List Nat) (outs : List RefundOutput) :
    candFoldInner tip fee extraInputs extraOutputs s [] kinds custodySpent outs =
      .error "empty-batch" := rfl

/-- Action/request count mismatch refuses (nonempty items). -/
theorem count_mismatch_refuses (tip fee extraInputs extraOutputs : Nat) (s : CandState)
    (x : FoldItem) (xs : List FoldItem) (kinds : List Kind)
    (custodySpent : List Nat) (outs : List RefundOutput)
    (h2 : ¬ kinds.length = (x :: xs).length) :
    candFoldInner tip fee extraInputs extraOutputs s (x :: xs) kinds custodySpent outs =
      .error "action-count-mismatch" := by
  unfold candFoldInner
  exact dif_neg h2

end RejectedFold
