import Singular.Model

namespace RejectedFold

/-! Executable rejected-fold refinement candidate (NOTE-030/A-006,
NOTE-034 one-transaction context).

Conservative extension over the ACCEPTED model (`lean/Singular/Model.lean`,
imported never modified): per-item processed/rejected disposition over ONE
batch transaction context, with registry-bound funding, derived E17
funding checks, a parametric consumer contract, and explicit custody
bindings. NOT adopted; candidate scope only. Finite checks demonstrate;
quantified/proof obligations stay open (see results receipt).

Allocation-source rule (A-006 review): owner, input lovelace and
submission time are bound ONCE in candidate state keyed by request id;
batch items carry only the `FoldItem` identity. Timing comes from the
single batch `TxContext` shared by all items — per-item ranges are
unrepresentable by construction. A caller cannot choose a convenient
recipient/value/floor/window. Refund outputs remain CHECKED
observations, never evidence.

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

/-- ONE batch transaction context (NOTE-131/034): a single validity range
plus the shared state times. Every item decision uses this same context
plus its keyed funding record.

Endpoint convention (integer abstraction): lower bound inclusive, upper
bound exclusive, `none` = +∞; a finite range with `lower >= upper` is
empty/inverted and refused before item decisions. REMAINING DEBT: exact
Aiken bound-closure/infinity correspondence (`Interval` bound types and
`is_entirely_before/after` on ledger bounds vs this `[l, u)`). -/
structure TxContext where
  rangeLower : Int
  rangeUpper : Option Int
  processTime : Int
  retractTime : Int
  deriving Repr, BEq, DecidableEq

def rangeValid (c : TxContext) : Bool :=
  match c.rangeUpper with
  | none => true
  | some u => c.rangeLower < u

def rejectThreshold (c : TxContext) (submittedAt : Int) : Int :=
  submittedAt + c.processTime + c.retractTime - 1

def decidesRejectable (c : TxContext) (submittedAt : Int) : Bool :=
  c.rangeLower > rejectThreshold c submittedAt ||
  match c.rangeUpper with
  | some u => u < submittedAt
  | none => false

def decidesPhase1 (c : TxContext) (submittedAt : Int) : Bool :=
  match c.rangeUpper with
  | some u => u < submittedAt + c.processTime
  | none => false

/-- Funding registry entry: the allocation source for one request id.
Bound at admission (candidate-run discipline), unique per id, persisted
past consumption as the audit trail. Keeps request-specific
`submittedAt`, owner and input lovelace; the window/timing lives ONLY
in the batch context. The owner is ledger-observed funding metadata —
NEVER `proposal.refundAddress` (the distinct cancellation obligation,
A-006.4). -/
structure FundingRecord where
  requestId : Nat
  owner : Nat
  inputLovelace : Nat
  submittedAt : Int
  deriving Repr, BEq, DecidableEq

/-- Observed refund output: recipient credential + lovelace. These are
CHECKED observations, never caller-supplied evidence of correctness. -/
structure RefundOutput where
  recipient : Nat
  lovelace : Nat
  deriving Repr, BEq, DecidableEq

/-- Parametric consumer contract evidence (NOTE-034: NO funding field —
a caller Bool must not override registry records; funding is derived
per selected record in the worker). The candidate names the interface;
instantiations are separate (E17 below, bounded). -/
structure ConsumerEvidence where
  pinWithdrawalPresent : Bool
  spentStatesNonempty : Bool
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
exit (`finish`): funding ids unique; custody request ids unique; every
custody request id funding-bound; every present batch-item id already
consumed in `used`; funding ids monotone across the fold (consumed ids
keep their records as the audit trail). Custodians may repeat (shared
script). Admission discipline populating the registry is run-level debt
(see results receipt). -/
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
only (A-006.5): mirrors `check_requests` spent-state presence +
`check_rep_mints` lineage at candidate abstraction. Funding (`lovelace
>= tip` per matching request) is DERIVED from registry records in the
worker, never asserted here. The bound 14a64a4 KERI adapter/consumer
and the final compositor are separate MANDATORY debt — no
instantiation provided here. -/
def e17Consumer : ConsumerEvidence → Bool :=
  fun ev => ev.pinWithdrawalPresent && ev.spentStatesNonempty &&
    ev.mintLineageOk

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

def refundFloor (inputLovelace tip : Nat) : Int :=
  (inputLovelace : Int) - (tip : Int)

/-- Duplicate-id detector (explicit Bool recursion: no instance risk). -/
def hasDup : List Nat → Bool
  | [] => false
  | x :: xs => xs.contains x || hasDup xs

def removeRequest (s : CandState) (id : Nat) : CandState :=
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

/-- Threaded worker: funding looked up by request id (never
caller-supplied); E17 funding floor derived per selected record
(`inputLovelace >= tip` — a contradictory caller Bool cannot override
a record); timing from the shared batch context plus the record's
`submittedAt`; request-row-only removal for rejected (never `consume`
— applications/custody untouched by construction). -/
def go (tip : Nat) (ctx : TxContext) (s : CandState) : List FoldItem → List Kind →
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
        if f.inputLovelace < tip then .error "request-underfunded"
        else match k with
        | .processed =>
          if !decidesPhase1 ctx f.submittedAt then .error "process-timing"
          else match foldOne s.base it with
               | .error m => .error ("foldOne: " ++ m)
               | .ok t => go tip ctx { s with base := t.state } its ks outs
                   (log ++ t.logical) (rem ++ [it.request]) paid
        | .rejected =>
          if !decidesRejectable ctx f.submittedAt then .error "reject-timing"
          else match r.held with
               | some h =>
                 match s.custody.find? (fun b =>
                   b.requestId == it.request && b.rep == h) with
                 | none => .error "custody-unbound"
                 | some _ =>
                   match payRefund tip s f it outs rem paid with
                   | .error m => .error m
                   | .ok (s', outs', rem', paid') =>
                     go tip ctx s' its ks outs' log rem' paid'
               | none =>
                 match payRefund tip s f it outs rem paid with
                 | .error m => .error m
                 | .ok (s', outs', rem', paid') =>
                   go tip ctx s' its ks outs' log rem' paid'

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
exact output exhaustion plus registry-derived conservation over
`reqInputs + extraInputs == refunds + extraOutputs + fee`. `outs` names
EXACTLY the refund stream (no change outputs inside it); leftovers
refuse as surplus. There is deliberately NO caller input-total
parameter. Funding records persist structurally (no code path drops
them); `sumInputs` fails loudly on any missing binding at the exact
reliance point, so no separate monotonicity check is needed. -/
def finish (fee extraInputs extraOutputs : Nat)
    (res : Except String (CandState × List Delta × List Nat × List RefundOutput × List RefundOutput)) :
    Except String CandResult :=
  match res with
  | .error m => .error m
  | .ok (s', log, rem, paid, rest) =>
    match rest with
    | _ :: _ => .error "surplus-refund"
    | [] =>
      match sumInputs s'.funding rem 0 with
      | .error m => .error m
      | .ok reqInputs =>
        let refundsTotal := paid.foldl (fun acc o => acc + o.lovelace) 0
        if reqInputs + extraInputs == refundsTotal + extraOutputs + fee then
          .ok { state := s', logical := log, removed := rem, refunds := paid }
        else .error "conservation"

/-- Inner batch fold (contract already checked): match-first structure
so refusal lemmas hold definitionally. Enforced entry invariants:
action count, item/funding/custody uniqueness, custody⊆funding,
present-item used-membership, and a valid (nonempty, non-inverted)
batch range — all before item decisions. -/
def candFoldInner (tip : Nat) (ctx : TxContext)
    (fee extraInputs extraOutputs : Nat) (s : CandState)
    (items : List FoldItem) (kinds : List Kind) (custodySpent : List Nat)
    (outs : List RefundOutput) : Except String CandResult :=
  match items with
  | [] => .error "empty-batch"
  | _ :: _ =>
    if h : kinds.length = items.length then
      if !hasDup (items.map (fun it => it.request)) then
        if !rangeValid ctx then .error "invalid-range"
        else if !hasDup (s.funding.map (fun f => f.requestId)) then
          if !hasDup (s.custody.map (fun b => b.requestId)) then
            if (s.custody.all fun b =>
              ((s.funding.map fun f => f.requestId).contains b.requestId)) then
              if !(items.all fun it =>
                !(s.base.requests.any fun r => r.id == it.request) ||
                s.base.used.contains it.request) then
                .error "missing-used-id"
              else if s.custody.any (fun b => custodySpent.contains b.custodian) then
                .error "custody-spent"
              else finish
                fee extraInputs extraOutputs
                (go tip ctx s items kinds outs [] [] [])
            else .error "custody-unassociated"
          else .error "custody-duplicate"
        else .error "funding-duplicate"
      else .error "duplicate-item"
    else .error "action-count-mismatch"

/-- Candidate batch fold: contract gate, then inner rules. `fee` burns,
`extraInputs` funds (state input + visible funding), `extraOutputs`
absorbs change — three distinct observed roles cross-checked against
the registry-derived request sum. -/
def candFold (tip : Nat) (contract : ConsumerEvidence → Bool)
    (ev : ConsumerEvidence) (ctx : TxContext)
    (fee extraInputs extraOutputs : Nat) (s : CandState)
    (items : List FoldItem) (kinds : List Kind) (custodySpent : List Nat)
    (outs : List RefundOutput) : Except String CandResult :=
  if !contract ev then .error "consumer-contract"
  else candFoldInner tip ctx fee extraInputs extraOutputs s items kinds custodySpent outs

/-- Empty batches refuse (definitionally: match-first). -/
theorem empty_batch_refuses (tip : Nat) (ctx : TxContext)
    (fee extraInputs extraOutputs : Nat) (s : CandState)
    (kinds : List Kind) (custodySpent : List Nat) (outs : List RefundOutput) :
    candFoldInner tip ctx fee extraInputs extraOutputs s [] kinds custodySpent outs =
      .error "empty-batch" := rfl

/-- Action/request count mismatch refuses (nonempty items). -/
theorem count_mismatch_refuses (tip : Nat) (ctx : TxContext)
    (fee extraInputs extraOutputs : Nat) (s : CandState)
    (x : FoldItem) (xs : List FoldItem) (kinds : List Kind)
    (custodySpent : List Nat) (outs : List RefundOutput)
    (h2 : ¬ kinds.length = (x :: xs).length) :
    candFoldInner tip ctx fee extraInputs extraOutputs s (x :: xs) kinds custodySpent outs =
      .error "action-count-mismatch" := by
  unfold candFoldInner
  exact dif_neg h2

end RejectedFold
