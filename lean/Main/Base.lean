import Singular.Driver
import Singular.Economics

/-! Registry fixtures, refused edges, codec and basic observations. -/

open Singular
open Singular.Driver
open Lean

/-- The open application's policy id. It is unparameterised: one policy id, one
blueprint, no applied hash to derive, and therefore no cross-registry
separation to promise. -/
def openPolicyHash : Nat := 7

def cfg : Config :=
  { root := rootOf [], minimumTip := 1, processTime := 2, retractTime := 3
  , applicationPolicy := openPolicyHash, activePolicy := 8 }

def s0 : RegistryState := { config := cfg, trie := [], held := [] }

def apFor (e : Edge) (k o d : Nat) : Option Approval :=
  some { policy := openPolicyHash, edge := e, key := k, owner := o, destination := d
       , assetName := approvalAssetName e k o d }

/-- A canonical booked key: known active, one active token at output 555. -/
def booked (s : RegistryState) (k : Nat) : RegistryState :=
  match step s ({ edge := .insertActive, key := k, owner := 42, output := 555
                , approval := apFor .insertActive k 42 555 } : Request) with
  | .ok r => r.state
  | .error _ => s

/-- A key whose leaf is known absent. -/
def legacyAbsent (s : RegistryState) (k : Nat) : RegistryState :=
  let trie := trieSet s.trie k (.known .absent)
  { s with trie := trie, config := { s.config with root := rootOf trie } }

def req (e : Edge) (k : Nat) (owner : Nat) (out : Nat) : Request :=
  let target : Request := { edge := e, key := k, owner := owner, output := out }
  { edge := e, key := k, owner := owner, output := out
  , approval := apFor e k owner (requestDestination target) }

structure Case where
  id : String
  status : String := "modeled"
  expectedAccept : Bool
  expectedReason : String := ""
  before : RegistryState
  action : Request
  actual : Except String Result

def runCase (id : String) (accept : Bool) (reason : String) (s : RegistryState)
    (r : Request) : Case :=
  { id := id, expectedAccept := accept, expectedReason := reason
  , before := s, action := r, actual := step s r }

def caseActualString (c : Case) : String :=
  match c.actual with
  | .ok _ => s!"accepted(expected={c.expectedAccept})"
  | .error e => s!"refused:{e}(expectedAccept={c.expectedAccept},reason={c.expectedReason})"

def correct (c : Case) : Bool :=
  match c.actual with
  | .ok _ => c.expectedAccept
  | .error e => !c.expectedAccept && e == c.expectedReason

/-- A canonical retired key: known terminal (booked then retired). -/
def retiredState : RegistryState :=
  match step (booked s0 42) (req .updateTerminal 42 42 555) with
  | .ok r => r.state | .error _ => s0

-- Only two success rows. Legacy absent starts below are synthetic, unreachable fixtures.
def accInsertActive : Case :=
  runCase "GA02-insert-active-accepted" true "" s0 (req .insertActive 42 42 555)
def accUpdateTerminal : Case :=
  runCase "GA04-update-terminal-accepted" true "" (booked s0 42)
    (req .updateTerminal 42 42 555)

def refusals : List Case :=
  let starts := [("unknown", s0), ("absent", legacyAbsent s0 42),
                 ("active", booked s0 42), ("terminal", retiredState)]
  let excluded := [Edge.insertAbsent, .updateActive, .deleteAbsent, .deleteActive, .witnessTerminal]
  excluded.flatMap fun e => starts.map fun (label, state) =>
    runCase ("GR-excluded-" ++ edgeName e ++ "-" ++ label) false "edge-inadmissible" state
      (req e 42 42 555)

def readRows : List Case :=
  [ runCase "GD01-register-occupied-refused" false "key-exists" (booked s0 42)
      (req .insertActive 42 42 555)
  , runCase "GD02-terminal-permanent-refused" false "key-exists" retiredState
      (req .insertActive 42 42 555)
  , runCase "GD03-termination-unknown-refused" false "key-unknown" s0
      (req .updateTerminal 42 42 555)
  , runCase "GD04-termination-terminal-refused" false "terminal-immutable" retiredState
      (req .updateTerminal 42 42 555)
  , runCase "GD05-approval-missing-refused" false "no-approval" s0
      { req .insertActive 42 42 555 with approval := none } ]

def custodyRows : List Case :=
  [ runCase "GC05-update-terminal-without-token" false "token-missing"
      { booked s0 42 with held := [] } (req .updateTerminal 42 42 555)
  , runCase "GC06-update-terminal-legacy-absent" false "not-booked"
      (legacyAbsent s0 42) (req .updateTerminal 42 42 555) ]

-- fold-level rows: zero batch, mint mismatch, read inside batch at position
def foldRows : List (String × Bool × String) :=
  [ ("GF01-empty-fold-refused", false, "empty-fold")
  , ("GF02-batch-accepted", true, "")
  , ("GF03-mint-mismatch-refused", false, "net-mint-mismatch") ]
def batchEmpty : Option String :=
  match foldBatch s0 [] with | .error e => some e | .ok _ => none

def batchMint : Option String :=
  match foldBatch s0 [{ req .insertActive 5 42 555 with claimed := [(.active, 2)] }] with
  | .error e => some e | .ok _ => none

def adaRows : List (String × Bool × (List (Nat × Nat))) :=
  [ ("GAda-reject-returns-deposit", true,
      match exitStep s0 .reject { req .insertActive 5 91 555 with deposit := 55 } with
      | .ok r => r.paid | .error _ => [])
  , ("GAda-retract-returns-deposit-and-tip", true,
      match exitStep s0 .retract { req .insertActive 5 91 555 with deposit := 55, tip := 7 } with
      | .ok r => r.paid | .error _ => []) ]

-- codec rows
/-- Each codec row carries the bytes it decodes, so a consumer replays the row
rather than trusting its verdict. -/
def codecInputs : List (String × Bool × List Nat) :=
  [ ("GC01-decode-absent", true, [0])
  , ("GC02-decode-active", true, [1])
  , ("GC03-decode-terminal", true, [2])
  , ("GC04-decode-03-refused", false, [3])
  , ("GC05-decode-empty-refused", false, [])
  , ("GC06-decode-naming-era-refused", false, [104, 101, 108, 108, 111])
  , ("GC07-decode-two-bytes-refused", false, [0, 1]) ]

def codecRows : List (String × Bool × Option State × List Nat) :=
  codecInputs.map fun (id, expected, bytes) =>
    (id, expected, decodeState (bytes.map (fun n => (n.toUInt8))).toByteArray, bytes)

def configRow : Bool :=
  match (fromJson? (toJson cfg) : Except String Config) with
  | .ok c => c == cfg
  | .error _ => false
