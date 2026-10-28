import NoPin.ApplicationRequests.History
import NoPin.Oracle

/-! Hypotheses under #741, not accepted law. Generic, serialized definition
calls. Codec, hash and trie commitments are finite public observations; a
missing table entry is an error, never a default successful observation. -/
namespace NoPin.ApplicationRequests
open Singular Lean

/-- Hypothesis under #741, not accepted law; public judgement branches. -/
inductive Case where
  | recognition | genesis | registration | termination | batch | publicFold
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; explicit finite codec observation. -/
structure CodeEntry where
  preimage : Preimage
  encoded : List Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; explicit finite root interpretation. -/
structure RootEntry where
  trie : Trie
  commitment : Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; named definition inputs, no theorem input. -/
structure Query where
  surface : Case
  codes : List CodeEntry
  hashes : List NoPin.HashEntry
  roots : List RootEntry
  release : PublishedRelease
  seed : OutRef
  output : ObservedOutput
  transaction : NoPin.TxView
  outputs : List ObservedOutput
  observation : FoldObservation
  trie : Trie
  action : Change
  requests : List PendingRequest
  funding : FoldFunding
  decoding : List (Nat × ApplicationDatum)
  deriving ToJson, FromJson
/-- Hypothesis under #741, not accepted law; finite codec interpretation. -/
def queryCode (q : Query) : Codec := fun p =>
  ((q.codes.find? fun e => e.preimage == p).map (·.encoded)).getD []
/-- Hypothesis under #741, not accepted law; finite root interpretation. -/
def queryCommit (q : Query) : TrieCommit := fun trie =>
  ((q.roots.find? fun e => e.trie == trie).map (·.commitment)).getD 0
/-- Hypothesis under #741, not accepted law; public application decoding observations. -/
def queryDecode (q : Query) : DecodeApplication := fun datum =>
  (q.decoding.find? fun entry => entry.1 == datum).map (·.2)
/-- Hypothesis under #741, not accepted law; exhaustive generic definition dispatch. -/
def runWith (mutation : Mutation) (hash : Hash) (code : Codec) (commit : TrieCommit)
    (q : Query) : Bool :=
  match q.surface with
  | .recognition => recognizeState mutation hash code q.release q.seed q.output
  | .genesis => genesis mutation hash code commit q.release q.seed q.transaction q.outputs
  | .registration | .termination => (change mutation hash code q.release q.trie q.action q.observation).isOk
  | .batch => fold mutation hash code commit q.release q.observation
  | .publicFold => fold mutation hash code commit q.release
      (buildFold hash code commit q.release q.observation.before q.requests q.funding)
/-- Hypothesis under #741, not accepted law; selected change constructor is public. -/
def caseShape (q : Query) : Bool :=
  match q.surface, q.action with
  | .registration, .register .. | .termination, .terminate .. => true
  | .registration, _ | .termination, _ => false | _, _ => true
/-- Hypothesis under #741, not accepted law; finite state/active/approval occurrences of the public builder. -/
def publicDomain (q : Query) : List Preimage :=
  [.state q.observation.before.seed] ++ q.requests.flatMap fun request =>
    [.active request.registry request.key] ++ match request with
    | .registration _ data => [.registrationApproval data.registry data.key
        data.holdingAddress data.initialDatum data.deposit]
    | .termination _ registry key => [.terminationApproval registry key]
/-- Hypothesis under #741, not accepted law; oracle reports missing observations. -/
def wellFormed (q : Query) : Bool :=
  let o := q.observation
  let preimages := [.state q.seed, .state o.before.seed] ++
    o.changes.flatMap (changePreimages o) ++ changePreimages o q.action ++ publicDomain q
  decide (q.codes.map (·.preimage)).Nodup &&
  decide (q.hashes.map (·.input)).Nodup && decide (q.roots.map (·.trie)).Nodup &&
  preimages.all (fun p => q.codes.any fun e => e.preimage == p) &&
  q.codes.all (fun e => q.hashes.any fun h => h.input == e.encoded) &&
  [[], o.before.trie, o.after.trie].all (fun trie => q.roots.any fun e => e.trie == trie) &&
  (if q.surface == .publicFold then
    q.roots.any fun entry => entry.trie == (buildFold (NoPin.lookupHash q.hashes)
      (queryCode q) (queryCommit q) q.release o.before q.requests q.funding).after.trie
    else true) && caseShape q
/-- Hypothesis under #741, not accepted law; one surface and one selector. -/
structure Scenario where
  query : Query
  mutation : Mutation
  deriving ToJson, FromJson
/-- Hypothesis under #741, not accepted law; supplied finite table execution. -/
def runQuery (mutation : Mutation) (q : Query) : Except String Bool :=
  if wellFormed q then .ok (runWith mutation (NoPin.lookupHash q.hashes) (queryCode q) (queryCommit q) q)
  else .error "incomplete-or-wrong-surface-observation"

end NoPin.ApplicationRequests
