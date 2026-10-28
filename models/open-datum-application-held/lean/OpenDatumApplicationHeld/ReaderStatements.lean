import OpenDatumApplicationHeld.Application
import SingularApplicationHeld.ReaderStatements

/-! The shared reader's custody answers under open datum's own predicates. -/
namespace OpenDatumApplicationHeld.ReaderStatements
open Singular SingularApplicationHeld

/-- The live answer implies open datum's exact liveShape at this registry and key. -/
theorem live_custody (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (world : CandidateWorld) (registry : PublicRegistry)
    (network : Nat) (key : Key) (observed : ReaderObservation) (output : ObservedOutput)
    (_history : HistoryPremises h c t release world registry key)
    (_evidence : ReaderEvidenceCorrespondence h c world registry key observed)
    (_release : observed.release = some release)
    (_answer : readKey h c t decode ⟨network, registry.identity, key⟩ observed = .live output) :
    trieGet registry.trie key = .known .active ∧ output ∈ world.unspent ∧
    ∃ control payload, decoded decode output = some (.live control payload) ∧
      control.registry = registry.identity ∧ control.key = key ∧
      liveShape .none h c release output control = true := by sorry

/-- A pending answer implies the exact termination request shape, not token absence. -/
theorem pending_custody (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (world : CandidateWorld) (registry : PublicRegistry)
    (network : Nat) (key : Key) (observed : ReaderObservation) (output : ObservedOutput)
    (_history : HistoryPremises h c t release world registry key)
    (_evidence : ReaderEvidenceCorrespondence h c world registry key observed)
    (_release : observed.release = some release)
    (_answer : readKey h c t decode ⟨network, registry.identity, key⟩ observed = .pendingTermination output) :
    trieGet registry.trie key = .known .active ∧ output ∈ world.unspent ∧
    output.credential = release.applicationCredential ∧ output.datum = .empty ∧
    exactAssets output [(activeAsset h c registry.identity key, 1),
      (terminationApproval h c release registry.identity key, 1)] = true := by sorry

end OpenDatumApplicationHeld.ReaderStatements
