import NoPin.ApplicationRequests.History

/-! Hypotheses under #741, not accepted law. Concrete parameters here instantiate
only finite examples. No stand-in is offered as the cryptographic chain hash. -/
namespace NoPin.ApplicationRequests.Fixtures
open Singular

/-- Hypothesis fixture under #741, not accepted law; structured role encoding. -/
def code : Codec
  | .state seed => [0, seed.tx, seed.index]
  | .active registry key => [1, registry.policy, registry.name, key]
  | .applicationConfiguration registry => [2, registry.policy, registry.name]
  | .registrationApproval registry key address datum deposit =>
      [3, registry.policy, registry.name, key, address, datum, deposit]
  | .terminationApproval registry key => [4, registry.policy, registry.name, key]
/-- Hypothesis fixture under #741, not accepted law; a finite illustrative hash parameter. -/
def hash : Hash := fun xs => xs.foldl (fun accumulator value => accumulator * 4099 + value + 1) 1
/-- Hypothesis fixture under #741, not accepted law; independent application identities. -/
def release : PublishedRelease := ⟨5, 99, 70, 10⟩
/-- Hypothesis fixture under #741, not accepted law; observed public genesis seed. -/
def seed : OutRef := ⟨11, 2⟩
/-- Hypothesis fixture under #741, not accepted law; derived complete registry identity. -/
def registryId : TokenId := stateAsset hash code release seed
/-- Hypothesis fixture under #741, not accepted law; a finite commitment parameter, not a trie proof. -/
def commit : TrieCommit := fun trie => trie.foldl (fun accumulator entry =>
  accumulator * 17 + entry.1 + match entry.2 with
    | .unknown => 0 | .known .active => 1 | .known .terminal => 2 | .known .absent => 3) 0
/-- Hypothesis fixture under #741, not accepted law; protected initial control. -/
def control (key : Key) : ProtectedControl := ⟨registryId, activeAsset hash code registryId key, key, 42, 7⟩
/-- Hypothesis fixture under #741, not accepted law; finite public application datum decoding. -/
def registrationData : RegistrationData := ⟨registryId, 7, 42, 50, 99, 1007, 7, 1, 20, 30⟩
/-- Hypothesis fixture under #741, not accepted law; categories interpreted from actual datum ids. -/
def decode : DecodeApplication
  | 1007 => some (.live (control 7) 123)
  | 1008 => some (.live (control 8) 124)
  | 1009 => some (.live (control 8) 125)
  | 2007 => some (.registration registrationData)
  | _ => none
/-- Hypothesis fixture under #741, not accepted law; request quantities derived from its producer. -/
def registration : PendingRequest := .registration
  ⟨⟨12, 0⟩, release.applicationCredential, 23, .application 2007,
    [(registrationAsset hash code release registrationData, 1)]⟩ registrationData
/-- Hypothesis fixture under #741, not accepted law; two-token empty-datum request. -/
def termination : PendingRequest := .termination
  ⟨⟨13, 0⟩, release.applicationCredential, 10, .empty,
    [(activeAsset hash code registryId 8, 1), (terminationApproval hash code release registryId 8, 1)]⟩ registryId 8
/-- Hypothesis fixture under #741, not accepted law; root-only actual state output. -/
def registry : PublicRegistry :=
  let trie := trieSet [] 8 (.known .active)
  ⟨registryId, seed, ⟨⟨11, 0⟩, release.statePolicy, 2, .root (commit trie), [(registryId, 1)]⟩, trie⟩
/-- Hypothesis fixture under #741, not accepted law; public ordinary fee funding. -/
def funding : FoldFunding := ⟨⟨⟨14, 0⟩, 60, 1, .empty, []⟩, 77, 15, ⟨5, 6⟩, 1⟩
/-- Hypothesis fixture under #741, not accepted law; mixed batch at cardinality two. -/
def mixed : FoldObservation := buildFold hash code commit release registry [registration, termination] funding
/-- Hypothesis fixture under #741, not accepted law; independent application view of that transaction. -/
def mixedApplication : ApplicationObservation := applicationFoldView mixed [registration, termination]
/-- Hypothesis fixture under #741, not accepted law; genesis actual transaction from its seed. -/
def genesisView : NoPin.TxView :=
  let state := { registry.state with datum := .root (commit []) }
  ⟨[seed], [⟨state.assets⟩], [(registryId, 1)], [release.statePolicy]⟩
/-- Hypothesis fixture under #741, not accepted law; successful kernel-evaluated mixed fold. -/
theorem mixed_singular : fold .none hash code commit release mixed = true := by decide
/-- Hypothesis fixture under #741, not accepted law; independent application success. -/
theorem mixed_application : applicationStep .none hash code decode release mixedApplication = true := by decide
/-- Hypothesis fixture under #741, not accepted law; actual conservation of value, no typed payouts. -/
theorem mixed_balance : observedBalance mixed.spentOutputs mixed.outputs mixed.fee mixed.donation = true := by decide
/-- Hypothesis fixture under #741, not accepted law; whole ADA bid net fee separately funded. -/
theorem mixed_processor : paidTo mixed.outputs funding.processorAddress =
    ([registration, termination].map PendingRequest.bid).sum := by decide
/-- Hypothesis fixture under #741, not accepted law; exact deposit from the producer's output. -/
theorem mixed_holding : (mixed.outputs[1]?).map (·.lovelace) = some registrationData.deposit := by decide

end NoPin.ApplicationRequests.Fixtures
