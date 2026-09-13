import Grading
import RejectedFold
import Singular.Model

set_option autoImplicit false

namespace RejectedFoldGate

/-! Focused candidate gate (NOTE-030 TDD step 1, NOTE-034 one-context
revision): battery over the `RejectedFold` candidate interface.

One batch context per run: `ctxMain` (nonempty [5000, 6000), shared
state times) judges every item together with its keyed funding record.
Per-item ranges do not exist, so substitution is unrepresentable. Owner,
input lovelace and submission time live ONLY in the funding registry. -/

open Singular
open Grading (s2 req0 prop0 out0 rep0 w0 mint0 item0 t1 getOk)
open RejectedFold

def okOf : Except String CandResult → Option CandResult
  | .ok r => some r
  | .error _ => none

def errOf : Except String CandResult → String
  | .ok _ => "UNEXPECTED-OK"
  | .error m => m

def tip500 : Nat := 500

/-- The one coherent batch context: nonempty [5000, 6000), shared state
times. Older submissions reject out of it; newer ones process in it. -/
def ctxMain : TxContext :=
  { rangeLower := 5000, rangeUpper := some 6000,
    processTime := 2000, retractTime := 1000 }

/-- Inverted finite range: must refuse before item decisions. -/
def ctxBad : TxContext :=
  { rangeLower := 5000, rangeUpper := some 1000,
    processTime := 2000, retractTime := 1000 }

/-- Outsider-admitted request 8 (same id as the compiled rejected input). -/
def rOut8 : Request :=
  { id := 8, operation := .insert, proposal := prop0,
    destination := 90, authenticatedOrigin := false }

def sOutBase : State :=
  match step s2 (.outsider rOut8) with
  | .ok t => { t.state with used := 7 :: t.state.used }
  | .error _ => s2

-- Candidate-run admission discipline (enforced, NOTE-033): every batch
-- item id is already consumed in `used`. The MODEL needs none of this;
-- req 7 was admitted earlier with used-registration, req 8 just now.

/-- Funding registry records (admission-bound, unique per id). Owner tags
are abstract credentials deliberately distinct from `refundAddress` 5.
Every selected record is sufficiently funded (`>= tip`); the candidate
derives that itself — no caller Bool. -/
def fund8 : FundingRecord :=
  { requestId := 8, owner := 77, inputLovelace := 2000000, submittedAt := 1000 }

def fund8new : FundingRecord := { fund8 with submittedAt := 4500 }

def fund8zero : FundingRecord := { fund8 with inputLovelace := 0 }

def fund7 : FundingRecord :=
  { requestId := 7, owner := 78, inputLovelace := 600, submittedAt := 4500 }

def fund7old : FundingRecord :=
  { requestId := 7, owner := 78, inputLovelace := 600, submittedAt := 1000 }

def fund9 : FundingRecord :=
  { requestId := 9, owner := 79, inputLovelace := 600, submittedAt := 4500 }

def fund10 : FundingRecord :=
  { requestId := 10, owner := 80, inputLovelace := 3000000, submittedAt := 1000 }

def cOut : CandState :=
  { base := sOutBase, funding := [fund8, fund7], custody := [] }

def i8 : FoldItem := { request := 8, outputId := 100, output := none }
def i7 : FoldItem := item0
def i9 : FoldItem := { request := 9, outputId := 0, output := none }
def i10 : FoldItem := { request := 10, outputId := 0, output := none }

def evOk : ConsumerEvidence :=
  { pinWithdrawalPresent := true, spentStatesNonempty := true,
    mintLineageOk := true }

def evNoPin : ConsumerEvidence := { evOk with pinWithdrawalPresent := false }

def refund8 : RefundOutput := { recipient := 77, lovelace := 1999500 }
def refund10 : RefundOutput := { recipient := 80, lovelace := 2999500 }

-- G-all-rejected: one rejected Insert; exact post-state + ordered results.
/-- The legitimate nonempty all-rejected batch is accepted with exact effects.
Conservation: registry 2000000 + 0 == 1999500 + 500 (tip change) + 0. -/
def resAR : Except String CandResult :=
  candFold tip500 e17Consumer evOk ctxMain 0 0 500 cOut
    [i8] [.rejected] [] [refund8]

/-- info: (some [8], some [], some [7], some [{ recipient := 77, lovelace := 1999500 }], some [], true) -/
#guard_msgs in
#eval (((okOf resAR).map (·.removed)),
       ((okOf resAR).map (·.logical)),
       ((okOf resAR).map (fun r => r.state.base.requests.map (·.id))),
       ((okOf resAR).map (·.refunds)),
       ((okOf resAR).map (fun r => r.state.custody.map (·.requestId))),
       ((okOf resAR).map (fun r => r.state.base.used.contains 8) == some true))

-- Full post-state: pre except the same request row removed; every other
-- component byte-identical (entries, applications, approvals, config,
-- funding, custody, used).
/-- info: (true, true, true, true, true, true, true) -/
#guard_msgs in
#eval (((okOf resAR).map (fun r => r.state.base.entries) == some (cOut.base.entries)),
       ((okOf resAR).map (fun r => r.state.base.applications) == some (cOut.base.applications)),
       ((okOf resAR).map (fun r => r.state.base.approvals) == some (cOut.base.approvals)),
       ((okOf resAR).map (fun r => r.state.base.config) == some (cOut.base.config)),
       ((okOf resAR).map (fun r => r.state.funding) == some (cOut.funding)),
       ((okOf resAR).map (fun r => r.state.custody) == some (cOut.custody)),
       ((okOf resAR).map (fun r => r.state.base.used) == some (cOut.base.used)))

-- The rejected id was already consumed in `used` pre-batch and stays so.
/-- info: (true, true) -/
#guard_msgs in
#eval ((cOut.base.used.contains 8),
       ((okOf resAR).map (fun r => r.state.base.used.contains 8) == some true))

-- Immediate replay on the post-state refuses: the consumed id is gone
-- (candidate-scope no-replay).
def postAR : CandState :=
  match okOf resAR with | some r => r.state | none => cOut

/-- info: "request-unavailable" -/
#guard_msgs in
#eval errOf (candFold tip500 e17Consumer evOk ctxMain 0 0 0 postAR
  [i8] [.rejected] [] [refund8])

-- G-mixed: older rejectable request 8 (submitted 1000) with newer
-- phase-1 request 7 (submitted 4500) under the SAME range — the
-- preserved valid mixed positive (NOTE-131.1/4).
def resMX : Except String CandResult :=
  candFold tip500 e17Consumer evOk ctxMain 0 0 1100 cOut
    [i7, i8] [.processed, .rejected] [] [refund8]

/-- info: (some [{ asset := { registry := 1, key := 42, policy := 8, assetScope := 0 }, quantity := 1 }], some [7, 8], some []) -/
#guard_msgs in
#eval (((okOf resMX).map (·.logical)),
       ((okOf resMX).map (·.removed)),
       ((okOf resMX).map (fun r => r.state.base.requests.map (·.id))))

-- DIR-A (candidate → model projection): processed sub-effects coincide with
-- the accepted model fold over the same base and projected items.
/-- info: true -/
#guard_msgs in
#eval (((okOf resMX).map (·.logical)) ==
       ((getOk (foldItems sOutBase [item0])).map (·.logical)))

-- G-zero-net: insert key42 then delete key42 in one batch.
-- Reachability justification (A-006 review): entry42 sits at incarnation 2
-- (key inserted + deleted twice before — no value now); the deleter retains
-- rep42 minted in lifecycle 2, still scope-identical under reuseIdentity;
-- the new insert proposal is scoped [2] with its matching approval; both
-- submissions (4500) are in-phase1 under the shared range. Every model
-- check passes, so the batch is legitimate — not a synthetic holding.
-- (All-rejected `[]` is also zero-net, labeled separately below as the
-- vacuous case.)
def e42 : Entry := { key := 42, value := none, incarnation := 2 }

def prop2 : Proposal := { prop0 with scope := [2] }

def appr2 : Approval := { asset := insertAsset prop2, accepted := true }

def req0' : Request :=
  { req0 with proposal := prop2, token := some (insertAsset prop2) }

def req9 : Request :=
  { id := 9, operation := .delete, proposal := prop2, held := some rep0,
    destination := 90, authenticatedOrigin := true }

def sZNBase : State :=
  { config := {}, entries := [e42], applications := [],
    requests := [req0', req9], approvals := [appr2], used := [7, 9] }

def cZN : CandState :=
  { base := sZNBase, funding := [fund7, fund9], custody := [] }

def resZN : Except String CandResult :=
  candFold tip500 e17Consumer evOk ctxMain 0 0 1200 cZN
    [i7, i9] [.processed, .processed] [] []

/-- info: (some [{ asset := { registry := 1, key := 42, policy := 8, assetScope := 0 }, quantity := 1 },
  { asset := { registry := 1, key := 42, policy := 8, assetScope := 0 }, quantity := -1 }],
 some [7, 9],
 some [],
 true) -/
#guard_msgs in
#eval (((okOf resZN).map (·.logical)),
       ((okOf resZN).map (·.removed)),
       ((okOf resZN).map (fun r => r.state.base.requests.map (·.id))),
       ((okOf resZN).map (fun r => netSumsZero r.logical) == some true))

-- All-rejected `[]` is zero-net VACUOUSLY — labeled separately, not a
-- processed zero-net control.
/-- info: true -/
#guard_msgs in
#eval netSumsZero ([] : List Delta)

-- DIR-B (model → candidate realizability): the model SPAN-OK success plus
-- timing/funding/consumer extras is candidate-accepted with same effects.
def cB : CandState :=
  { base := { s2 with used := [7] }, funding := [fund7], custody := [] }

def resDB : Except String CandResult :=
  candFold tip500 e17Consumer evOk ctxMain 0 0 600 cB
    [i7] [.processed] [] []

/-- info: (some [{ asset := { registry := 1, key := 42, policy := 8, assetScope := 0 }, quantity := 1 }], some [7]) -/
#guard_msgs in
#eval (((okOf resDB).map (·.logical)),
       ((okOf resDB).map (·.removed)))

-- G-custody (Case T): held-carrying rejected 10 with a separately bound
-- custody identity (E17 retirement-custody tag); custody preserved
-- unchanged, request row removed.
def req10 : Request :=
  { id := 10, operation := .update, proposal := prop0, held := some rep0,
    destination := 90, authenticatedOrigin := true }

def sCBase : State :=
  { sOutBase with requests := req10 :: sOutBase.requests, used := 10 :: sOutBase.used }

def cC : CandState :=
  { base := sCBase, funding := [fund10],
    custody := [{ requestId := 10, rep := rep0, custodian := retirementCustodian }] }

def resCT : Except String CandResult :=
  candFold tip500 e17Consumer evOk ctxMain 0 0 500 cC
    [i10] [.rejected] [] [refund10]

/-- info: (some [10], some [], some [{ recipient := 80, lovelace := 2999500 }], some [10]) -/
#guard_msgs in
#eval (((okOf resCT).map (·.removed)),
       ((okOf resCT).map (·.logical)),
       ((okOf resCT).map (·.refunds)),
       ((okOf resCT).map (fun r => r.state.custody.map (·.requestId))))

-- Refusal controls: each must fail on its own exact reason.
-- R-empty.
/-- info: "empty-batch" -/
#guard_msgs in
#eval errOf (candFold tip500 e17Consumer evOk ctxMain 0 0 0 cOut [] [] [] [])

-- R-count (surplus action).
/-- info: "action-count-mismatch" -/
#guard_msgs in
#eval errOf (candFold tip500 e17Consumer evOk ctxMain 0 0 0 cOut
  [i8] [.rejected, .rejected] [] [refund8])

-- R-count (missing action).
/-- info: "action-count-mismatch" -/
#guard_msgs in
#eval errOf (candFold tip500 e17Consumer evOk ctxMain 0 0 0 cOut
  [i7, i8] [.processed] [] [refund8])

-- R-duplicate.
/-- info: "duplicate-item" -/
#guard_msgs in
#eval errOf (candFold tip500 e17Consumer evOk ctxMain 0 0 0 cOut
  [i8, i8] [.rejected, .rejected] [] [refund8, refund8])

-- R-invalid-range (lower 5000 / upper 1000 refuses before item decisions).
/-- info: "invalid-range" -/
#guard_msgs in
#eval errOf (candFold tip500 e17Consumer evOk ctxBad 0 0 0 cOut
  [i8] [.rejected] [] [refund8])

-- R-funding-duplicate.
/-- info: "funding-duplicate" -/
#guard_msgs in
#eval errOf (candFold tip500 e17Consumer evOk ctxMain 0 0 0
  { cOut with funding := [fund8, fund8] }
  [i8] [.rejected] [] [refund8])

-- R-missing.
/-- info: "request-unavailable" -/
#guard_msgs in
#eval errOf (candFold tip500 e17Consumer evOk ctxMain 0 0 0 cOut
  [{ request := 999, outputId := 100, output := none }] [.rejected] [] [])

-- R-missing-used-id (present request whose id was never consumed).
/-- info: "missing-used-id" -/
#guard_msgs in
#eval errOf (candFold tip500 e17Consumer evOk ctxMain 0 0 0
  { base := { sOutBase with used := [] }, funding := [fund8, fund7], custody := [] }
  [i8] [.rejected] [] [refund8])

-- R-funding-unbound (request present, no registry binding).
/-- info: "funding-unbound" -/
#guard_msgs in
#eval errOf (candFold tip500 e17Consumer evOk ctxMain 0 0 0
  { cOut with funding := [] }
  [i8] [.rejected] [] [refund8])

-- R-underfunded (registry 0 < tip 500 with all other evidence passing:
-- no caller Bool overrides the record).
/-- info: "request-underfunded" -/
#guard_msgs in
#eval errOf (candFold tip500 e17Consumer evOk ctxMain 0 0 0
  { cOut with funding := [fund8zero, fund7] }
  [i8] [.rejected] [] [refund8])

-- R-reject-timing (newer submission 4500 is not rejectable at [5000,6000)).
/-- info: "reject-timing" -/
#guard_msgs in
#eval errOf (candFold tip500 e17Consumer evOk ctxMain 0 0 0
  { cOut with funding := [fund8new, fund7] }
  [i8] [.rejected] [] [refund8])

-- R-process-timing (older submission 1000 is not phase-1 at [5000,6000)).
/-- info: "process-timing" -/
#guard_msgs in
#eval errOf (candFold tip500 e17Consumer evOk ctxMain 0 0 0
  { cOut with funding := [fund8, fund7old] }
  [i7] [.processed] [] [])

-- R-consumer (pin withdrawal absent).
/-- info: "consumer-contract" -/
#guard_msgs in
#eval errOf (candFold tip500 e17Consumer evNoPin ctxMain 0 0 0 cOut
  [i8] [.rejected] [] [refund8])

-- R-recipient.
/-- info: "refund-recipient" -/
#guard_msgs in
#eval errOf (candFold tip500 e17Consumer evOk ctxMain 0 0 0 cOut
  [i8] [.rejected] [] [{ recipient := 999, lovelace := 1999500 }])

-- R-underpayment.
/-- info: "refund-underpayment" -/
#guard_msgs in
#eval errOf (candFold tip500 e17Consumer evOk ctxMain 0 0 0 cOut
  [i8] [.rejected] [] [{ recipient := 77, lovelace := 1999499 }])

-- R-conservation (refunds + fee exceed registry inputs + extras).
/-- info: "conservation" -/
#guard_msgs in
#eval errOf (candFold tip500 e17Consumer evOk ctxMain 99999999 0 0 cOut
  [i8] [.rejected] [] [refund8])

-- R-conservation-output-high (change 501 invents one lovelace).
/-- info: "conservation" -/
#guard_msgs in
#eval errOf (candFold tip500 e17Consumer evOk ctxMain 0 0 501 cOut
  [i8] [.rejected] [] [refund8])

-- R-extraInputs-unbalanced (one funded lovelace with no matching output).
/-- info: "conservation" -/
#guard_msgs in
#eval errOf (candFold tip500 e17Consumer evOk ctxMain 0 1 500 cOut
  [i8] [.rejected] [] [refund8])

-- R-surplus-refund (output stream not exhausted exactly).
/-- info: "surplus-refund" -/
#guard_msgs in
#eval errOf (candFold tip500 e17Consumer evOk ctxMain 0 0 0 cOut
  [i8] [.rejected] [] [refund8, { recipient := 77, lovelace := 500 }])

-- R-refund-missing.
/-- info: "refund-missing" -/
#guard_msgs in
#eval errOf (candFold tip500 e17Consumer evOk ctxMain 0 0 0 cOut
  [i8] [.rejected] [] [])

-- R-custody-duplicate.
/-- info: "custody-duplicate" -/
#guard_msgs in
#eval errOf (candFold tip500 e17Consumer evOk ctxMain 0 0 0
  { cC with custody := [{ requestId := 10, rep := rep0, custodian := retirementCustodian },
    { requestId := 10, rep := rep0, custodian := retirementCustodian }] }
  [i10] [.rejected] [] [refund10])

-- R-custody-unassociated.
/-- info: "custody-unassociated" -/
#guard_msgs in
#eval errOf (candFold tip500 e17Consumer evOk ctxMain 0 0 0
  { cC with custody := [{ requestId := 99, rep := rep0, custodian := retirementCustodian }] }
  [i10] [.rejected] [] [refund10])

-- R-custody-unbound (held-carrying rejected item, no binding).
/-- info: "custody-unbound" -/
#guard_msgs in
#eval errOf (candFold tip500 e17Consumer evOk ctxMain 0 0 0
  { base := sCBase, funding := [fund10], custody := [] }
  [i10] [.rejected] [] [refund10])

-- R-custody-spent (bound custodian listed as spent).
/-- info: "custody-spent" -/
#guard_msgs in
#eval errOf (candFold tip500 e17Consumer evOk ctxMain 0 0 0 cC
  [i10] [.rejected] [retirementCustodian] [refund10])

end RejectedFoldGate
