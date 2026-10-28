import SingularApplicationHeld.HistoryClaims

/-! The reader classifies observations. It does not perform a transaction.
An empty complete asset answer and a missing answer are different evidence.
The trie library's proofs are assumed sound. -/
namespace SingularApplicationHeld
open Singular Lean

/-- A complete answer is distinguished from every unavailable observation. -/
inductive ReaderRead (α : Type) where
  | missing
  | failed (reason : String)
  | incomplete (reason : String)
  | complete (value : α)
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

inductive ReaderReadName where
  | network | activeOutputs | state | trie
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

inductive ReaderUnavailable where
  | missing | failed (reason : String) | incomplete (reason : String)
  | stateNotFound | stateNotRecognized | trieRootMismatch
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- The read's exact unavailable reason, without manufacturing an answer. -/
def ReaderRead.unavailableReason : ReaderRead α → Option ReaderUnavailable
  | .missing => some .missing
  | .failed reason => some (.failed reason)
  | .incomplete reason => some (.incomplete reason)
  | .complete _ => none

inductive ReaderRefusal where
  | wrongNetwork (requested served : Nat)
  | unknownStatePolicy (policy : Nat)
  | foreignStatePolicy (requested published : Nat)
  | tokenOutsideApplicationCustody (reference : OutRef) (credential : Nat)
  | conflictingEvidence
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- Trie content belongs to the supplied state root, not to an unrelated leaf. -/
structure ReaderState where
  output : ObservedOutput
  trie : Trie
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

structure ReaderRequest where
  network : Nat
  registry : TokenId
  key : Key
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- Complete asset answers concern exactly activeAsset h c request.registry request.key.
State evidence is needed only after a complete empty asset answer. -/
structure ReaderObservation where
  network : ReaderRead Nat
  release : Option PublishedRelease
  activeOutputs : ReaderRead (List ObservedOutput)
  state : ReaderRead (Option ObservedOutput)
  trie : ReaderRead Trie
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

inductive ReaderAnswer where
  | live (output : ObservedOutput)
  | pendingTermination (output : ObservedOutput)
  | terminal (state : ReaderState)
  | neverRegistered (state : ReaderState)
  | unavailable (read : ReaderReadName) (reason : ReaderUnavailable)
  | refused (reason : ReaderRefusal)
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

def ReaderAnswer.isAbsence : ReaderAnswer → Bool
  | .terminal _ | .neverRegistered _ => true
  | _ => false

/-- State recognition from the already known complete registry asset identity.
It requires the same credential, single asset, unit quantity and root datum
as recognizeState. No inversion of the state token name to a seed is needed. -/
def recognizeReaderState (release : PublishedRelease) (registry : TokenId)
    (output : ObservedOutput) : Bool :=
  output.credential == release.statePolicy && registry.policy == release.statePolicy &&
  output.assets == [(registry, 1)] &&
  (match output.datum with | .root _ => true | _ => false)

/-- One authoritative decision over the evidence. The lookup is trieGet on
the content authenticated by the recognised state's root. -/
def readKey (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (request : ReaderRequest) (observed : ReaderObservation) : ReaderAnswer := Id.run do
  match observed.network with
    | .missing => return .unavailable .network .missing
    | .failed why => return .unavailable .network (.failed why)
    | .incomplete why => return .unavailable .network (.incomplete why)
    | .complete served =>
      if served != request.network then
        return .refused (.wrongNetwork request.network served)
      let some release := observed.release
        | return .refused (.unknownStatePolicy request.registry.policy)
      if request.registry.policy != release.statePolicy then
        return .refused (.foreignStatePolicy request.registry.policy release.statePolicy)
      match observed.activeOutputs with
        | .missing => return .unavailable .activeOutputs .missing
        | .failed why => return .unavailable .activeOutputs (.failed why)
        | .incomplete why => return .unavailable .activeOutputs (.incomplete why)
        | .complete outputs =>
          match outputs with
          | [output] =>
            if quantity output (activeAsset h c request.registry request.key) != 1 then
              return .refused .conflictingEvidence
            if output.credential != release.applicationCredential || output.credential == request.registry.policy then
              return .refused (.tokenOutsideApplicationCustody output.reference output.credential)
            if terminationShape .none h c release output request.registry request.key then
              return .pendingTermination output
            match decoded decode output with
            | some (.live control _) =>
              if control.registry == request.registry && control.key == request.key &&
                  control.activeAsset == activeAsset h c request.registry request.key &&
                  control.deposit ≤ output.lovelace then
                return .live output
              return .refused .conflictingEvidence
            | _ => return .refused .conflictingEvidence
          | [] =>
            match observed.state with
            | .missing => return .unavailable .state .missing
            | .failed why => return .unavailable .state (.failed why)
            | .incomplete why => return .unavailable .state (.incomplete why)
            | .complete none => return .unavailable .state .stateNotFound
            | .complete (some output) =>
              if !recognizeReaderState release request.registry output then
                return .unavailable .state .stateNotRecognized
              match observed.trie with
              | .missing => return .unavailable .trie .missing
              | .failed why => return .unavailable .trie (.failed why)
              | .incomplete why => return .unavailable .trie (.incomplete why)
              | .complete trie =>
                if output.datum != .root (t trie) then
                  return .unavailable .trie .trieRootMismatch
                let state : ReaderState := ⟨output, trie⟩
                match trieGet trie request.key with
                | .unknown => return .neverRegistered state
                | .known .terminal => return .terminal state
                | _ => return .refused .conflictingEvidence
          | _ => return .refused .conflictingEvidence

/-- Provider observation correspondence, separate from the executable reader.
Successful answers are complete observations of the same reachable world.
No conclusion, leaf status or application-custody fact is assumed. -/
def ReaderEvidenceCorrespondence (h : Hash) (c : Codec) (world : CandidateWorld)
    (registry : PublicRegistry) (key : Key) (observed : ReaderObservation) : Prop :=
  (∀ outputs, observed.activeOutputs = .complete outputs →
    outputs = world.unspent.filter (fun output => quantity output (activeAsset h c registry.identity key) > 0)) ∧
  (∀ output, observed.state = .complete (some output) → output = registry.state) ∧
  (∀ trie, observed.trie = .complete trie → trie = registry.trie)

end SingularApplicationHeld
