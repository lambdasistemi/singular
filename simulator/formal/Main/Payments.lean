import Main.Transactions

/-! Payment settlement fixtures and observed transaction outputs. -/

open Singular
open Singular.Driver
open Lean

/-! ### Where every exit's deposit goes, and the judgement of a transaction's outputs

Checked when this module elaborates: `lake build` fails on the first row that
does not hold. The expected payments are the rule table's; the expected reasons
are the chain's trace names. -/

/-- A request whose payment-relevant fields all differ: owner 42, refund address
91, destination 99, deposit 55, tip 7, sitting at reference 31. -/
def exitRequest (e : Edge) : Request :=
  { edge := e, key := 5, owner := 42, refundAddress := 91, output := 99
  , deposit := 55, tip := 7, reference := 31 }

-- The rule table, one row per exit.
#guard obligations (.fold .insertAbsent) (exitRequest .insertAbsent) ==
  []
#guard obligations (.fold .insertActive) (exitRequest .insertActive) ==
  [{ recipient := .destination 99 none, atLeast := 55 }]
#guard obligations (.fold .updateActive) (exitRequest .updateActive) ==
  []
#guard obligations (.fold .witnessTerminal) (exitRequest .witnessTerminal) ==
  []
#guard obligations (.fold .updateTerminal) (exitRequest .updateTerminal) ==
  [{ recipient := .owner 42, atLeast := 55 }]
#guard obligations (.fold .deleteAbsent) (exitRequest .deleteAbsent) ==
  []
#guard obligations (.fold .deleteActive) (exitRequest .deleteActive) ==
  []
#guard obligations .reject (exitRequest .insertActive) ==
  [{ recipient := .owner 42, atLeast := 55 }]
#guard obligations .retract (exitRequest .insertActive) ==
  [{ recipient := .bound 42 31, atLeast := 62 }]
-- Reject and retract owe the owner whatever edge the request named; a retract
-- owes it through an output bound to the request's own reference.
#guard obligations .reject (exitRequest .insertAbsent) ==
  [{ recipient := .owner 42, atLeast := 55 }]
#guard obligations .retract (exitRequest .insertAbsent) ==
  [{ recipient := .bound 42 31, atLeast := 62 }]

-- The request carries its tip in its JSON, and a request that names none holds none.
#guard match (toJson (exitRequest .insertActive)).getObjValAs? Nat "tip" with
  | .ok 7 => true | _ => false
#guard ({ edge := .insertActive, key := 5 } : Request).tip == 0

/-- One exit's settlement: the outputs that carry none of its payment, and the
one output that carries it. The three controls are that output as built, one
lovelace short, and at another address. -/
structure SettleCase where
  exit : Exit
  request : Request
  context : List TxOutput
  carrier : TxOutput

def SettleCase.untampered (c : SettleCase) : Option String :=
  settle (obligations c.exit c.request) (c.context ++ [c.carrier])

def SettleCase.shortByOne (c : SettleCase) : Option String :=
  settle (obligations c.exit c.request)
    (c.context ++ [{ c.carrier with lovelace := c.carrier.lovelace - 1 }])

def SettleCase.otherAddress (c : SettleCase) : Option String :=
  settle (obligations c.exit c.request)
    (c.context ++ [{ c.carrier with address := c.carrier.address.map (· + 1) }])

/-- An output paying `lovelace` back to `owner`. -/
def ownerOutput (owner lovelace : Nat) : TxOutput :=
  { role := .owner, datum := .inline, address := some owner, stateTokens := 0
  , config := none, commitment := none, assets := [], lovelace := lovelace }

def txOutputs (t : Except String Tx) : List TxOutput :=
  match t with | .ok tx => tx.outputs | .error _ => []

def settleInsertActiveRequest : Request :=
  { req .insertActive 8 42 99 with deposit := 55, tip := 7, reference := 31 }

/-- The token-delivering fold: the model's own transaction, its destination
output carrying the deposit. -/
def settleInsertActive : SettleCase :=
  let outs := txOutputs (txOf s0 settleInsertActiveRequest 1)
  let dest := (outs.find? (·.role == .destination)).getD (ownerOutput 0 0)
  { exit := .fold .insertActive, request := settleInsertActiveRequest
  , context := outs.filter (·.role != .destination)
  , carrier := { dest with lovelace := settleInsertActiveRequest.deposit } }

def settleUpdateTerminalRequest : Request :=
  { req .updateTerminal 8 42 99 with deposit := 55, tip := 7 }

/-- The fold delivering nothing: the model's own transaction, its owner output
carrying the deposit back. -/
def settleUpdateTerminal : SettleCase :=
  let outs := txOutputs (txOf (booked s0 8) settleUpdateTerminalRequest 1)
  { exit := .fold .updateTerminal, request := settleUpdateTerminalRequest
  , context := outs.filter (·.role != .owner)
  , carrier := (outs.find? (·.role == .owner)).getD (ownerOutput 0 0) }

/-- Reject: the registry continues unchanged, and the owner is refunded. -/
def settleReject : SettleCase :=
  { exit := .reject, request := settleInsertActiveRequest
  , context := [txStateOutput (emptyResult s0)]
  , carrier := ownerOutput 42 settleInsertActiveRequest.deposit }

/-- Retract: the owner takes back everything the request held, through an output
whose inline datum is the request's own reference. -/
def settleRetract : SettleCase :=
  { exit := .retract, request := settleInsertActiveRequest, context := []
  , carrier := { ownerOutput 42 (settleInsertActiveRequest.deposit + settleInsertActiveRequest.tip)
                 with reference := some settleInsertActiveRequest.reference } }

-- The model's own transactions exist, so the controls above are not vacuous.
#guard (txOutputs (txOf s0 settleInsertActiveRequest 1)).any (·.role == .destination)
#guard (txOutputs (txOf (booked s0 8) settleUpdateTerminalRequest 1)).any (·.role == .owner)

#guard settleInsertActive.untampered == none
#guard settleInsertActive.shortByOne == some "deposit-returned"
#guard settleInsertActive.otherAddress == some "destination"
#guard settleUpdateTerminal.untampered == none
#guard settleUpdateTerminal.shortByOne == some "deposit-returned"
#guard settleUpdateTerminal.otherAddress == some "deposit-returned"
#guard settleReject.untampered == none
#guard settleReject.shortByOne == some "deposit-returned"
#guard settleReject.otherAddress == some "deposit-returned"
#guard settleRetract.untampered == none
#guard settleRetract.shortByOne == some "deposit-returned"
#guard settleRetract.otherAddress == some "deposit-returned"

-- Retract returns the tip: the deposit alone does not settle it.
#guard settle (obligations .retract settleInsertActiveRequest)
  [{ settleRetract.carrier with lovelace := settleInsertActiveRequest.deposit }]
    == some "deposit-returned"

/-- A second request retracted beside `settleInsertActiveRequest`, at reference 32. -/
def secondRetracted : Request :=
  { settleInsertActiveRequest with key := 9, reference := 32 }

-- A retraction's return is bound to the request it retracts, as the chain binds it:
-- an owner output presenting another request's reference, or none, returns nothing;
-- fragments bound to it are not summed; and one bound output cannot return two
-- retractions, each of which needs its own.
#guard settle (obligations .retract settleInsertActiveRequest)
  [{ settleRetract.carrier with reference := some 32 }] == some "deposit-returned"
#guard settle (obligations .retract settleInsertActiveRequest)
  [{ settleRetract.carrier with reference := none }] == some "deposit-returned"
-- The reference binds only as the output's inline datum: presented any other way,
-- or by an output with no datum, it returns nothing.
#guard settle (obligations .retract settleInsertActiveRequest)
  [{ settleRetract.carrier with datum := .none }] == some "deposit-returned"
#guard settle (obligations .retract settleInsertActiveRequest)
  [{ settleRetract.carrier with datum := .hashed }] == some "deposit-returned"
#guard settle (obligations .retract settleInsertActiveRequest)
  [{ settleRetract.carrier with lovelace := 61 }, { settleRetract.carrier with lovelace := 1 }]
    == some "deposit-returned"
-- A sufficient bound output settles it whatever else is bound beside it.
#guard settle (obligations .retract settleInsertActiveRequest)
  [settleRetract.carrier, { settleRetract.carrier with lovelace := 1 }] == none
#guard settle (obligations .retract settleInsertActiveRequest ++ obligations .retract secondRetracted)
  [{ settleRetract.carrier with lovelace := 124 }] == some "deposit-returned"
#guard settle (obligations .retract settleInsertActiveRequest ++ obligations .retract secondRetracted)
  [settleRetract.carrier, { settleRetract.carrier with reference := some 32 }] == none

-- The model's retraction returns everything the request held through one output at
-- the owner's key whose inline datum is the request's own reference; a reject
-- refunds the owner through an output with no datum that returns the request's
-- approval, as a fold delivering nothing does.
#guard settleInsertActiveRequest.approval.isSome
#guard txOutputs (txOfExit s0 .retract settleInsertActiveRequest 1) ==
  [{ role := .owner, datum := .inline, address := some 42, stateTokens := 0, config := none
   , commitment := none, assets := [], lovelace := 62, reference := some 31 }]
#guard (txOutputs (txOfExit s0 .reject settleInsertActiveRequest 1)).filter (·.role == .owner) ==
  [{ role := .owner, datum := .none, address := some 42, stateTokens := 0, config := none
   , commitment := settleInsertActiveRequest.approval.map (·.assetName), assets := []
   , lovelace := 55 }]

def txInputs (t : Except String Tx) : List TxInput :=
  match t with | .ok tx => tx.inputs | .error _ => []

/-- An input holding a registry state token. -/
def stateTokenInput : TxInput :=
  { role := .state, datum := .inline, stateTokens := 1, approvals := 0, lovelace := 0 }

-- A retraction spends no input holding a state token: beside one it is refused
-- `retract-state-spent`, before its payment is judged. The model's own retraction
-- spends none, and no other exit is refused for what it spends: a reject spends
-- the state it returns.
#guard spendRefusal .retract (txInputs (txOfExit s0 .retract settleInsertActiveRequest 1)
  ++ [stateTokenInput]) == some "retract-state-spent"
#guard spendRefusal .retract (txInputs (txOfExit s0 .retract settleInsertActiveRequest 1)) == none
#guard (txInputs (txOfExit s0 .reject settleInsertActiveRequest 1)).any (0 < ·.stateTokens)
#guard spendRefusal .reject (txInputs (txOfExit s0 .reject settleInsertActiveRequest 1)) == none
#guard [Edge.insertAbsent, .insertActive, .updateActive, .updateTerminal, .deleteAbsent,
    .deleteActive, .witnessTerminal].all fun e => spendRefusal (.fold e) [stateTokenInput] == none

-- Every recipient is paid only by an output of its role at its address: the same
-- lovelace at another address, or under any other role, pays nothing.
#guard [ (obligations (.fold .insertActive) settleInsertActiveRequest, .destination, 99, "destination")
       , (obligations .reject settleInsertActiveRequest, .owner, 42, "deposit-returned") ].all
    fun (owed, role, address, reason) =>
      let paid := { ownerOutput address 1000 with role := role, datum := .none }
      settle owed [paid] == none &&
      settle owed [{ paid with address := some (address + 1) }] == some reason &&
      [TxRole.state, .request, .destination, .witness, .owner].all fun other =>
        other == role || settle owed [{ paid with role := other }] != none

-- Two obligations to one recipient are summed: one output sized for one is refused,
-- two such outputs settle both.
#guard settle (obligations .reject settleInsertActiveRequest ++ obligations .reject settleInsertActiveRequest)
  [ownerOutput 42 55] == some "deposit-returned"
#guard settle (obligations .reject settleInsertActiveRequest ++ obligations .reject settleInsertActiveRequest)
  [ownerOutput 42 55, ownerOutput 42 55] == none

-- The state continuation pays no recipient, even at the recipient's own address.
#guard [ (obligations (.fold .insertActive) settleInsertActiveRequest, some 99, "destination")
       , (obligations .reject settleInsertActiveRequest, some 42, "deposit-returned") ].all
    fun (owed, address, reason) =>
      settle owed [{ txStateOutput (emptyResult s0) with address := address, lovelace := 1000 }] == some reason
-- An output counts toward one recipient: a destination output does not pay the owner.
#guard settle (obligations .reject settleInsertActiveRequest)
  [{ ownerOutput 42 55 with role := .destination }] == some "deposit-returned"
-- A destination is paid only by an output carrying exactly the request's datum:
-- the value inline, or no datum when the request carries none. Another value, a
-- datum where none is carried, none where one is, or a datum by hash, reaches no
-- destination and is refused `destination`.
def carrying (datum : DatumForm) (value : Option Nat) : TxOutput :=
  { ownerOutput 99 55 with role := .destination, datum := datum, datumValue := value }
#guard [ (none, carrying .none none, true), (none, carrying .inline (some 7), false)
       , (none, carrying .hashed none, false)
       , (some 7, carrying .inline (some 7), true), (some 7, carrying .inline (some 8), false)
       , (some 7, carrying .none none, false), (some 7, carrying .hashed (some 7), false)
       , (some 7, carrying .inline none, false) ].all
    fun (datum, output, pays) =>
      settle (obligations (.fold .insertActive) { settleInsertActiveRequest with datum := datum })
        [output] == if pays then none else some "destination"
-- The model builds the destination output carrying the request's datum, and it settles.
#guard [none, some 0, some 7].all fun d =>
  let r := { settleInsertActiveRequest with datum := d }
  let outs := txOutputs (txOf s0 r 1)
  outs.any (fun o => o.role == .destination && presentsDatum d o)
    && settle (obligations (.fold .insertActive) r) outs == none

-- The reason is the first unpaid recipient's, in the order the payments are owed.
#guard settle [{ recipient := .owner 42, atLeast := 55 }, { recipient := .destination 99 none, atLeast := 55 }]
  [] == some "deposit-returned"
#guard settle [{ recipient := .destination 99 none, atLeast := 55 }, { recipient := .owner 42, atLeast := 55 }]
  [] == some "destination"
