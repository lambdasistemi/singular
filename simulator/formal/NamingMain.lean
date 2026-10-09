import Singular.Model
import Singular.Naming
import Singular.NamingLifecycle
open Singular
open Lean

/-! The naming corpus over the registry-mode model: registration (record-binds-active-registration), the
two supported registry edges, retirement per naming-approval-rules as amended
(retirement-removes-active-witness/naming-approval-rules), the refused reads and re-registration (terminal-key-cannot-change), and the observations. -/

def ns0 : NamingState := namingInitial

def jRegistered : NamingState :=
  match namingRegister ns0 aliceKey 5 aliceFixture with
  | .ok s => s | .error _ => ns0

def completeFirstRetirement (state : NamingState) : NamingState :=
  match state.pendingRetirements.head? with
  | none => state
  | some pending =>
      match namingCompleteRetirement state (completionFor pending) with
      | .ok completed => completed
      | .error _ => state

def jRetired : NamingState :=
  match namingRetire jRegistered aliceKey [quorumKeyHash 1, quorumKeyHash 29] none with
  | .ok pending => completeFirstRetirement pending
  | .error _ => jRegistered

def jRetiredByRecoveryKey : NamingState :=
  match namingRetire jRegistered aliceKey [] (some nextControllerAddress) with
  | .ok pending => completeFirstRetirement pending
  | .error _ => jRegistered

/-- An observation row: naming's authenticated view of a key. -/
def obs (id : String) (state : NamingState) (key : Nat) : Json :=
  let leaf := trieGet state.registry.trie key
  let active := kindCount state.registry .active key
  let custody := custodyCount state.registry key
  let terminal := kindCount state.registry .terminal key
  Json.mkObj [ ("id", toJson id), ("leaf", toJson leaf), ("active", toJson active)
             , ("absent", toJson custody), ("terminal", toJson terminal) ]

def spellings : List Json :=
  [ Json.mkObj [ ("id", toJson "NS01-alice-known"), ("spelling", toJson "alice")
               , ("key", toJson ((spellingKey "alice").getD 0))
               , ("resolved", toJson (spellingKey "alice" != none)) ]
  , Json.mkObj [ ("id", toJson "NS02-unknown-spelling"), ("spelling", toJson "bob")
               , ("resolved", toJson (spellingKey "bob" != none)) ] ]

def queues : List Json :=
  [ Json.mkObj [ ("id", toJson "NQ02-register-accepts"), ("expected", toJson true)
               , ("actual", toJson (namingRegister ns0 aliceKey 5 aliceFixture).isOk) ]
  , Json.mkObj [ ("id", toJson "NQ03-register-occupied-refused"), ("expected", toJson false)
               , ("actual", toJson (namingRegister jRegistered aliceKey 6 otherFixture).isOk) ] ]

def folds : List Json :=
  [ Json.mkObj [ ("id", toJson "NF01-registration-holds-active-token"), ("expected", toJson true)
               , ("actual", kindCount jRegistered.registry .active aliceKey == 1
                  && trieGet jRegistered.registry.trie aliceKey == .known .active) ]
  , Json.mkObj [ ("id", toJson "NF05-retirement-by-quorum"), ("expected", toJson true)
               , ("actual", toJson (trieGet jRetired.registry.trie aliceKey == .known .terminal
                  && jRetired.records.isEmpty)) ]
  , Json.mkObj [ ("id", toJson "NF06-retirement-by-recovery-key"), ("expected", toJson true)
               , ("actual", toJson (trieGet jRetiredByRecoveryKey.registry.trie aliceKey == .known .terminal)) ]
 ]

def steps : List Json :=
  [ Json.mkObj [ ("id", toJson "NS03-delete-active-never-certified"), ("expected", toJson false)
               , ("actual", namingCertifies fixtureHasher .deleteActive
                    [controllerAddress.bytes] none
                    { controllerBytes := controllerAddress.bytes
                    , refundBytes := controllerAddress.bytes
                    , fixture := aliceFixture }) ]
  , Json.mkObj [ ("id", toJson "NS04-control-key-alone-never-retires"), ("expected", toJson false)
               , ("actual", namingCertifies fixtureHasher .updateTerminal
                    [controllerAddress.bytes] none
                    { controllerBytes := controllerAddress.bytes
                    , refundBytes := controllerAddress.bytes
                    , fixture := aliceFixture }) ]
  , Json.mkObj [ ("id", toJson "NS05-quorum-retires"), ("expected", toJson true)
               , ("actual", quorumMet aliceFixture.retirementQuorum
                    [quorumKeyHash 1, quorumKeyHash 29]) ]
  , Json.mkObj [ ("id", toJson "NS06-recovery-key-retires"), ("expected", toJson true)
               , ("actual", revealsCommittedRecoveryKey fixtureHasher
                    { aliceFixture with nextControlCommitment := nextControllerCommitment }
                    (some nextControllerAddress)) ] ]

def resolves : List Json :=
  [ obs "NRP01-resolve-absent" ns0 aliceKey
  , obs "NRP03-resolve-active" jRegistered aliceKey
  , obs "NRP04-resolve-terminal" jRetired aliceKey
 ]

def replays : List Json :=
  [ Json.mkObj [ ("id", toJson "NRP10-rebooking-after-terminal-refused"), ("expected", toJson false)
               , ("actual", toJson (namingRegister jRetired aliceKey 6 otherFixture).isOk) ]
 ]

def allOk : Bool :=
  (queues ++ steps ++ replays ++ folds).all fun row =>
    match row.getObjVal? "expected", row.getObjVal? "actual" with
    | .ok e, .ok a => e == a
    | _, _ => false

def main : IO Unit := do
  let stdout ← IO.getStdout
  for grp in [queues, steps, replays, folds] do
    for row in grp do
      match row.getObjVal? "expected", row.getObjVal? "actual" with
      | .ok e, .ok a =>
        unless e == a do throw (IO.userError s!"naming row failed: {row.compress}")
      | _, _ => pure ()
  let json := Json.mkObj
    [ ("schema", toJson "singular-naming-corpus-v2")
    , ("spellings", toJson spellings)
    , ("queues", toJson queues)
    , ("folds", toJson folds)
    , ("steps", toJson steps)
    , ("resolves", toJson resolves)
    , ("replays", toJson replays) ]
  stdout.putStrLn json.compress
