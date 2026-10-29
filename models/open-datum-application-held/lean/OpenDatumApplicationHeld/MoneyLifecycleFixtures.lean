import OpenDatumApplicationHeld.RefundLifecycle
import OpenDatumApplicationHeld.MoneyFixtureQueries


namespace OpenDatumApplicationHeld.RefundLifecycle.Fixtures
open Singular Lean SingularApplicationHeld OpenDatumApplicationHeld.Fixtures


def observation (inputs outputs : List ObservedOutput) (mint : List (TokenId × Int))
    (actions : List ApplicationAction) (signers : List Nat := [])
    (interval : Interval := ⟨5, 6⟩) (donation : Nat := 0) : ApplicationObservation :=
  ⟨⟨inputs.map (·.reference), outputs.map (fun output => ⟨output.assets⟩), mint,
    [release.applicationPolicy, release.statePolicy]⟩, inputs, outputs, [], [], signers, interval, 0, donation, actions⟩

def configuration : ObservedOutput :=
  ⟨⟨16, 0⟩, release.applicationCredential, 2, .configuration ⟨0, 0, 19, 10, 1⟩,
    [(configurationAsset hash code release registryId, 1)], none⟩

def live : ObservedOutput :=
  ⟨⟨17, 0⟩, release.applicationCredential, 17, .application 1008,
    [(activeAsset hash code registryId 8, 1)], none⟩

def refund (value : Nat) : ObservedOutput := ⟨⟨18, 0⟩, registrationData.refundAddress, value, .empty, [], none⟩

def examples : List (String × ApplicationObservation) :=
  [("configurationCreate", { observation [] [configuration]
      [(configurationAsset hash code release registryId, 1), (registryId, 1)]
      [.configurationCreate registryId seed 0] with assets := { (observation [] [] [] []).assets with spent := [seed], mint := [(configurationAsset hash code release registryId, 1), (registryId, 1)] } }),
   ("bookRegistration", { observation [] [registration.output]
      [(registrationAsset hash code release registrationData, 1)] [.bookRegistration 0] [42] ⟨0, 1⟩ with
      referenceInputs := [configuration.reference], referenceOutputs := [configuration] }),
   ("bookTermination", observation [live] [termination.output]
      [(terminationApproval hash code release registryId 8, 1)]
      [.bookTermination live.reference 0] [42] ⟨5, 6⟩ (control 8).deposit),
   ("registrationFold", applicationFoldView
      (buildFold hash code commit release OpenDatumApplicationHeld.Fixtures.registry [registration] funding) [registration]),
   ("ownerReclaim", observation [registration.output] [refund registration.output.lovelace]
      [(registrationAsset hash code release registrationData, -1)]
      [.ownerReclaim registration.output.reference] [registrationData.refundAddress] ⟨20, 21⟩),
   ("expiredCleanup", observation [registration.output] [refund registrationData.deposit]
      [(registrationAsset hash code release registrationData, -1)]
      [.expiredCleanup registration.output.reference] [] ⟨30, 31⟩),
   ("terminationFold", applicationFoldView
      (buildFold hash code commit release OpenDatumApplicationHeld.Fixtures.registry [termination] funding) [termination]),
   ("liveUpdate", observation [live] [{live with reference := ⟨18, 0⟩, datum := .application 1009}]
      [] [.liveUpdate live.reference 0] [42]),
   ("approvalBurn", observation
      [⟨⟨19, 0⟩, 60, 2, .empty, [(terminationApproval hash code release registryId 8, 1)], none⟩]
      [⟨⟨20, 0⟩, 60, 2, .empty, [], none⟩]
      [(terminationApproval hash code release registryId 8, -1)] [.approvalBurn])]

def exampleFor (name : String) : ApplicationObservation :=
  ((examples.find? fun entry => entry.1 == name).map (·.2)).getD mixedApplication

def publicQuery : Query :=
  let preimages := ([Preimage.state seed, .applicationConfiguration registryId] ++
    mixed.changes.flatMap (changePreimages mixed)).eraseDups
  let codes := preimages.map fun p => CodeEntry.mk p (code p)
  { (FixtureQueries.goodQuery .publicFold) with
      codes := codes
      hashes := (codes.map fun e => ⟨e.encoded, hash e.encoded⟩)
      decoding := [(2007, .registration registrationData), (1007, .live (control 7) 123),
        (1008, .live (control 8) 124), (1009, .live (control 8) 125)] }

def inputFor (name : String) : Input :=
  let o := exampleFor name
  ⟨publicQuery, o, o.actions.head?.getD .approvalBurn⟩

def terminationInput : Input :=
  let built := buildFold hash code commit release OpenDatumApplicationHeld.Fixtures.registry [termination] funding
  { (inputFor "terminationFold") with
    query := {publicQuery with
      requests := [termination]
      roots := [[], OpenDatumApplicationHeld.Fixtures.registry.trie, mixed.after.trie, built.after.trie].eraseDups.map fun trie => ⟨trie, commit trie⟩} }

end OpenDatumApplicationHeld.RefundLifecycle.Fixtures
