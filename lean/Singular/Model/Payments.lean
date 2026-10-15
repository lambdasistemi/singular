import Singular.Model.Routing

/-! Exit vocabulary, obligations, settlement and spending judgement. -/

namespace Singular
open Lean

/-! ### Exits and what each one owes

A request leaves the registry's queue by exactly one exit: a fold of one of the
seven edges, a reject, or a retract. Each exit owes payments, stated per exit and
per request, reading no state and no configuration. A payment is a floor: value
an exit's payments do not name — fees, the folder's tip — is unconstrained. -/

/-- The nine ways a request ends: seven folds, a reject, a retract. -/
inductive Exit where
  | fold (e : Edge) | reject | retract
  deriving Repr, BEq, DecidableEq

/-- Who a payment is owed to: the address a delivering fold names under the datum
its request carries, the cage's custody, the request's owner, or the owner
through an output bound to the request it retracts, by that request's
`reference`. -/
inductive Recipient where
  | destination (address : Nat) (datum : Option Nat) | custody | owner (key : Nat)
  | bound (key reference : Nat)
  deriving Repr, DecidableEq

/-- A payment owed: at least `atLeast` lovelace to `recipient`. -/
structure Payment where
  recipient : Recipient
  atLeast : Nat
  deriving Repr, BEq, DecidableEq

/-- Registration owes its deposit at the named destination. Termination and
reject owe it to the owner; retract returns deposit and tip through a
request-reference-bound output. Excluded folds have no success obligations. -/
def obligations (exit : Exit) (request : Request) : List Payment :=
  match exit with
  | .fold .insertActive =>
    [{ recipient := .destination (requestDestination request) request.datum
     , atLeast := request.deposit }]
  | .fold .updateTerminal | .reject =>
    [{ recipient := .owner request.owner, atLeast := request.deposit }]
  | .retract =>
    [{ recipient := .bound request.owner request.reference, atLeast := request.deposit + request.tip }]
  | .fold _ => []

/-- Whether an output carries exactly this datum: the value inline, or no datum
for none. Another value, a datum where none is carried, none where one is, or a
datum presented by hash, is not it. -/
def presentsDatum (datum : Option Nat) (output : TxOutput) : Bool :=
  match datum with
  | some v => output.datum == .inline && output.datumValue == some v
  | none => output.datum == .none

/-- Whether an output pays a recipient, by its role and address, for a destination
by the datum it carries, and for a return bound to a request by the reference an
inline datum presents. An output pays at most one of the recipients one exit
owes, and the state continuation pays none. -/
def paysRecipient (recipient : Recipient) (output : TxOutput) : Bool :=
  match recipient with
  | .custody => output.role == .cage && output.address == some cageAddress
  | .destination address datum =>
    output.role == .destination && output.address == some address && presentsDatum datum output
  | .owner key => output.role == .owner && output.address == some key
  | .bound key reference =>
    output.role == .owner && output.address == some key && output.datum == .inline
      && output.reference == some reference

/-- The chain's reason for a recipient left unpaid: custody or a destination no
output reaches is `absent-custody` or `destination` — an output at the named
address carrying another datum does not reach it; custody or a destination
reached short, or an owner short or unreached, is `deposit-returned`. -/
def unpaidReason (recipient : Recipient) (paying : List TxOutput) : String :=
  match recipient with
  | .custody => if paying.isEmpty then "absent-custody" else "deposit-returned"
  | .destination _ _ => if paying.isEmpty then "destination" else "deposit-returned"
  | .owner _ | .bound _ _ => "deposit-returned"

/-- What the payments owe one recipient: their floors, summed. -/
def owedTo (recipient : Recipient) (payments : List Payment) : Nat :=
  (payments.filter (·.recipient == recipient)).foldl (· + ·.atLeast) 0

/-- What the outputs paying a recipient give it: their summed lovelace, or, for a
return bound to a request, the lovelace of the largest one. The chain settles a
retraction by one sufficient output bound to it, never by fragments. -/
def receivedBy (recipient : Recipient) (outputs : List TxOutput) : Nat :=
  let paying := outputs.filter (paysRecipient recipient)
  match recipient with
  | .bound _ _ => paying.foldl (fun most o => max most o.lovelace) 0
  | _ => paying.foldl (· + ·.lovelace) 0

/-- Whether the chain requires an output to reach this recipient whatever its
floor: a destination is reached only by the carrier of the delivered token at its
address with its datum, which the cage requires whatever the deposit. -/
def requiresCarrier : Recipient → Bool
  | .destination _ _ => true
  | _ => false

/-- Judge a transaction's outputs against the payments owed: `none` when every
recipient receives its summed floor and a destination is reached by its carrier,
else the chain's reason for the first recipient, in the order the payments are
owed, that is not. A destination no output reaches is refused whatever its floor,
as the cage refuses a delivery with no matching carrier. One exit's judgement is
`settle (obligations exit request) outputs`; a batch is the concatenation of its
exits' payments. -/
def settle (payments : List Payment) (outputs : List TxOutput) : Option String :=
  (payments.map (·.recipient)).eraseDups.findSome? fun recipient =>
    let paying := outputs.filter (paysRecipient recipient)
    if requiresCarrier recipient && paying.isEmpty then some (unpaidReason recipient paying)
    else if owedTo recipient payments ≤ receivedBy recipient outputs then none
    else some (unpaidReason recipient paying)

/-- A payment as the (address, value) pair `Result.paid` carries, at the address
`paysRecipient` reads for its recipient: the cage's for custody, the named address
for a destination, and the owner's key for the owner. -/
def paymentPaid (payment : Payment) : Nat × Nat :=
  match payment.recipient with
  | .custody => (cageAddress, payment.atLeast)
  | .destination address _ => (address, payment.atLeast)
  | .owner key | .bound key _ => (key, payment.atLeast)

/-- The refusal an exit's transaction earns by what it spends, before its payments
are judged: a retraction spending any input that holds a state token is refused
`retract-state-spent`, as the chain refuses it. Every other exit spends the state
it folds or returns, and is refused nothing here. -/
def spendRefusal (exit : Exit) (inputs : List TxInput) : Option String :=
  match exit with
  | .retract => if inputs.any (0 < ·.stateTokens) then some "retract-state-spent" else none
  | _ => none


end Singular
