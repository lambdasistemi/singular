import OpenDatumApplicationHeld.Application
import SingularApplicationHeld.ReaderStatements

/-! The shared reader's custody answers under open datum's own predicates. -/
namespace OpenDatumApplicationHeld.ReaderStatements
open Singular SingularApplicationHeld

private theorem app_guard_none (site : AppGuard) (condition : Bool) :
    appGuard .none site condition = condition := by rfl

private theorem empty_of_beq (datum : OutputDatum) (same : (datum == .empty) = true) :
    datum = .empty := by
  cases datum <;> simp_all [reduceBEq]

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
      liveShape .none h c release output control = true := by
  obtain ⟨active, member, custody, one, control, payload, decoding,
    registryBinding, keyBinding, assetBinding, deposit⟩ :=
      SingularApplicationHeld.ReaderStatements.live_sound h c t decode release world registry network key observed output
        _history _evidence _release _answer
  refine ⟨active, member, control, payload, decoding, registryBinding, keyBinding, ?_⟩
  simp [liveShape, app_guard_none, custody, one, registryBinding, keyBinding, assetBinding, deposit]

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
      (terminationApproval h c release registry.identity key, 1)] = true := by
  obtain ⟨active, member, shape⟩ :=
    SingularApplicationHeld.ReaderStatements.pending_termination_sound h c t decode release world registry network key observed output
      _history _evidence _release _answer
  simp only [terminationShape, app_guard_none, Bool.and_eq_true] at shape
  exact ⟨active, member, by simpa using shape.1.1, empty_of_beq output.datum shape.1.2, shape.2⟩

end OpenDatumApplicationHeld.ReaderStatements
