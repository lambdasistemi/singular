import Singular.Model

namespace Grading

/-! Executable abstract-side grading (slice 1, model at base `5bd7c79`).

`Model.lean` is copied verbatim from the worktree (provenance: `blaster/abstract/`
recipe asserts `lean/` untouched and records the commit). These instances mirror the
CEK fixture SHAPES, not byte values — the shape↔bytes refinement is stated debt
(`MAPPING.md`); what executes here are the abstract conjuncts both CEK runs assume:

- G1 mirrors the honest-`Update` fixture: one insert, `+1` mint, `representativeMint`
  set, no actions — all five `fold_iff` conjuncts must hold AND `step` must succeed.
- G2 mirrors the `Rejected` fixture as the empty fold (a rejected request is unfolded):
  trivial conjuncts, success.
- G3 is the abstract refusal control: same as G1 but `nativeSpend := false` — `step`
  must NOT succeed (the abstract check fires; a vacuous-accept model would fail here).

Boolean reflection throughout (`==`, `&&`, `!_ || _`): the exact mirror of the
`fold_iff` conjunction for these instances. (`decide` on `Except` equality is avoided:
`DecidableEq (Except String Result)` does not synthesize in this toolchain; `BEq`
comparison of `getOk` projections is equivalent for success/failure + payload here.)
-/

open Singular

def getOk : Except String Result → Option Result
  | .ok t => some t
  | .error _ => none

def s0 : State := { config := {} }
def key0 : Nat := 42
def rep0 : Representative := representative s0 key0
def out0 : Output :=
  { representative := rep0, quantity := 1, destination := 90, datum := 0, value := 0 }
def prop0 : Proposal :=
  { registry := 1, key := key0, applicationPolicy := 7, refundAddress := 5,
    initial := out0, scope := [0] }
def appr0 : Approval := { asset := insertAsset prop0, accepted := true }
def s1 : State := { s0 with approvals := [appr0] }
def req0 : Request :=
  { id := 7, operation := .insert, proposal := prop0, token := some (insertAsset prop0),
    held := none, destination := 90, authenticatedOrigin := true }
def s2 : State := { s1 with requests := [req0] }
def item0 : FoldItem := { request := 7, outputId := 99, output := some out0 }
def mint0 : List Delta := [{ asset := rep0, quantity := 1 }]
def w0 : Witnesses :=
  { applicationMint := false, applicationSpend := false, nativeSpend := true,
    representativeMint := true }

def r1 : Except String Result := foldItems s2 [item0]
def t1 : Result := match r1 with | .ok t => t | .error _ => { state := s2 }

def rhs1 : Bool :=
  w0.nativeSpend &&
  (getOk (foldItems s2 [item0]) == some t1) &&
  sameNet t1.logical mint0 &&
  (!(nonzero mint0) || w0.representativeMint) &&
  (!(actionNonzero ([] : List ActionDelta)) || w0.applicationMint)

-- G1: all five conjuncts hold and `step` succeeds (concrete sufficiency instance).
/-- info: (true, true) -/
#guard_msgs in
#eval ((getOk (step s2 (.fold [item0] mint0 [] w0)) == some t1), rhs1)

-- G2: empty fold — trivial conjuncts and success (the `Rejected` mirror).
/-- info: (true, true) -/
#guard_msgs in
#eval ((getOk (step s2 (.fold [] [] [] w0)) == some { state := s2 }),
  (w0.nativeSpend &&
    (getOk (foldItems s2 []) == some { state := s2 }) &&
    sameNet ([] : List Delta) [] &&
    (!(nonzero ([] : List Delta)) || w0.representativeMint) &&
    (!(actionNonzero ([] : List ActionDelta)) || w0.applicationMint)))

def wBad : Witnesses := { w0 with nativeSpend := false }

-- G3: without `nativeSpend`, `step` must NOT succeed (abstract refusal control).
/-- info: false -/
#guard_msgs in
#eval (getOk (step s2 (.fold [item0] mint0 [] wBad)) == some t1)

end Grading
