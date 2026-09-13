import Grading
import Singular.Model

namespace GradingSpan

/-! Machine-checked mapping receipt: ddfc span fixtures ↔ `fold_iff`
conjuncts (NOTE-016 item 2, model at the frozen base).

Correspondence table (fixtures → graded Model values, ddfc span):
- five-field state datum (zeros root, `representative_policy` 53828b96,
  tip 500) into `Modify([UpdateAction([])])` over the MPF insert request
  ~ `s2` (registry holding insert request 7) with `items = [item0]`;
- tx mint `+1` representative under the expected policy ~ `mint0`;
- tx mint `-1` approval under the application policy ~ `netC5` with
  `wC5.applicationMint` (abstract endpoint fires for real; compiled
  endpoint and the UNPROVED bridge — see mapping note below);
- purposes (state spent; representative policy minting) ~
  `w0` (`nativeSpend` + `representativeMint` set).
- R2 rejected shape (`Modify([Rejected])` consuming a request with empty
  logical, component-HALT in `ModifyWitness`) ~ an item naming an ABSENT
  request: no abstract consume-without-logical op exists (R2), so the
  graded fold FAILS — a checker counting component-HALT as abstract
  success fires RED here and GREEN on SPAN-OK (both directions pinned).
- FOREIGN shape (mint `+1` with `representativeMint` unset) ~ `wFor`:
  abstract `step` refuses (C4 control, mirrors the foreign-mint CEK leg).
- tx mint `-1` approval under the application policy ~ `netC5 =
  [{insertAsset prop0, -1}]` with `wC5.applicationMint` set. NOTE-024
  disposition: endpoints green, bridge OPEN. Refinement debts, stated
  not hidden and NOT discharged: policy correspondence (compiled 52dbf57b
  vs `config.applicationPolicy`), name correspondence (blake2b_256
  preimage bytes vs abstract `.insert` proposal — no hash function on
  the model side; the binding is by role as the unique per-proposal
  approval token), burn-vs-persist divergence (compiled burns the
  approval; abstract `fold` retains approvals). What IS mechanical:
  quantity preserved (`-1` = `-1`), and the burn half executes against
  the span's own live claim (`runSpanAppMintBurn`).

The shape↔bytes refinement itself stays stated debt (`MAPPING.md`); this
receipt anchors the abstract endpoints against the MODEL (not a
reimplementation) and proves the checker can both pass and fail. Finite
instances only — never quantified proof.
-/

open Singular
open Grading (s2 item0 mint0 w0 t1 wBad out0 getOk prop0)

-- SPAN-OK (positive control): each of the five conjuncts separately, plus
-- the step — the G1 compiled counterpart's abstract side, clause by clause.
/-- info: (true, true, true, true, true, true) -/
#guard_msgs in
#eval ((w0.nativeSpend),
       (getOk (foldItems s2 [item0]) == some t1),
       (sameNet t1.logical mint0),
       (!(nonzero mint0) || w0.representativeMint),
       (!(actionNonzero ([] : List ActionDelta)) || w0.applicationMint),
       (getOk (step s2 (.fold [item0] mint0 [] w0)) == some t1))

/-- The R2 rejected-shape grading: an item naming request 999, absent from
` s2`, so `foldItems` fails and the composed fold is NOT a success — even
though the compiled component HALTs on the corresponding shape. -/
def itemR : FoldItem := { request := 999, outputId := 99, output := some out0 }

/-- info: (false, false) -/
#guard_msgs in
#eval ((getOk (foldItems s2 [itemR]) == some t1),
       (getOk (step s2 (.fold [itemR] [] [] w0)) == some t1))

def wFor : Witnesses := { w0 with representativeMint := false }

/-- info: (false, false) -/
#guard_msgs in
#eval ((!(nonzero mint0) || wFor.representativeMint),
       (getOk (step s2 (.fold [item0] mint0 [] wFor)) == some t1))

-- C5 endpoints-green instance (NOTE-022 abstract leg, NOTE-024 disposition):
-- the burned approval graded as a consumed insert-asset delta; the
-- implication fires for real on the abstract endpoint. The compiled
-- endpoint (app-MINT purpose HALT on the exact composed value) lives in
-- DdfcSpan; the bytes-to-insertAsset BRIDGE between them is stated
-- refinement debt, not an established relation — this instance does not
-- by itself discharge C5 across the compiled-to-abstract mapping.
def netC5 : List ActionDelta :=
  [{ asset := insertAsset prop0, quantity := -1 }]

def wC5 : Witnesses := { w0 with applicationMint := true }

/-- info: (true, true, true) -/
#guard_msgs in
#eval ((actionNonzero netC5),
       (wC5.applicationMint),
       (getOk (step s2 (.fold [item0] mint0 netC5 wC5)) == some t1))

-- Vacuous-grading control retained: the old all-empty-net grading made
-- C5 antecedent-false by construction; the instance above replaces it.
/-- info: false -/
#guard_msgs in
#eval actionNonzero ([] : List ActionDelta)

end GradingSpan
