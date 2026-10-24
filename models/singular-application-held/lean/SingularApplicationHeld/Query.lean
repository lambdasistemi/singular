import SingularApplicationHeld.Client

/-! The application-held Singular model beside the current one, to be removed
with it in #743. -/

namespace SingularApplicationHeld
open Singular Lean

/-- public judgement branches. -/
inductive Case where
  | recognition | genesis | registration | termination | batch | publicFold
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- explicit finite codec observation. -/
structure CodeEntry where
  preimage : Preimage
  encoded : List Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- explicit finite root interpretation. -/
structure RootEntry where
  trie : Trie
  commitment : Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- named definition inputs, no theorem input. -/
structure Query where
  surface : Case
  codes : List CodeEntry
  hashes : List SingularApplicationHeld.Assets.HashEntry
  roots : List RootEntry
  release : PublishedRelease
  seed : OutRef
  output : ObservedOutput
  transaction : SingularApplicationHeld.Assets.TxView
  outputs : List ObservedOutput
  observation : FoldObservation
  trie : Trie
  action : Change
  requests : List PendingRequest
  funding : FoldFunding
  decoding : List (Nat × ApplicationDatum)
  deriving ToJson, FromJson

/-- public application decoding observations. -/
def queryDecode (q : Query) : DecodeApplication := fun datum =>
  (q.decoding.find? fun entry => entry.1 == datum).map (·.2)

/-- exhaustive generic definition dispatch. -/
def runWith (mutation : Mutation) (hash : Hash) (code : Codec) (commit : TrieCommit)
    (q : Query) : Bool :=
  match q.surface with
  | .recognition => recognizeState mutation hash code q.release q.seed q.output
  | .genesis => genesis mutation hash code commit q.release q.seed q.transaction q.outputs
  | .registration | .termination => (change mutation hash code q.release q.trie q.action q.observation).isOk
  | .batch => fold mutation hash code commit q.release q.observation
  | .publicFold => fold mutation hash code commit q.release
      (buildFold hash code commit q.release q.observation.before q.requests q.funding)

/-- selected change constructor is public. -/
def caseShape (q : Query) : Bool :=
  match q.surface, q.action with
  | .registration, .register .. | .termination, .terminate .. => true
  | .registration, _ | .termination, _ => false | _, _ => true

/-- finite state/active/approval occurrences of the public builder. -/
def publicDomain (q : Query) : List Preimage :=
  [.state q.observation.before.seed] ++ q.requests.flatMap fun request =>
    [.active request.registry request.key] ++ match request with
    | .registration _ data => [.registrationApproval data.registry data.key
        data.holdingAddress data.initialDatum data.deposit]
    | .termination _ registry key => [.terminationApproval registry key]

end SingularApplicationHeld
