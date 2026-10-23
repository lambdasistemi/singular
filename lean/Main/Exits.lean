import Main.Payments

/-! Exit execution and payment checks. -/

open Singular
open Singular.Driver
open Lean

/-! ### Every exit is a model step

Checked when this module elaborates. The registry below holds keys in three
different leaves, so an exit that moved anything would show; the requests name
every edge, the ones the law admits and the ones it refuses alike. -/

def exitEdges : List Edge :=
  [.insertAbsent, .insertActive, .updateActive, .updateTerminal,
   .deleteAbsent, .deleteActive, .witnessTerminal]

/-- Keys 3 and 4 active, key 6 absent under custody. -/
def exitState : RegistryState := legacyAbsent (booked (booked s0 3) 4) 6

/-- A request of edge `e` at key `k`, owner 42, deposit 55, tip 7. -/
def exitStepRequest (e : Edge) (k : Nat) : Request :=
  { req e k 42 99 with deposit := 55, tip := 7, submittedAt := 100 }

/-- The keys the rows range over: active, absent, and unbound. -/
def exitKeys : List Nat := [4, 6, 9]

/-- The step leaves the registry as it was, mints nothing and pays `paid`. -/
def leavesRegistry (s : RegistryState) (paid : List (Nat × Nat)) :
    Except String Result → Bool
  | .ok r => r.state == s && r.mint.isEmpty && r.paid == paid
  | .error _ => false

-- A fold of any other edge is refused, whatever the law would say of the request.
#guard exitEdges.all fun e => exitEdges.all fun named => exitKeys.all fun k =>
  named == e || sameStep (exitStep exitState (.fold e) (exitStepRequest named k))
    (.error "exit-edge-mismatch")
-- Reject pays the owner the deposit back, and retract the deposit and the tip,
-- for a request of any edge at any key: neither changes the registry or mints.
#guard exitEdges.all fun e => exitKeys.all fun k =>
  leavesRegistry exitState [(42, 55)] (exitStep exitState .reject (exitStepRequest e k))
#guard exitEdges.all fun e => exitKeys.all fun k =>
  leavesRegistry exitState [(42, 62)] (exitStep exitState .retract (exitStepRequest e k))

-- A fold's transaction is the edge's own, and a fold of another edge builds none.
#guard exitEdges.all fun e => exitKeys.all fun k =>
  match txOfExit exitState (.fold e) (exitStepRequest e k) 3, txOf exitState (exitStepRequest e k) 3 with
  | .ok a, .ok b => a == b
  | .error a, .error b => a == b
  | _, _ => false
#guard exitEdges.all fun e => exitEdges.all fun named => exitKeys.all fun k =>
  named == e || match txOfExit exitState (.fold e) (exitStepRequest named k) 3 with
    | .error why => why == "exit-edge-mismatch"
    | .ok _ => false

/-- The roles of a built transaction's inputs and outputs, and whether it mints
nothing, requires exactly `signers`, refunds exactly `paid` and settles `exit`'s
obligations. -/
def exitTxShape (exit : Exit) (r : Request) (signers : List Nat) (paid : List (Nat × Nat)) :
    Except String Tx → Option (List TxRole × List TxRole)
  | .ok tx =>
    if tx.mint.isEmpty && tx.signers == signers && tx.refunds == paid
       && settle (obligations exit r) tx.outputs == none
    then some (tx.inputs.map (·.role), tx.outputs.map (·.role)) else none
  | .error _ => none

-- A reject is settled inside a transaction that spends the state and returns it
-- unchanged and requires no signer; a retract is its own transaction, touches no
-- state and requires the owner's signature, as the chain does. Each pays the owner
-- one output carrying what it owes, and so settles its obligations.
#guard exitEdges.all fun e => exitKeys.all fun k =>
  exitTxShape .reject (exitStepRequest e k) [] [(42, 55)]
    (txOfExit exitState .reject (exitStepRequest e k) 3)
    == some ([.state, .request], [.state, .owner])
#guard exitEdges.all fun e => exitKeys.all fun k =>
  exitTxShape .retract (exitStepRequest e k) [42] [(42, 62)]
    (txOfExit exitState .retract (exitStepRequest e k) 3)
    == some ([.request], [.owner])
#guard exitEdges.all fun e => exitKeys.all fun k =>
  match txOfExit exitState .reject (exitStepRequest e k) 3 with
  | .ok tx => tx.outputs.head?.bind (·.config) == some exitState.config
  | .error _ => false

/-! ### Every exit carries its payments

A fold's `paid` is what the exit owes, then the custody refunds its step already
pays; its transaction carries each floor in the output that pays it, and settles.
The registry below adds a terminal key to `exitState`, so every edge is admitted at
one of the keys the rows range over. -/

/-- Keys 3 and 4 active, key 5 terminal, key 6 absent under custody. -/
def paidState : RegistryState :=
  match step (booked exitState 5) (req .updateTerminal 5 42 555) with
  | .ok r => r.state | .error _ => exitState

/-- The keys the payment rows range over: active, terminal, absent, unbound. -/
def paidKeys : List Nat := [4, 5, 6, 9]

/-- Where a fold of edge `e` pays the deposit of `exitStepRequest e k`, read off the
rule table: the cage for `insertAbsent`, the named output 99 for the edges that
deliver a token, the owner 42 for the edges that deliver nothing. -/
def foldPaysDepositTo : Edge → Nat
  | .insertActive => 99
  | .updateTerminal => 42
  | _ => 0

def deliversToken (e : Edge) : Bool := foldPaysDepositTo e == 99
def returnsDeposit (e : Edge) : Bool := foldPaysDepositTo e == 42

-- Not vacuous: every edge is admitted at one of the keys.
#guard exitEdges.filter (fun e => allowed e) |>.all fun e => paidKeys.any fun k =>
  match step paidState (exitStepRequest e k) with | .ok _ => true | .error _ => false

-- A fold pays the deposit where the rule table says, then what its step pays.
#guard exitEdges.all fun e => paidKeys.all fun k =>
  match exitStep paidState (.fold e) (exitStepRequest e k), step paidState (exitStepRequest e k) with
  | .ok a, .ok b =>
    a.state == b.state && a.mint == b.mint && a.paid == (foldPaysDepositTo e, 55) :: b.paid
  | .error x, .error y => x == y
  | _, _ => false

-- A fold's transaction carries the deposit in the output that pays it: the
-- destination output of a delivering edge, one owner output of an edge that
-- delivers nothing, with no datum and naming the approval it returns; an edge
-- that delivers nothing has no destination output (#304); and it refunds exactly
-- what the exit pays.
#guard exitEdges.all fun e => paidKeys.all fun k =>
  match exitStep paidState (.fold e) (exitStepRequest e k),
        txOfExit paidState (.fold e) (exitStepRequest e k) 3 with
  | .ok t, .ok tx =>
    (tx.outputs.filter (·.role == .destination)).map (·.lovelace)
        == (if deliversToken e then [55] else []) &&
      tx.outputs.filter (·.role == .owner)
        == (if returnsDeposit e then
              [{ ownerOutput 42 55 with
                 datum := .none, commitment := (exitStepRequest e k).approval.map (·.assetName) }]
            else []) &&
      tx.refunds == t.paid
  | .error x, .error y => x == y
  | _, _ => false

/-- The nine exits. -/
def allExits : List Exit := exitEdges.map .fold ++ [.reject, .retract]

-- Every transaction an exit builds settles what the exit owes, and every exit
-- builds one at some key.
#guard allExits.all fun x => exitEdges.all fun e => paidKeys.all fun k =>
  match txOfExit paidState x (exitStepRequest e k) 3 with
  | .ok tx => settle (obligations x (exitStepRequest e k)) tx.outputs == none
  | .error _ => true
#guard (allExits.filter fun x => match x with | .fold e => allowed e | _ => true).all fun x => exitEdges.any fun e => paidKeys.any fun k =>
  match txOfExit paidState x (exitStepRequest e k) 3 with | .ok _ => true | .error _ => false

-- The driver's operations are the nine exits: the seven edges by their own
-- names, then reject and retract. It judges what a transaction spends, then what
-- it pays, and answers two batch questions, neither observing a transaction;
-- the surface's protocol moved for each, and again when a request came to carry
-- its datum.
#guard declaredOperations == exitEdges.map edgeName ++ ["reject", "retract"]
#guard surface.protocolVersion == 8
#guard surface.judgements == ["spend", "settle"]
#guard surface.batchQuestions.map (·.1) == ["foldBatch", "rejectBatch"]
#guard surface.batchQuestions.all fun q => !q.2.contains "tx"

/-- The scenario a caller asks the driver to judge a settle case's outputs for:
the case's own exit and request, from the empty registry. -/
def judgedScenario (c : SettleCase) : Scenario :=
  { id := "judged", theoremName := "", statementSha256 := "", kind := "witness"
  , mutates := none, requiresReachableState := false, start := s0, setup := []
  , exit := c.exit, request := c.request, lovelace := 1 }

/-- The driver's judgement of a settle case's three controls: its payment output
as built, one lovelace short, and at another address. -/
def SettleCase.judged (c : SettleCase) : List (Option String) :=
  let judge := judgeSurface (judgedScenario c) []
  [ judge (c.context ++ [c.carrier])
  , judge (c.context ++ [{ c.carrier with lovelace := c.carrier.lovelace - 1 }])
  , judge (c.context ++ [{ c.carrier with address := c.carrier.address.map (· + 1) }]) ]

-- The driver judges outputs a caller observed against what the scenario's own exit
-- owes: a delivering and a non-delivering fold, untampered, short and misdirected.
#guard settleInsertActive.judged == [none, some "deposit-returned", some "destination"]
#guard settleUpdateTerminal.judged == [none, some "deposit-returned", some "deposit-returned"]
-- A reject's refund, as built, short and misdirected.
#guard settleReject.judged == [none, some "deposit-returned", some "deposit-returned"]

/-- The driver's judgement of a retraction's controls beside its untampered
return: short, misdirected, bound to another request, presenting its reference
with no datum, and spending a state token beside the request. -/
def retractJudged : List (Option String) :=
  let c := settleRetract
  let judge := judgeSurface (judgedScenario c)
  let spent := txInputs (txOfExit s0 .retract c.request 1)
  [ judge spent [c.carrier]
  , judge spent [{ c.carrier with lovelace := c.carrier.lovelace - 1 }]
  , judge spent [{ c.carrier with address := c.carrier.address.map (· + 1) }]
  , judge spent [{ c.carrier with reference := some 32 }]
  , judge spent [{ c.carrier with datum := .none }]
  , judge (spent ++ [stateTokenInput]) [c.carrier] ]

#guard (txInputs (txOfExit s0 .retract settleRetract.request 1)).length == 1
#guard retractJudged ==
  [none, some "deposit-returned", some "deposit-returned", some "deposit-returned",
   some "deposit-returned",
   some "retract-state-spent"]
