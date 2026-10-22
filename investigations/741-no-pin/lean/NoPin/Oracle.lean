import NoPin.Identity

/-! Hypothetical #741 oracle, not accepted law. The named public definitions
are selected by Case; this interface contains no theorem-specific projections. -/

namespace NoPin
open Singular Lean

/-- Hypothesis under #741, not accepted law; explicit finite hash interpretation. -/
structure HashEntry where
  input : List Nat
  output : Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; named identity/role/seed observation surface. -/
structure Query where
  surface : Case
  hashes : List HashEntry
  application : Nat
  registry : TokenId
  payload : Payload
  key : Nat
  supplied : TokenId
  observation : Observation
  seed : OutRef
  transaction : TxView
  history : List TxView
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; explicit lookup hash, no cryptographic claim. -/
def lookupHash (entries : List HashEntry) (input : List Nat) : Nat :=
  ((entries.find? (fun entry => entry.input == input)).map (·.output)).getD 0
/-- Hypothesis under #741, not accepted law; exhaustive oracle boundary by public Case.
none is the production candidate; mutation selectors are used only by the mutant ledger. -/
def runQuery (m : Mutation) (q : Query) : Bool :=
  let hash := lookupHash q.hashes
  match q.surface with
  | .approvalFull => approve m .full hash encode q.application q.registry q.payload q.supplied
  | .approvalNameOnly => approve m .nameOnly hash encode q.application q.registry q.payload q.supplied
  | .policyOnly => recognize m .policyOnly hash encode q.registry .state q.key q.observation
  | .state => recognize m .authenticated hash encode q.registry .state q.key q.observation
  | .witness => recognize m .authenticated hash encode q.registry .witness q.key q.observation
  | .trieReady => recognize m .authenticated hash encode q.registry .trieReady q.key q.observation
  | .application => recognize m .authenticated hash encode q.registry .application q.key q.observation
  | .genesis => genesis m q.transaction q.seed q.registry
  | .history => historyAllows m q.history

/-- Hypothesis under #741, not accepted law; generic oracle scenario for witness/mutant replay. -/
structure Scenario where
  query : Query
  mutation : Mutation
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

end NoPin
