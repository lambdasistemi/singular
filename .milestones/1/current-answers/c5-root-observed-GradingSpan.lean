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
- empty action net ~ `[]`;
- purposes (state spent; representative policy minting) ~
  `w0` (`nativeSpend` + `representativeMint` set).
- R2 rejected shape (`Modify([Rejected])` consuming a request with empty
  logical, component-HALT in `ModifyWitness`) ~ an item naming an ABSENT
  request: no abstract consume-without-logical op exists (R2), so the
  graded fold FAILS — a checker counting component-HALT as abstract
  success fires RED here and GREEN on SPAN-OK (both directions pinned).
- FOREIGN shape (mint `+1` with `representativeMint` unset) ~ `wFor`:
  abstract `step` refuses (C4 control, mirrors the foreign-mint CEK leg).
- C5 (`actionNonzero net → applicationMint`): every encoded shape has
  `net = []`, so the antecedent is false and the leg is VACUOUS here —
  pinned below; a non-vacuous C5 (action-net minting) is unencodable at
  the current identity and classified tuple-dependent, never manufactured.

The shape↔bytes refinement itself stays stated debt (`MAPPING.md`); this
receipt anchors the abstract endpoints against the MODEL (not a
reimplementation) and proves the checker can both pass and fail. Finite
instances only — never quantified proof.
-/

open Singular
open Grading (s2 item0 mint0 w0 t1 wBad out0 getOk)

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

-- C5 vacuity pinned: no encoded shape carries a non-empty action net.
/-- info: false -/
#guard_msgs in
#eval actionNonzero ([] : List ActionDelta)

end GradingSpan
