import Singular.Model.Exits

/-! Retraction, fold and rejection admission and admitted execution. -/

namespace Singular
open Lean

/-! ### Which pending requests their owner can retract, and when

A retraction is admitted before it is judged by what it spends and pays. The
request script admits it when three checks hold, in this order: the request
inserts a key or reads a terminal one, the request's owner signed the
transaction, and the transaction's validity interval lies inside the request's
phase 2. An admitted retraction is the `retract` exit, unchanged; a refused one
names the first check it fails and is refused before anything it spends or pays
is looked at. -/

/-- What a retraction's admission reads beyond the request: the transaction's validity
bounds as the request script receives them, and its signatories. Times are POSIX
milliseconds; `validFrom` is the interval's lower bound, included, and `validTo`
its upper bound, excluded, as the ledger hands a script a transaction's validity. -/
structure RetractWitness where
  /-- Legacy wire field retained for compatibility. Admission uses the request booked time. -/
  submittedAt : Nat
  validFrom : Nat
  validTo : Nat
  signatories : List Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- The edges whose pending request its owner can retract: the two inserts and
the read of a terminal key. An update or a delete request cannot be taken back;
the fold that processes it is its only way out. -/
def retractableEdge (e : Edge) : Bool :=
  match e with
  | .insertAbsent | .insertActive | .witnessTerminal => true
  | .updateActive | .updateTerminal | .deleteAbsent | .deleteActive => false

/-- Phase 2 of a request: the retraction's whole validity interval lies after the
processing time has passed since submission and before the retraction time that
follows it has run out. The first instant allowed is
`submittedAt + processTime`, included; the upper bound, being excluded, may reach
`submittedAt + processTime + retractTime` and not pass it. This is the request
script's `in_phase2` over a finite interval. -/
def inPhase2 (c : Config) (r : Request) (w : RetractWitness) : Bool :=
  decide (r.submittedAt + c.processTime ≤ w.validFrom) &&
    decide (w.validTo ≤ r.submittedAt + c.processTime + c.retractTime)

/-- Why a retraction of `r` is not admitted, in the request script's order: a
request that neither inserts a key nor reads a terminal one is
`withdraw-insert-only`; a retraction its owner did not sign is `retract-owner`;
one whose validity interval is not inside phase 2 is `not-phase2`. `none`
admits. -/
def retractAdmission (c : Config) (r : Request) (w : RetractWitness) : Option String :=
  if !retractableEdge r.edge then some "withdraw-insert-only"
  else if !w.signatories.contains r.owner then some "retract-owner"
  else if !inPhase2 c r w then some "not-phase2"
  else none

/-- The finite, excluded upper validity bound the ledger hands to a fold. -/
structure FoldWitness where
  validTo : Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- Whether the fold's upper bound is at or before this request's deadline. -/
def inPhase1 (c : Config) (submittedAt validTo : Nat) : Bool :=
  decide (validTo ≤ submittedAt + c.processTime)

/-- Fold admission, before the law: fixed edges, then every request's window. -/
def foldAdmission (c : Config) (batch : List Request) (w : FoldWitness) : Option String :=
  if !batch.all (fun r => allowed r.edge) then some "edge-inadmissible"
  else if !batch.all (fun r => inPhase1 c r.submittedAt w.validTo) then some "not-phase1"
  else none

/-- A batch under its finite validity witness, admission before the batch law. -/
def admittedFoldBatch (s : RegistryState) (batch : List Request) (w : FoldWitness) :
    Except String Result :=
  match foldAdmission s.config batch w with
  | some why => .error why
  | none => foldBatch s batch

/-! ### Protected rejection

Evidence is an authenticated logical read, not Merkle proof bytes. Its full
registry configuration (including root and identity), request and reason must match the actual
state. A concrete verifier must establish this correspondence: invalid proof
bytes are never evidence of lifecycle incompatibility.
-/

inductive RejectReason where
  | mismatch (leaf : Leaf)
  | expired
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

structure RejectEvidence where
  registry : Config
  request : Request
  reason : RejectReason
  deriving BEq, DecidableEq

/-- A finite lower-inclusive, upper-exclusive transaction interval carrying the evidence. -/
structure RejectWitness where
  evidence : RejectEvidence
  validFrom : Nat
  validTo : Nat
  deriving BEq, DecidableEq

/-- Only a verified lifecycle mismatch or expiry after both windows authorizes
rejection. Evidence is bound to this request and this intermediate state, in the order the
data model states: evidence present; registry, request identity and root; request; interval;
then the ground. -/
def rejectAdmission (s : RegistryState) (r : Request) (w : Option RejectWitness) : Option String :=
  match w with
  | none => some "reject-evidence-missing"
  | some w =>
    if decide (w.evidence.registry ≠ s.config) || r.registryId != s.config.registryId ||
        s.config.root != rootOf s.trie then
      some "reject-registry-mismatch"
    else if w.evidence.request ≠ r then some "reject-request-mismatch"
    else if w.validFrom >= w.validTo then some "reject-invalid-interval"
    else match w.evidence.reason with
      | .mismatch leaf =>
        if leaf != trieGet s.trie r.key then some "reject-leaf-mismatch"
        else if (transition r.edge leaf).isSome then some "reject-compatible"
        else none
      | .expired =>
        if r.submittedAt + s.config.processTime + s.config.retractTime ≤ w.validFrom then none
        else some "reject-not-expired"

/-- The admission an exit is subject to: a retract's is `retractAdmission`; a rejection's is
`rejectAdmission`; a fold uses `foldAdmission` with the finite upper bound. -/
def exitAdmission (s : RegistryState) (exit : Exit) (r : Request) (w : RetractWitness)
    (rejection : Option RejectWitness := none) : Option String :=
  match exit with
  | .retract => retractAdmission s.config r w
  | .reject => rejectAdmission s r rejection
  | .fold _ => foldAdmission s.config [r] { validTo := w.validTo }

/-- One exit as a model step, admission first: refused with the admission's
reason, otherwise exactly `exitStep`. -/
def admittedExitStep (state : RegistryState) (exit : Exit) (request : Request)
    (witness : RetractWitness) (rejection : Option RejectWitness := none) : Except String Result :=
  match exitAdmission state exit request witness rejection with
  | some why => .error why
  | none => exitStep state exit request

/-- The transaction of an exit, admission first: refused with the admission's
reason, otherwise exactly the transaction `txOfExit` builds. -/
def admittedTxOfExit (state : RegistryState) (exit : Exit) (request : Request)
    (witness : RetractWitness) (lovelace : Nat) (rejection : Option RejectWitness := none) : Except String Tx :=
  match exitAdmission state exit request witness rejection with
  | some why => .error why
  | none => txOfExit state exit request lovelace

/-- The refusal an exit's transaction earns, in the request script's order:
admission, then what it spends (`spendRefusal`), then what it pays (`settle`).
A rejection or retraction refused admission is refused with that reason whatever it spends
and pays. -/
def exitRefusal (s : RegistryState) (exit : Exit) (request : Request) (witness : RetractWitness)
    (inputs : List TxInput) (outputs : List TxOutput) (rejection : Option RejectWitness := none) : Option String :=
  (exitAdmission s exit request witness rejection).orElse fun _ =>
    (spendRefusal exit inputs).orElse fun _ => settle (obligations exit request) outputs


end Singular
