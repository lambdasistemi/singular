import OpenDatumApplicationHeld.RefundLifecycleClaims


namespace OpenDatumApplicationHeld
open Singular Lean SingularApplicationHeld SingularApplicationHeld
def changePreimages (observation : FoldObservation) (action : Change) : List Preimage :=
  [.active observation.before.identity action.key] ++ match action with
  | .terminate _ key => [.terminationApproval observation.before.identity key]
  | .register _ key index deposit => match observation.outputs[index]? with
    | some output => match output.datum with
      | .application datum => [.registrationApproval observation.before.identity key output.address datum deposit]
      | _ => []
    | _ => []

end OpenDatumApplicationHeld

namespace OpenDatumApplicationHeld.Fixtures
open Singular Lean SingularApplicationHeld


def code : Codec
  | .state seed => [0, seed.tx, seed.index]
  | .active registry key => [1, registry.policy, registry.name, key]
  | .applicationConfiguration registry => [2, registry.policy, registry.name]
  | .registrationApproval registry key address datum deposit =>
      [3, registry.policy, registry.name, key, address.paymentCredential] ++
        (match address.stakingCredential with | none => [0] | some stake => [1, stake]) ++
        [datum, deposit]
  | .terminationApproval registry key => [4, registry.policy, registry.name, key]

def hash : Hash := fun xs => xs.foldl (fun accumulator value => accumulator * 4099 + value + 1) 1

def release : PublishedRelease := ⟨5, 99, 70, 10⟩

def seed : OutRef := ⟨11, 2⟩

def registryId : TokenId := stateAsset hash code release seed

def commit : TrieCommit := fun trie => trie.foldl (fun accumulator entry =>
  accumulator * 17 + entry.1 + match entry.2 with
    | .unknown => 0 | .known .active => 1 | .known .terminal => 2 | .known .absent => 3) 0

def control (key : Key) : ProtectedControl := ⟨registryId, activeAsset hash code registryId key, key, 42, 7⟩

def registrationData : RegistrationData := ⟨registryId, 7, 42, 50, ⟨99, none⟩, 1007, 7, 1, 20, 30⟩

def decode : DecodeApplication
  | 1007 => some (.live (control 7) 123)
  | 1008 => some (.live (control 8) 124)
  | 1009 => some (.live (control 8) 125)
  | 2007 => some (.registration registrationData)
  | _ => none

def registration : PendingRequest := .registration
  ⟨⟨12, 0⟩, release.applicationCredential, 23, .application 2007,
    [(registrationAsset hash code release registrationData, 1)], none⟩ registrationData

def termination : PendingRequest := .termination
  ⟨⟨13, 0⟩, release.applicationCredential, 10, .empty,
    [(activeAsset hash code registryId 8, 1), (terminationApproval hash code release registryId 8, 1)], none⟩ registryId 8

def registry : PublicRegistry :=
  let trie := trieSet [] 8 (.known .active)
  ⟨registryId, seed, ⟨⟨11, 0⟩, release.statePolicy, 2, .root (commit trie), [(registryId, 1)], none⟩, trie⟩

def funding : FoldFunding := ⟨⟨⟨14, 0⟩, 60, 1, .empty, [], none⟩, 77, 15, ⟨5, 6⟩, 1⟩

def mixed : FoldObservation := buildFold hash code commit release registry [registration, termination] funding

def mixedApplication : ApplicationObservation := applicationFoldView mixed [registration, termination]

def genesisView : SingularApplicationHeld.Assets.TxView :=
  let state := { registry.state with datum := .root (commit []) }
  ⟨[seed], [⟨state.assets⟩], [(registryId, 1)], [release.statePolicy]⟩

end OpenDatumApplicationHeld.Fixtures
