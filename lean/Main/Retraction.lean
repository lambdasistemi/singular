import Main.Exits

/-! Retraction admission and witness checks. -/

open Singular
open Singular.Driver
open Lean

/-! ### Which pending requests their owner can retract, and when

Each row retracts a request of owner 42, deposit 55 and tip 7 from `exitState`,
which holds keys in three different leaves. The request was submitted at 100;
with the corpus configuration's processing time 2 and retraction time 3, phase 2
runs from 102, included, to 105, which the excluded upper bound may reach and not
pass. The expected verdicts are the request script's, typed here; the verdicts
compared with them are computed by `admittedExitStep`, `admittedTxOfExit` and
`exitRefusal`.

Consumers of `retract_admitted_iff` (every verdict), `retract_refusal_first_failing`
(every reason, including rows failing more than one check),
`admitted_exit_is_the_exit` (every admitted retraction, and every other exit
under a witness a retraction would fail) and `admission_refuses_first` (the
judgement rows). -/

/-- A retraction submitted at 100, signed by `signatories`, valid from `validFrom`,
included, to `validTo`, excluded. -/
def retractWitness (signatories : List Nat) (validFrom validTo : Nat) : RetractWitness :=
  { submittedAt := 100, validFrom := validFrom, validTo := validTo, signatories := signatories }

/-- `(id, edge, key, witness, expected refusal)`; `none` expects admission. -/
def admissionRows : List (String × Edge × Nat × RetractWitness × Option String) :=
  [ ("RA01-insert-absent-retracted", .insertAbsent, 9, retractWitness [77, 42] 102 105, none)
  , ("RA02-insert-active-retracted", .insertActive, 9, retractWitness [42, 77] 102 105, none)
  , ("RA03-read-retracted", .witnessTerminal, 4, retractWitness [42] 103 104, none)
  , ("RA04-update-active-not-retractable", .updateActive, 4, retractWitness [42] 102 105,
      some "withdraw-insert-only")
  , ("RA05-update-terminal-not-retractable", .updateTerminal, 4, retractWitness [42] 102 105,
      some "withdraw-insert-only")
  , ("RA06-delete-absent-not-retractable", .deleteAbsent, 6, retractWitness [42] 102 105,
      some "withdraw-insert-only")
  , ("RA07-delete-active-unsigned-outside-phase-2", .deleteActive, 4, retractWitness [] 0 1000,
      some "withdraw-insert-only")
  , ("RA08-unsigned-in-phase-2", .insertActive, 9, retractWitness [77, 88] 102 105,
      some "retract-owner")
  , ("RA09-unsigned-outside-phase-2", .insertAbsent, 9, retractWitness [77] 101 106,
      some "retract-owner")
  , ("RA10-starts-one-before-phase-2", .insertActive, 9, retractWitness [42] 101 105,
      some "not-phase2")
  , ("RA11-ends-one-past-phase-2", .insertActive, 9, retractWitness [42] 102 106,
      some "not-phase2")
  , ("RA12-inside-phase-1", .insertAbsent, 9, retractWitness [42] 50 60, some "not-phase2")
  , ("RA13-inside-phase-3", .witnessTerminal, 4, retractWitness [42, 77] 106 110,
      some "not-phase2") ]

/-- What an admission row violates: the step's or the transaction's verdict or
reason differs from the script's; an admitted retraction is not the retract exit
(the state moved, something was minted, the owner is not paid the deposit and the
tip, or the transaction spends more than the request, pays anything but one owner
output, or requires a signer other than the owner alone); the witness does not
read back from its own JSON. -/
def admissionFailures : List String :=
  admissionRows.flatMap fun (id, e, k, w, expected) =>
    let r := exitStepRequest e k
    (match admittedExitStep exitState .retract r w, expected with
      | .ok t, none =>
        if t.state == exitState && t.mint.isEmpty && t.paid == [(42, 62)] then []
        else [s!"{id}: the admitted retraction is not the retract exit"]
      | .error why, some want => if why == want then [] else [s!"{id}: refused {why}, expected {want}"]
      | .ok _, some want => [s!"{id}: admitted, expected {want}"]
      | .error why, none => [s!"{id}: refused {why}, expected admission"]) ++
    (match admittedTxOfExit exitState .retract r w 3, expected with
      | .ok tx, none =>
        if tx.signers == [42] && tx.inputs.map (·.role) == [.request]
            && tx.outputs.map (·.role) == [.owner] && tx.mint.isEmpty && tx.refunds == [(42, 62)]
        then [] else [s!"{id}: the admitted retraction's transaction is not the retract exit's"]
      | .error why, some want =>
        if why == want then [] else [s!"{id}: the transaction refused {why}, expected {want}"]
      | .ok _, some want => [s!"{id}: the transaction was built, expected {want}"]
      | .error why, none => [s!"{id}: the transaction refused {why}, expected admission"]) ++
    (match (fromJson? (toJson w) : Except String RetractWitness) with
      | .ok v => if v == w then [] else [s!"{id}: the witness reads back changed from its JSON"]
      | .error why => [s!"{id}: the witness does not read back from its JSON ({why})"])

/-- A witness every retraction fails: nobody signed, and the interval is not in
phase 2. -/
def failingWitness : RetractWitness := retractWitness [] 0 1000

/-- Retraction admission does not change folds: under a failing retraction
witness each fold steps and builds as before; and an
admitted retraction steps and builds exactly as the retract exit. -/
def admittedExitFailures : List String :=
  let others := (exitEdges.map Exit.fold).flatMap fun x =>
    exitEdges.flatMap fun e => paidKeys.flatMap fun k =>
      let r := exitStepRequest e k
      let expectedStep := match exitAdmission paidState x r failingWitness with
        | none => exitStep paidState x r
        | some why => .error why
      let expectedTx := match exitAdmission paidState x r failingWitness with
        | none => txOfExit paidState x r 3
        | some why => .error why
      if sameStep (admittedExitStep paidState x r failingWitness) expectedStep
          && sameTx (admittedTxOfExit paidState x r failingWitness 3) expectedTx
      then [] else [s!"{repr x} at {repr e}/{k}: the exit differs from its admission then its law"]
  let r := exitStepRequest .insertActive 9
  let w := retractWitness [42, 77] 102 105
  let retracted :=
    if sameStep (admittedExitStep exitState .retract r w) (exitStep exitState .retract r)
        && sameTx (admittedTxOfExit exitState .retract r w 3) (txOfExit exitState .retract r 3)
    then [] else ["an admitted retraction is not the retract exit"]
  others ++ retracted

/-- `(id, exit, request, witness, inputs, outputs, expected refusal)`: what a
transaction spends and pays, judged with admission first. -/
def judgementRows : List (String × Exit × Request × RetractWitness × List TxInput ×
    List TxOutput × Option String) :=
  let r := exitStepRequest .insertActive 9
  let signed := retractWitness [42] 102 105
  let spent := txInputs (txOfExit exitState .retract r 3)
  let paid := txOutputs (txOfExit exitState .retract r 3)
  let short := paid.map fun o => { o with lovelace := o.lovelace - 1 }
  [ ("RJ01-unsigned-beside-a-state-token", .retract, r, retractWitness [77] 102 105,
      spent ++ [stateTokenInput], [], some "retract-owner")
  , ("RJ02-update-beside-a-state-token-unpaid", .retract, exitStepRequest .updateActive 4, signed,
      spent ++ [stateTokenInput], [], some "withdraw-insert-only")
  , ("RJ03-outside-phase-2-beside-a-state-token", .retract, r, retractWitness [42] 101 105,
      spent ++ [stateTokenInput], paid, some "not-phase2")
  , ("RJ04-admitted-beside-a-state-token", .retract, r, signed,
      spent ++ [stateTokenInput], paid, some "retract-state-spent")
  , ("RJ05-admitted-paid-short", .retract, r, signed, spent, short, some "deposit-returned")
  , ("RJ06-admitted-as-built", .retract, r, signed, spent, paid, none)
  , ("RJ07-reject-under-a-failing-witness", .reject, r, failingWitness,
      txInputs (txOfExit exitState .reject r 3), txOutputs (txOfExit exitState .reject r 3), some "reject-evidence-missing")
  , ("RJ08-fold-past-deadline", .fold .insertActive, r, failingWitness,
      txInputs (txOf exitState r 3), txOutputs (txOf exitState r 3), some "not-phase1")
  , ("RJ09-fold-at-deadline", .fold .insertActive, r, { failingWitness with validTo := r.submittedAt + exitState.config.processTime },
      txInputs (txOf exitState r 3), txOutputs (txOf exitState r 3), none) ]

def judgementFailures : List String :=
  judgementRows.flatMap fun (id, x, r, w, inputs, outputs, expected) =>
    let got := exitRefusal exitState x r w inputs outputs
    if got == expected then [] else [s!"{id}: judged {got}, expected {expected}"]

-- The judgement rows are not vacuous: the retraction and the exits under a
-- failing witness each build a transaction, and a retraction spends one input.
#guard (txInputs (txOfExit exitState .retract (exitStepRequest .insertActive 9) 3)).length == 1
#guard (txOutputs (txOfExit exitState .reject (exitStepRequest .insertActive 9) 3)).length == 2
#guard (txOutputs (txOf exitState (exitStepRequest .insertActive 9) 3)).length ≥ 2

-- A saved state replays with the datum each holding's delivery wrote: a holding
-- serialised and read back is the same holding, with a datum value or none.
#guard [none, some 0, some 7].all fun d =>
  let h : Holding := { key := 42, kind := .active, output := 555, datum := d }
  match (fromJson? (toJson h) : Except String Holding) with
  | .ok back => back == h
  | .error _ => false
