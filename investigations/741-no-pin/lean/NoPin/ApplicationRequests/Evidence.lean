import NoPin.ApplicationRequests.Statements
import NoPin.ApplicationRequests.Fixtures

/-! Hypothetical #741 finite witnesses, not accepted law. Every general
antecedent is instantiated completely; only kernel decide proves examples. -/
set_option maxRecDepth 16384
set_option maxHeartbeats 4000000
namespace NoPin.ApplicationRequests.Evidence
open Singular Lean Fixtures

/-- Hypothesis fixture under #741, not accepted law; public preimage support. -/
def codes : List CodeEntry :=
  ([Preimage.state seed] ++ mixed.changes.flatMap (changePreimages mixed)).map fun p => ⟨p, code p⟩
/-- Hypothesis fixture under #741, not accepted law; values computed by the producer. -/
def hashes : List NoPin.HashEntry := codes.map fun e => ⟨e.encoded, hash e.encoded⟩
/-- Hypothesis fixture under #741, not accepted law; actual root interpretation samples. -/
def roots : List RootEntry := [[], mixed.before.trie, mixed.after.trie].map fun trie => ⟨trie, commit trie⟩
/-- Hypothesis fixture under #741, not accepted law; every input is public and serialized. -/
def goodQuery (surface : Case) : Query :=
  { surface, codes, hashes, roots, release, seed,
    output := Fixtures.registry.state, transaction := genesisView,
    outputs := [{ Fixtures.registry.state with datum := .root (commit []) }],
    observation := mixed, trie := Fixtures.registry.trie,
    action := if surface == .termination then mixed.changes[1] else mixed.changes[0],
    requests := [registration, termination], funding,
    decoding := [(2007, .registration registrationData), (1007, .live (control 7) 123)] }

/-- Hypothesis instance under #741, not accepted law; full theorem antecedent. -/
abbrev recognition_inversion_premise (_m : Mutation) (_h : Hash) (_c : Codec) (_t : TrieCommit) (q : Query) : Prop :=
  q.surface = .recognition ∧ caseShape q = true
/-- Hypothesis instance under #741, not accepted law; exact general conclusion. -/
abbrev recognition_inversion_claim (m : Mutation) (h : Hash) (c : Codec) (t : TrieCommit) (q : Query) : Prop :=
  runWith m h c t q = true ↔ expectedWith h c t q = true
/-- Executed full antecedent of the #741 hypothesis, not accepted law. -/
theorem recognition_antecedent : recognition_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .recognition)) (queryCommit (goodQuery .recognition))
    (goodQuery .recognition) := by decide
/-- Executed public case of the #741 hypothesis, not accepted law. -/
theorem recognition_accepted : (runQuery .none (goodQuery .recognition)).toOption = some true := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem recognition_stateCredential_candidate : recognition_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .recognition)) (queryCommit (goodQuery .recognition)) (goodQuery .recognition) →
    recognition_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .recognition))
      (queryCommit (goodQuery .recognition)) (goodQuery .recognition) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem recognition_stateCredential_mutant : ¬ (recognition_inversion_premise (.flip .stateCredential)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .recognition)) (queryCommit (goodQuery .recognition)) (goodQuery .recognition) →
    recognition_inversion_claim (.flip .stateCredential) (NoPin.lookupHash hashes) (queryCode (goodQuery .recognition))
      (queryCommit (goodQuery .recognition)) (goodQuery .recognition)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem recognition_statePolicy_candidate : recognition_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .recognition)) (queryCommit (goodQuery .recognition)) (goodQuery .recognition) →
    recognition_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .recognition))
      (queryCommit (goodQuery .recognition)) (goodQuery .recognition) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem recognition_statePolicy_mutant : ¬ (recognition_inversion_premise (.flip .statePolicy)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .recognition)) (queryCommit (goodQuery .recognition)) (goodQuery .recognition) →
    recognition_inversion_claim (.flip .statePolicy) (NoPin.lookupHash hashes) (queryCode (goodQuery .recognition))
      (queryCommit (goodQuery .recognition)) (goodQuery .recognition)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem recognition_stateName_candidate : recognition_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .recognition)) (queryCommit (goodQuery .recognition)) (goodQuery .recognition) →
    recognition_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .recognition))
      (queryCommit (goodQuery .recognition)) (goodQuery .recognition) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem recognition_stateName_mutant : ¬ (recognition_inversion_premise (.flip .stateName)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .recognition)) (queryCommit (goodQuery .recognition)) (goodQuery .recognition) →
    recognition_inversion_claim (.flip .stateName) (NoPin.lookupHash hashes) (queryCode (goodQuery .recognition))
      (queryCommit (goodQuery .recognition)) (goodQuery .recognition)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem recognition_stateQuantity_candidate : recognition_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .recognition)) (queryCommit (goodQuery .recognition)) (goodQuery .recognition) →
    recognition_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .recognition))
      (queryCommit (goodQuery .recognition)) (goodQuery .recognition) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem recognition_stateQuantity_mutant : ¬ (recognition_inversion_premise (.flip .stateQuantity)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .recognition)) (queryCommit (goodQuery .recognition)) (goodQuery .recognition) →
    recognition_inversion_claim (.flip .stateQuantity) (NoPin.lookupHash hashes) (queryCode (goodQuery .recognition))
      (queryCommit (goodQuery .recognition)) (goodQuery .recognition)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem recognition_stateDatum_candidate : recognition_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .recognition)) (queryCommit (goodQuery .recognition)) (goodQuery .recognition) →
    recognition_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .recognition))
      (queryCommit (goodQuery .recognition)) (goodQuery .recognition) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem recognition_stateDatum_mutant : ¬ (recognition_inversion_premise (.flip .stateDatum)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .recognition)) (queryCommit (goodQuery .recognition)) (goodQuery .recognition) →
    recognition_inversion_claim (.flip .stateDatum) (NoPin.lookupHash hashes) (queryCode (goodQuery .recognition))
      (queryCommit (goodQuery .recognition)) (goodQuery .recognition)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem recognition_stateBare_candidate : recognition_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .recognition)) (queryCommit (goodQuery .recognition)) (goodQuery .recognition) →
    recognition_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .recognition))
      (queryCommit (goodQuery .recognition)) (goodQuery .recognition) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem recognition_stateBare_mutant : ¬ (recognition_inversion_premise (.flip .stateBare)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .recognition)) (queryCommit (goodQuery .recognition)) (goodQuery .recognition) →
    recognition_inversion_claim (.flip .stateBare) (NoPin.lookupHash hashes) (queryCode (goodQuery .recognition))
      (queryCommit (goodQuery .recognition)) (goodQuery .recognition)) := by decide

/-- Hypothesis instance under #741, not accepted law; full theorem antecedent. -/
abbrev genesis_inversion_premise (_m : Mutation) (_h : Hash) (_c : Codec) (_t : TrieCommit) (q : Query) : Prop :=
  q.surface = .genesis ∧ caseShape q = true
/-- Hypothesis instance under #741, not accepted law; exact general conclusion. -/
abbrev genesis_inversion_claim (m : Mutation) (h : Hash) (c : Codec) (t : TrieCommit) (q : Query) : Prop :=
  runWith m h c t q = true ↔ expectedWith h c t q = true
/-- Executed full antecedent of the #741 hypothesis, not accepted law. -/
theorem genesis_antecedent : genesis_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .genesis)) (queryCommit (goodQuery .genesis))
    (goodQuery .genesis) := by decide
/-- Executed public case of the #741 hypothesis, not accepted law. -/
theorem genesis_accepted : (runQuery .none (goodQuery .genesis)).toOption = some true := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem genesis_genesisSeed_candidate : genesis_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .genesis)) (queryCommit (goodQuery .genesis)) (goodQuery .genesis) →
    genesis_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .genesis))
      (queryCommit (goodQuery .genesis)) (goodQuery .genesis) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem genesis_genesisSeed_mutant : ¬ (genesis_inversion_premise (.flip .genesisSeed)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .genesis)) (queryCommit (goodQuery .genesis)) (goodQuery .genesis) →
    genesis_inversion_claim (.flip .genesisSeed) (NoPin.lookupHash hashes) (queryCode (goodQuery .genesis))
      (queryCommit (goodQuery .genesis)) (goodQuery .genesis)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem genesis_genesisInvocation_candidate : genesis_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .genesis)) (queryCommit (goodQuery .genesis)) (goodQuery .genesis) →
    genesis_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .genesis))
      (queryCommit (goodQuery .genesis)) (goodQuery .genesis) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem genesis_genesisInvocation_mutant : ¬ (genesis_inversion_premise (.flip .genesisInvocation)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .genesis)) (queryCommit (goodQuery .genesis)) (goodQuery .genesis) →
    genesis_inversion_claim (.flip .genesisInvocation) (NoPin.lookupHash hashes) (queryCode (goodQuery .genesis))
      (queryCommit (goodQuery .genesis)) (goodQuery .genesis)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem genesis_genesisMint_candidate : genesis_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .genesis)) (queryCommit (goodQuery .genesis)) (goodQuery .genesis) →
    genesis_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .genesis))
      (queryCommit (goodQuery .genesis)) (goodQuery .genesis) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem genesis_genesisMint_mutant : ¬ (genesis_inversion_premise (.flip .genesisMint)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .genesis)) (queryCommit (goodQuery .genesis)) (goodQuery .genesis) →
    genesis_inversion_claim (.flip .genesisMint) (NoPin.lookupHash hashes) (queryCode (goodQuery .genesis))
      (queryCommit (goodQuery .genesis)) (goodQuery .genesis)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem genesis_genesisOutput_candidate : genesis_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .genesis)) (queryCommit (goodQuery .genesis)) (goodQuery .genesis) →
    genesis_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .genesis))
      (queryCommit (goodQuery .genesis)) (goodQuery .genesis) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem genesis_genesisOutput_mutant : ¬ (genesis_inversion_premise (.flip .genesisOutput)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .genesis)) (queryCommit (goodQuery .genesis)) (goodQuery .genesis) →
    genesis_inversion_claim (.flip .genesisOutput) (NoPin.lookupHash hashes) (queryCode (goodQuery .genesis))
      (queryCommit (goodQuery .genesis)) (goodQuery .genesis)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem genesis_genesisEmpty_candidate : genesis_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .genesis)) (queryCommit (goodQuery .genesis)) (goodQuery .genesis) →
    genesis_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .genesis))
      (queryCommit (goodQuery .genesis)) (goodQuery .genesis) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem genesis_genesisEmpty_mutant : ¬ (genesis_inversion_premise (.flip .genesisEmpty)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .genesis)) (queryCommit (goodQuery .genesis)) (goodQuery .genesis) →
    genesis_inversion_claim (.flip .genesisEmpty) (NoPin.lookupHash hashes) (queryCode (goodQuery .genesis))
      (queryCommit (goodQuery .genesis)) (goodQuery .genesis)) := by decide

/-- Hypothesis instance under #741, not accepted law; full theorem antecedent. -/
abbrev registration_inversion_premise (_m : Mutation) (_h : Hash) (_c : Codec) (_t : TrieCommit) (q : Query) : Prop :=
  q.surface = .registration ∧ caseShape q = true
/-- Hypothesis instance under #741, not accepted law; exact general conclusion. -/
abbrev registration_inversion_claim (m : Mutation) (h : Hash) (c : Codec) (t : TrieCommit) (q : Query) : Prop :=
  runWith m h c t q = true ↔ expectedWith h c t q = true
/-- Executed full antecedent of the #741 hypothesis, not accepted law. -/
theorem registration_antecedent : registration_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .registration)) (queryCommit (goodQuery .registration))
    (goodQuery .registration) := by decide
/-- Executed public case of the #741 hypothesis, not accepted law. -/
theorem registration_accepted : (runQuery .none (goodQuery .registration)).toOption = some true := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem registration_changeReference_candidate : registration_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .registration)) (queryCommit (goodQuery .registration)) (goodQuery .registration) →
    registration_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .registration))
      (queryCommit (goodQuery .registration)) (goodQuery .registration) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem registration_changeReference_mutant : ¬ (registration_inversion_premise (.flip .changeReference)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .registration)) (queryCommit (goodQuery .registration)) (goodQuery .registration) →
    registration_inversion_claim (.flip .changeReference) (NoPin.lookupHash hashes) (queryCode (goodQuery .registration))
      (queryCommit (goodQuery .registration)) (goodQuery .registration)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem registration_changeApprovalShape_candidate : registration_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .registration)) (queryCommit (goodQuery .registration)) (goodQuery .registration) →
    registration_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .registration))
      (queryCommit (goodQuery .registration)) (goodQuery .registration) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem registration_changeApprovalShape_mutant : ¬ (registration_inversion_premise (.flip .changeApprovalShape)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .registration)) (queryCommit (goodQuery .registration)) (goodQuery .registration) →
    registration_inversion_claim (.flip .changeApprovalShape) (NoPin.lookupHash hashes) (queryCode (goodQuery .registration))
      (queryCommit (goodQuery .registration)) (goodQuery .registration)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem registration_changeApproval_candidate : registration_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .registration)) (queryCommit (goodQuery .registration)) (goodQuery .registration) →
    registration_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .registration))
      (queryCommit (goodQuery .registration)) (goodQuery .registration) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem registration_changeApproval_mutant : ¬ (registration_inversion_premise (.flip .changeApproval)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .registration)) (queryCommit (goodQuery .registration)) (goodQuery .registration) →
    registration_inversion_claim (.flip .changeApproval) (NoPin.lookupHash hashes) (queryCode (goodQuery .registration))
      (queryCommit (goodQuery .registration)) (goodQuery .registration)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem registration_changeApprovalBurn_candidate : registration_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .registration)) (queryCommit (goodQuery .registration)) (goodQuery .registration) →
    registration_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .registration))
      (queryCommit (goodQuery .registration)) (goodQuery .registration) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem registration_changeApprovalBurn_mutant : ¬ (registration_inversion_premise (.flip .changeApprovalBurn)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .registration)) (queryCommit (goodQuery .registration)) (goodQuery .registration) →
    registration_inversion_claim (.flip .changeApprovalBurn) (NoPin.lookupHash hashes) (queryCode (goodQuery .registration))
      (queryCommit (goodQuery .registration)) (goodQuery .registration)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem registration_changeLeaf_candidate : registration_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .registration)) (queryCommit (goodQuery .registration)) (goodQuery .registration) →
    registration_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .registration))
      (queryCommit (goodQuery .registration)) (goodQuery .registration) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem registration_changeLeaf_mutant : ¬ (registration_inversion_premise (.flip .changeLeaf)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .registration)) (queryCommit (goodQuery .registration)) (goodQuery .registration) →
    registration_inversion_claim (.flip .changeLeaf) (NoPin.lookupHash hashes) (queryCode (goodQuery .registration))
      (queryCommit (goodQuery .registration)) (goodQuery .registration)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem registration_registrationPlacement_candidate : registration_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .registration)) (queryCommit (goodQuery .registration)) (goodQuery .registration) →
    registration_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .registration))
      (queryCommit (goodQuery .registration)) (goodQuery .registration) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem registration_registrationPlacement_mutant : ¬ (registration_inversion_premise (.flip .registrationPlacement)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .registration)) (queryCommit (goodQuery .registration)) (goodQuery .registration) →
    registration_inversion_claim (.flip .registrationPlacement) (NoPin.lookupHash hashes) (queryCode (goodQuery .registration))
      (queryCommit (goodQuery .registration)) (goodQuery .registration)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem registration_registrationMint_candidate : registration_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .registration)) (queryCommit (goodQuery .registration)) (goodQuery .registration) →
    registration_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .registration))
      (queryCommit (goodQuery .registration)) (goodQuery .registration) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem registration_registrationMint_mutant : ¬ (registration_inversion_premise (.flip .registrationMint)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .registration)) (queryCommit (goodQuery .registration)) (goodQuery .registration) →
    registration_inversion_claim (.flip .registrationMint) (NoPin.lookupHash hashes) (queryCode (goodQuery .registration))
      (queryCommit (goodQuery .registration)) (goodQuery .registration)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem registration_registrationDeposit_candidate : registration_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .registration)) (queryCommit (goodQuery .registration)) (goodQuery .registration) →
    registration_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .registration))
      (queryCommit (goodQuery .registration)) (goodQuery .registration) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem registration_registrationDeposit_mutant : ¬ (registration_inversion_premise (.flip .registrationDeposit)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .registration)) (queryCommit (goodQuery .registration)) (goodQuery .registration) →
    registration_inversion_claim (.flip .registrationDeposit) (NoPin.lookupHash hashes) (queryCode (goodQuery .registration))
      (queryCommit (goodQuery .registration)) (goodQuery .registration)) := by decide

/-- Hypothesis instance under #741, not accepted law; full theorem antecedent. -/
abbrev termination_inversion_premise (_m : Mutation) (_h : Hash) (_c : Codec) (_t : TrieCommit) (q : Query) : Prop :=
  q.surface = .termination ∧ caseShape q = true
/-- Hypothesis instance under #741, not accepted law; exact general conclusion. -/
abbrev termination_inversion_claim (m : Mutation) (h : Hash) (c : Codec) (t : TrieCommit) (q : Query) : Prop :=
  runWith m h c t q = true ↔ expectedWith h c t q = true
/-- Executed full antecedent of the #741 hypothesis, not accepted law. -/
theorem termination_antecedent : termination_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .termination)) (queryCommit (goodQuery .termination))
    (goodQuery .termination) := by decide
/-- Executed public case of the #741 hypothesis, not accepted law. -/
theorem termination_accepted : (runQuery .none (goodQuery .termination)).toOption = some true := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem termination_changeReference_candidate : termination_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .termination)) (queryCommit (goodQuery .termination)) (goodQuery .termination) →
    termination_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .termination))
      (queryCommit (goodQuery .termination)) (goodQuery .termination) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem termination_changeReference_mutant : ¬ (termination_inversion_premise (.flip .changeReference)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .termination)) (queryCommit (goodQuery .termination)) (goodQuery .termination) →
    termination_inversion_claim (.flip .changeReference) (NoPin.lookupHash hashes) (queryCode (goodQuery .termination))
      (queryCommit (goodQuery .termination)) (goodQuery .termination)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem termination_changeApprovalShape_candidate : termination_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .termination)) (queryCommit (goodQuery .termination)) (goodQuery .termination) →
    termination_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .termination))
      (queryCommit (goodQuery .termination)) (goodQuery .termination) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem termination_changeApprovalShape_mutant : ¬ (termination_inversion_premise (.flip .changeApprovalShape)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .termination)) (queryCommit (goodQuery .termination)) (goodQuery .termination) →
    termination_inversion_claim (.flip .changeApprovalShape) (NoPin.lookupHash hashes) (queryCode (goodQuery .termination))
      (queryCommit (goodQuery .termination)) (goodQuery .termination)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem termination_changeApproval_candidate : termination_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .termination)) (queryCommit (goodQuery .termination)) (goodQuery .termination) →
    termination_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .termination))
      (queryCommit (goodQuery .termination)) (goodQuery .termination) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem termination_changeApproval_mutant : ¬ (termination_inversion_premise (.flip .changeApproval)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .termination)) (queryCommit (goodQuery .termination)) (goodQuery .termination) →
    termination_inversion_claim (.flip .changeApproval) (NoPin.lookupHash hashes) (queryCode (goodQuery .termination))
      (queryCommit (goodQuery .termination)) (goodQuery .termination)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem termination_changeApprovalBurn_candidate : termination_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .termination)) (queryCommit (goodQuery .termination)) (goodQuery .termination) →
    termination_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .termination))
      (queryCommit (goodQuery .termination)) (goodQuery .termination) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem termination_changeApprovalBurn_mutant : ¬ (termination_inversion_premise (.flip .changeApprovalBurn)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .termination)) (queryCommit (goodQuery .termination)) (goodQuery .termination) →
    termination_inversion_claim (.flip .changeApprovalBurn) (NoPin.lookupHash hashes) (queryCode (goodQuery .termination))
      (queryCommit (goodQuery .termination)) (goodQuery .termination)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem termination_changeLeaf_candidate : termination_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .termination)) (queryCommit (goodQuery .termination)) (goodQuery .termination) →
    termination_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .termination))
      (queryCommit (goodQuery .termination)) (goodQuery .termination) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem termination_changeLeaf_mutant : ¬ (termination_inversion_premise (.flip .changeLeaf)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .termination)) (queryCommit (goodQuery .termination)) (goodQuery .termination) →
    termination_inversion_claim (.flip .changeLeaf) (NoPin.lookupHash hashes) (queryCode (goodQuery .termination))
      (queryCommit (goodQuery .termination)) (goodQuery .termination)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem termination_terminationHeld_candidate : termination_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .termination)) (queryCommit (goodQuery .termination)) (goodQuery .termination) →
    termination_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .termination))
      (queryCommit (goodQuery .termination)) (goodQuery .termination) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem termination_terminationHeld_mutant : ¬ (termination_inversion_premise (.flip .terminationHeld)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .termination)) (queryCommit (goodQuery .termination)) (goodQuery .termination) →
    termination_inversion_claim (.flip .terminationHeld) (NoPin.lookupHash hashes) (queryCode (goodQuery .termination))
      (queryCommit (goodQuery .termination)) (goodQuery .termination)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem termination_terminationBurn_candidate : termination_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .termination)) (queryCommit (goodQuery .termination)) (goodQuery .termination) →
    termination_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .termination))
      (queryCommit (goodQuery .termination)) (goodQuery .termination) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem termination_terminationBurn_mutant : ¬ (termination_inversion_premise (.flip .terminationBurn)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .termination)) (queryCommit (goodQuery .termination)) (goodQuery .termination) →
    termination_inversion_claim (.flip .terminationBurn) (NoPin.lookupHash hashes) (queryCode (goodQuery .termination))
      (queryCommit (goodQuery .termination)) (goodQuery .termination)) := by decide

/-- Hypothesis instance under #741, not accepted law; full theorem antecedent. -/
abbrev batch_inversion_premise (_m : Mutation) (_h : Hash) (_c : Codec) (_t : TrieCommit) (q : Query) : Prop :=
  q.surface = .batch ∧ caseShape q = true
/-- Hypothesis instance under #741, not accepted law; exact general conclusion. -/
abbrev batch_inversion_claim (m : Mutation) (h : Hash) (c : Codec) (t : TrieCommit) (q : Query) : Prop :=
  runWith m h c t q = true ↔ expectedWith h c t q = true
/-- Executed full antecedent of the #741 hypothesis, not accepted law. -/
theorem batch_antecedent : batch_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch))
    (goodQuery .batch) := by decide
/-- Executed public case of the #741 hypothesis, not accepted law. -/
theorem batch_accepted : (runQuery .none (goodQuery .batch)).toOption = some true := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem batch_changeReference_candidate : batch_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem batch_changeReference_mutant : ¬ (batch_inversion_premise (.flip .changeReference)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim (.flip .changeReference) (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem batch_changeApprovalShape_candidate : batch_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem batch_changeApprovalShape_mutant : ¬ (batch_inversion_premise (.flip .changeApprovalShape)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim (.flip .changeApprovalShape) (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem batch_changeApproval_candidate : batch_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem batch_changeApproval_mutant : ¬ (batch_inversion_premise (.flip .changeApproval)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim (.flip .changeApproval) (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem batch_changeApprovalBurn_candidate : batch_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem batch_changeApprovalBurn_mutant : ¬ (batch_inversion_premise (.flip .changeApprovalBurn)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim (.flip .changeApprovalBurn) (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem batch_changeLeaf_candidate : batch_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem batch_changeLeaf_mutant : ¬ (batch_inversion_premise (.flip .changeLeaf)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim (.flip .changeLeaf) (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem batch_registrationPlacement_candidate : batch_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem batch_registrationPlacement_mutant : ¬ (batch_inversion_premise (.flip .registrationPlacement)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim (.flip .registrationPlacement) (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem batch_registrationMint_candidate : batch_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem batch_registrationMint_mutant : ¬ (batch_inversion_premise (.flip .registrationMint)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim (.flip .registrationMint) (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem batch_registrationDeposit_candidate : batch_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem batch_registrationDeposit_mutant : ¬ (batch_inversion_premise (.flip .registrationDeposit)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim (.flip .registrationDeposit) (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem batch_terminationHeld_candidate : batch_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem batch_terminationHeld_mutant : ¬ (batch_inversion_premise (.flip .terminationHeld)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim (.flip .terminationHeld) (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem batch_terminationBurn_candidate : batch_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem batch_terminationBurn_mutant : ¬ (batch_inversion_premise (.flip .terminationBurn)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim (.flip .terminationBurn) (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem batch_foldIdentity_candidate : batch_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem batch_foldIdentity_mutant : ¬ (batch_inversion_premise (.flip .foldIdentity)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim (.flip .foldIdentity) (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem batch_foldBefore_candidate : batch_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem batch_foldBefore_mutant : ¬ (batch_inversion_premise (.flip .foldBefore)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim (.flip .foldBefore) (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem batch_foldNonempty_candidate : batch_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem batch_foldNonempty_mutant : ¬ (batch_inversion_premise (.flip .foldNonempty)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim (.flip .foldNonempty) (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem batch_foldDistinct_candidate : batch_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem batch_foldDistinct_mutant : ¬ (batch_inversion_premise (.flip .foldDistinct)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim (.flip .foldDistinct) (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem batch_foldPairing_candidate : batch_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem batch_foldPairing_mutant : ¬ (batch_inversion_premise (.flip .foldPairing)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim (.flip .foldPairing) (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem batch_foldTrie_candidate : batch_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem batch_foldTrie_mutant : ¬ (batch_inversion_premise (.flip .foldTrie)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim (.flip .foldTrie) (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem batch_foldContinuation_candidate : batch_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem batch_foldContinuation_mutant : ¬ (batch_inversion_premise (.flip .foldContinuation)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim (.flip .foldContinuation) (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem batch_foldAddress_candidate : batch_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem batch_foldAddress_mutant : ¬ (batch_inversion_premise (.flip .foldAddress)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim (.flip .foldAddress) (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem batch_foldValue_candidate : batch_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem batch_foldValue_mutant : ¬ (batch_inversion_premise (.flip .foldValue)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim (.flip .foldValue) (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem batch_foldWholePolicy_candidate : batch_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem batch_foldWholePolicy_mutant : ¬ (batch_inversion_premise (.flip .foldWholePolicy)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim (.flip .foldWholePolicy) (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem batch_foldNoNewConsumed_candidate : batch_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem batch_foldNoNewConsumed_mutant : ¬ (batch_inversion_premise (.flip .foldNoNewConsumed)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .batch)) (queryCommit (goodQuery .batch)) (goodQuery .batch) →
    batch_inversion_claim (.flip .foldNoNewConsumed) (NoPin.lookupHash hashes) (queryCode (goodQuery .batch))
      (queryCommit (goodQuery .batch)) (goodQuery .batch)) := by decide

/-- Hypothesis fixture under #741, not accepted law; a minted active token with a fabricated root. -/
def fakeState : Query :=
  let q := goodQuery .recognition
  let output := { q.output with
    datum := .root 999
    assets := [(activeAsset (NoPin.lookupHash hashes) (queryCode q)
      q.observation.before.identity q.action.key, 1)] }
  { q with output := output }
/-- Executed finite encoding premise of the #741 hypothesis, not accepted law. -/
theorem role_encoding : FiniteEncoding (queryCode fakeState) (roleDomain fakeState) := by
  intro a ha b hb he
  simp only [roleDomain, List.mem_cons, List.mem_nil_iff, or_false] at ha hb
  rcases ha with rfl | rfl <;> rcases hb with rfl | rfl
  · rfl
  · have hn : queryCode fakeState (.state fakeState.seed) ≠
        queryCode fakeState (.active fakeState.observation.before.identity fakeState.action.key) := by decide
    exact False.elim (hn he)
  · have hn : queryCode fakeState (.active fakeState.observation.before.identity fakeState.action.key) ≠
        queryCode fakeState (.state fakeState.seed) := by decide
    exact False.elim (hn he)
  · rfl
/-- Executed finite collision premise of the #741 hypothesis, not accepted law. -/
theorem role_collision : FiniteCollisionFree (NoPin.lookupHash hashes) (queryCode fakeState)
    (roleDomain fakeState) := by
  intro a ha b hb he
  simp only [roleDomain, List.mem_cons, List.mem_nil_iff, or_false] at ha hb
  rcases ha with rfl | rfl <;> rcases hb with rfl | rfl
  · rfl
  · have hn : NoPin.lookupHash hashes (queryCode fakeState (.state fakeState.seed)) ≠
        NoPin.lookupHash hashes (queryCode fakeState (.active fakeState.observation.before.identity fakeState.action.key)) := by decide
    exact False.elim (hn he)
  · have hn : NoPin.lookupHash hashes (queryCode fakeState (.active fakeState.observation.before.identity fakeState.action.key)) ≠
        NoPin.lookupHash hashes (queryCode fakeState (.state fakeState.seed)) := by decide
    exact False.elim (hn he)
  · rfl
/-- Hypothesis instance under #741, not accepted law; exact role-separation antecedent. -/
abbrev active_role_never_state_premise (_m : Mutation) (h : Hash) (c : Codec) (_t : TrieCommit) (q : Query) : Prop :=
  RolePremises h c q
/-- Hypothesis instance under #741, not accepted law; exact role-separation conclusion. -/
abbrev active_role_never_state_claim (m : Mutation) (h : Hash) (c : Codec) (_t : TrieCommit) (q : Query) : Prop :=
  recognizeState m h c q.release q.seed q.output = false
/-- Executed complete role premise of the #741 hypothesis, not accepted law. -/
theorem active_role_never_state_antecedent : active_role_never_state_premise .none
    (NoPin.lookupHash hashes) (queryCode fakeState) (queryCommit fakeState) fakeState :=
  ⟨role_encoding, role_collision, rfl⟩
/-- Hypothesis instance under #741, not accepted law; exact minted-role antecedent. -/
abbrev minted_active_never_state_premise (_m : Mutation) (h : Hash) (c : Codec) (t : TrieCommit) (q : Query) : Prop :=
  MintedRolePremises h c t q
/-- Hypothesis instance under #741, not accepted law; exact minted-role conclusion. -/
abbrev minted_active_never_state_claim (m : Mutation) (h : Hash) (c : Codec) (_t : TrieCommit) (q : Query) : Prop :=
  recognizeState m h c q.release q.seed q.output = false
/-- Executed complete minted-role premise of the #741 hypothesis, not accepted law. -/
theorem minted_active_never_state_antecedent : minted_active_never_state_premise .none
    (NoPin.lookupHash hashes) (queryCode fakeState) (queryCommit fakeState) fakeState := by
  exact ⟨active_role_never_state_antecedent, by decide, by decide⟩

/-- Executed role refusal of the #741 hypothesis, not accepted law. -/
theorem active_role_never_state_candidate : active_role_never_state_premise .none
    (NoPin.lookupHash hashes) (queryCode fakeState) (queryCommit fakeState) fakeState →
    active_role_never_state_claim .none (NoPin.lookupHash hashes) (queryCode fakeState) (queryCommit fakeState) fakeState := by
  intro _
  decide
/-- Executed single-name-guard falsification of the #741 hypothesis, not accepted law. -/
theorem active_role_never_state_mutant : ¬ (active_role_never_state_premise (.flip .stateName)
    (NoPin.lookupHash hashes) (queryCode fakeState) (queryCommit fakeState) fakeState →
    active_role_never_state_claim (.flip .stateName) (NoPin.lookupHash hashes) (queryCode fakeState) (queryCommit fakeState) fakeState) := by
  intro accepted
  have refused := accepted active_role_never_state_antecedent
  unfold active_role_never_state_claim at refused
  have accepts : recognizeState (.flip .stateName) (NoPin.lookupHash hashes) (queryCode fakeState)
      fakeState.release fakeState.seed fakeState.output = true := by decide
  rw [accepts] at refused
  cases refused

/-- Executed role refusal of the #741 hypothesis, not accepted law. -/
theorem minted_active_never_state_candidate : minted_active_never_state_premise .none
    (NoPin.lookupHash hashes) (queryCode fakeState) (queryCommit fakeState) fakeState →
    minted_active_never_state_claim .none (NoPin.lookupHash hashes) (queryCode fakeState) (queryCommit fakeState) fakeState := by
  intro _
  decide
/-- Executed single-name-guard falsification of the #741 hypothesis, not accepted law. -/
theorem minted_active_never_state_mutant : ¬ (minted_active_never_state_premise (.flip .stateName)
    (NoPin.lookupHash hashes) (queryCode fakeState) (queryCommit fakeState) fakeState →
    minted_active_never_state_claim (.flip .stateName) (NoPin.lookupHash hashes) (queryCode fakeState) (queryCommit fakeState) fakeState) := by
  intro accepted
  have refused := accepted minted_active_never_state_antecedent
  unfold minted_active_never_state_claim at refused
  have accepts : recognizeState (.flip .stateName) (NoPin.lookupHash hashes) (queryCode fakeState)
      fakeState.release fakeState.seed fakeState.output = true := by decide
  rw [accepts] at refused
  cases refused

/-- Hypothesis fixture under #741, not accepted law; keep all views of one physical output aligned. -/
def changeContinuation (q : Query) (next : ObservedOutput) : Query :=
  let observation := { q.observation with
    after := { q.observation.after with state := next },
    outputs := next :: q.observation.outputs.drop 1 }
  { q with observation := { observation with assets := { observation.assets with
      outputs := observation.outputs.map fun output => ⟨output.assets⟩ } } }
/-- Hypothesis fixture under #741, not accepted law; independent unapproved asset under the state policy. -/
def extraAsset : TokenId := ⟨release.statePolicy, hash (code (.active registryId 999))⟩
/-- Hypothesis fixture under #741, not accepted law; each explicit boundary attack changes one guard. -/
def badQueries : List (String × Query × Guard) :=
  let q := goodQuery .batch
  let extra (amount : Int) := { q with observation := { q.observation with
    assets := { q.observation.assets with mint := q.observation.assets.mint ++ [(extraAsset, amount)] } } }
  let wrongOutputs := q.observation.outputs.zipIdx.map fun (output, index) =>
    if index == 1 then { output with assets := [] }
    else if index == 2 then { output with assets := (q.observation.outputs[1]).assets }
    else output
  let wrong := { q.observation with outputs := wrongOutputs }
  let wrong := { wrong with assets := { wrong.assets with outputs := wrongOutputs.map fun output => ⟨output.assets⟩ } }
  [("extra-state-policy-mint", extra 1, .foldWholePolicy),
   ("extra-state-policy-burn", extra (-1), .foldWholePolicy),
   ("active-token-at-wrong-output", { q with observation := wrong }, .registrationPlacement),
   ("state-ada-drain", changeContinuation q { q.observation.after.state with lovelace := 1 }, .foldValue),
   ("state-token-stuffing", changeContinuation q { q.observation.after.state with
      assets := q.observation.after.state.assets ++ [(extraAsset, 1)] }, .foldContinuation),
   ("genuine-minted-active-as-state", fakeState, .stateName)]

/-- Hypothesis instance under #741, not accepted law; full theorem antecedent. -/
abbrev publicFold_inversion_premise (_m : Mutation) (_h : Hash) (_c : Codec) (_t : TrieCommit) (q : Query) : Prop :=
  q.surface = .publicFold ∧ caseShape q = true
/-- Hypothesis instance under #741, not accepted law; exact general conclusion. -/
abbrev publicFold_inversion_claim (m : Mutation) (h : Hash) (c : Codec) (t : TrieCommit) (q : Query) : Prop :=
  runWith m h c t q = true ↔ expectedWith h c t q = true
/-- Executed full antecedent of the #741 hypothesis, not accepted law. -/
theorem publicFold_antecedent : publicFold_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold))
    (goodQuery .publicFold) := by decide
/-- Executed public case of the #741 hypothesis, not accepted law. -/
theorem publicFold_accepted : (runQuery .none (goodQuery .publicFold)).toOption = some true := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem publicFold_changeReference_candidate : publicFold_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem publicFold_changeReference_mutant : ¬ (publicFold_inversion_premise (.flip .changeReference)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim (.flip .changeReference) (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem publicFold_changeApprovalShape_candidate : publicFold_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem publicFold_changeApprovalShape_mutant : ¬ (publicFold_inversion_premise (.flip .changeApprovalShape)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim (.flip .changeApprovalShape) (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem publicFold_changeApproval_candidate : publicFold_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem publicFold_changeApproval_mutant : ¬ (publicFold_inversion_premise (.flip .changeApproval)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim (.flip .changeApproval) (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem publicFold_changeApprovalBurn_candidate : publicFold_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem publicFold_changeApprovalBurn_mutant : ¬ (publicFold_inversion_premise (.flip .changeApprovalBurn)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim (.flip .changeApprovalBurn) (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem publicFold_changeLeaf_candidate : publicFold_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem publicFold_changeLeaf_mutant : ¬ (publicFold_inversion_premise (.flip .changeLeaf)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim (.flip .changeLeaf) (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem publicFold_registrationPlacement_candidate : publicFold_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem publicFold_registrationPlacement_mutant : ¬ (publicFold_inversion_premise (.flip .registrationPlacement)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim (.flip .registrationPlacement) (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem publicFold_registrationMint_candidate : publicFold_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem publicFold_registrationMint_mutant : ¬ (publicFold_inversion_premise (.flip .registrationMint)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim (.flip .registrationMint) (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem publicFold_registrationDeposit_candidate : publicFold_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem publicFold_registrationDeposit_mutant : ¬ (publicFold_inversion_premise (.flip .registrationDeposit)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim (.flip .registrationDeposit) (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem publicFold_terminationHeld_candidate : publicFold_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem publicFold_terminationHeld_mutant : ¬ (publicFold_inversion_premise (.flip .terminationHeld)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim (.flip .terminationHeld) (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem publicFold_terminationBurn_candidate : publicFold_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem publicFold_terminationBurn_mutant : ¬ (publicFold_inversion_premise (.flip .terminationBurn)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim (.flip .terminationBurn) (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem publicFold_foldIdentity_candidate : publicFold_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem publicFold_foldIdentity_mutant : ¬ (publicFold_inversion_premise (.flip .foldIdentity)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim (.flip .foldIdentity) (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem publicFold_foldBefore_candidate : publicFold_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem publicFold_foldBefore_mutant : ¬ (publicFold_inversion_premise (.flip .foldBefore)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim (.flip .foldBefore) (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem publicFold_foldNonempty_candidate : publicFold_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem publicFold_foldNonempty_mutant : ¬ (publicFold_inversion_premise (.flip .foldNonempty)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim (.flip .foldNonempty) (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem publicFold_foldDistinct_candidate : publicFold_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem publicFold_foldDistinct_mutant : ¬ (publicFold_inversion_premise (.flip .foldDistinct)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim (.flip .foldDistinct) (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem publicFold_foldPairing_candidate : publicFold_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem publicFold_foldPairing_mutant : ¬ (publicFold_inversion_premise (.flip .foldPairing)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim (.flip .foldPairing) (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem publicFold_foldTrie_candidate : publicFold_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem publicFold_foldTrie_mutant : ¬ (publicFold_inversion_premise (.flip .foldTrie)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim (.flip .foldTrie) (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem publicFold_foldContinuation_candidate : publicFold_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem publicFold_foldContinuation_mutant : ¬ (publicFold_inversion_premise (.flip .foldContinuation)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim (.flip .foldContinuation) (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem publicFold_foldAddress_candidate : publicFold_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem publicFold_foldAddress_mutant : ¬ (publicFold_inversion_premise (.flip .foldAddress)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim (.flip .foldAddress) (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem publicFold_foldValue_candidate : publicFold_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem publicFold_foldValue_mutant : ¬ (publicFold_inversion_premise (.flip .foldValue)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim (.flip .foldValue) (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem publicFold_foldWholePolicy_candidate : publicFold_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem publicFold_foldWholePolicy_mutant : ¬ (publicFold_inversion_premise (.flip .foldWholePolicy)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim (.flip .foldWholePolicy) (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold)) := by decide

/-- Executed unmutated instance of the #741 hypothesis, not accepted law. -/
theorem publicFold_foldNoNewConsumed_candidate : publicFold_inversion_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) := by decide
/-- Executed single-guard falsification of the #741 hypothesis, not accepted law. -/
theorem publicFold_foldNoNewConsumed_mutant : ¬ (publicFold_inversion_premise (.flip .foldNoNewConsumed)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    publicFold_inversion_claim (.flip .foldNoNewConsumed) (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold)) := by decide


/-- Executed finite-domain premise of the #741 hypothesis, not accepted law. -/
theorem public_encoding : FiniteEncoding (queryCode (goodQuery .publicFold)) (publicDomain (goodQuery .publicFold)) := by
  intro a ha b hb he
  change a ∈ [Preimage.state seed, .active registryId registration.key,
    .registrationApproval registrationData.registry registrationData.key registrationData.holdingAddress
      registrationData.initialDatum registrationData.deposit,
    .active registryId termination.key, .terminationApproval registryId termination.key] at ha
  change b ∈ [Preimage.state seed, .active registryId registration.key,
    .registrationApproval registrationData.registry registrationData.key registrationData.holdingAddress
      registrationData.initialDatum registrationData.deposit,
    .active registryId termination.key, .terminationApproval registryId termination.key] at hb
  simp only [List.mem_cons, List.mem_nil_iff, or_false] at ha hb
  rcases ha with rfl | rfl | rfl | rfl | rfl <;>
    rcases hb with rfl | rfl | rfl | rfl | rfl
  all_goals first | rfl | exact False.elim ((by decide : _ ≠ _) he)

/-- Executed finite-domain premise of the #741 hypothesis, not accepted law. -/
theorem public_collision : FiniteCollisionFree (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (publicDomain (goodQuery .publicFold)) := by
  intro a ha b hb he
  change a ∈ [Preimage.state seed, .active registryId registration.key,
    .registrationApproval registrationData.registry registrationData.key registrationData.holdingAddress
      registrationData.initialDatum registrationData.deposit,
    .active registryId termination.key, .terminationApproval registryId termination.key] at ha
  change b ∈ [Preimage.state seed, .active registryId registration.key,
    .registrationApproval registrationData.registry registrationData.key registrationData.holdingAddress
      registrationData.initialDatum registrationData.deposit,
    .active registryId termination.key, .terminationApproval registryId termination.key] at hb
  simp only [List.mem_cons, List.mem_nil_iff, or_false] at ha hb
  rcases ha with rfl | rfl | rfl | rfl | rfl <;>
    rcases hb with rfl | rfl | rfl | rfl | rfl
  all_goals first | rfl | exact False.elim ((by decide : _ ≠ _) he)

/-- Executed full public-input premise of the #741 hypothesis, not accepted law. -/
theorem public_input_facts : PublicFoldPremises (NoPin.lookupHash hashes)
    (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold))
    (queryDecode (goodQuery .publicFold)) release Fixtures.registry [registration, termination] funding := by
  refine ⟨by decide, by decide, by decide, by decide, by decide, by decide,
    by decide, by decide, by decide, by decide, by decide, ?_, ?_⟩
  · intro output member
    change output ∈ [Fixtures.registry.state, registration.output, termination.output, funding.ordinaryInput] at member
    simp only [List.mem_cons, List.mem_nil_iff, or_false] at member
    rcases member with rfl | rfl | rfl | rfl <;> decide
  · intro request member
    simp only [List.mem_cons, List.mem_nil_iff, or_false] at member
    rcases member with rfl | rfl <;> dsimp [Fixtures.registration, Fixtures.termination] <;> decide
/-- Hypothesis instance under #741, not accepted law; exact public-build antecedent. -/
abbrev public_fold_constructed_premise (_m : Mutation) (h : Hash) (c : Codec) (t : TrieCommit) (q : Query) : Prop :=
  PublicPremises h c t q
/-- Hypothesis instance under #741, not accepted law; exact constructive conclusion. -/
abbrev public_fold_constructed_claim (m : Mutation) (h : Hash) (c : Codec) (t : TrieCommit) (q : Query) : Prop :=
  PublicConclusion m h c t q
/-- Executed complete public-build antecedent of the #741 hypothesis, not accepted law. -/
theorem public_fold_constructed_antecedent : public_fold_constructed_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
    (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) :=
  ⟨public_input_facts, by decide, public_encoding, public_collision⟩
/-- Executed constructive public fold of the #741 hypothesis, not accepted law. -/
theorem public_fold_constructed_candidate : public_fold_constructed_premise .none
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
    (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    public_fold_constructed_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) := by
  intro _
  decide
/-- Executed single-whole-policy-guard falsification of the #741 hypothesis, not accepted law. -/
theorem public_fold_constructed_mutant : ¬ (public_fold_constructed_premise (.flip .foldWholePolicy)
    (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
    (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) →
    public_fold_constructed_claim (.flip .foldWholePolicy) (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold))
      (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold)) := by
  intro accepted
  have bad : ¬ public_fold_constructed_claim (.flip .foldWholePolicy) (NoPin.lookupHash hashes)
      (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) := by decide
  exact bad (accepted public_fold_constructed_antecedent)


/-- Hypothesis fixture under #741, not accepted law; two independently approved registrations. -/
def secondRegistration : PendingRequest :=
  let data := { registrationData with key := 9 }
  .registration ⟨⟨16, 0⟩, release.applicationCredential, 23, .application 2007,
    [(registrationAsset hash code release data, 1)]⟩ data
/-- Hypothesis fixture under #741, not accepted law; actual two-carrier fold. -/
def doubleRegistration : FoldObservation :=
  buildFold hash code commit release Fixtures.registry [registration, secondRegistration] funding
/-- Executed cardinality-two positive, not accepted law. -/
theorem double_registration_accepted : fold .none hash code commit release doubleRegistration = true := by decide
/-- Hypothesis fixture under #741, not accepted law; shared carrier underfunds the summed deposits. -/
def sharedRegistration : FoldObservation :=
  let o := doubleRegistration
  let holding := { o.outputs[1] with assets := o.outputs[1].assets ++ o.outputs[2].assets }
  let outputs := [o.outputs[0], holding, { o.outputs[2] with assets := [] }, o.outputs[3]]
  let changes := o.changes.map fun action => match action with
    | .register ref key _ deposit => .register ref key 1 deposit
    | .terminate ref key => .terminate ref key
  { o with outputs, changes, assets := { o.assets with outputs := outputs.map fun output => ⟨output.assets⟩ } }
/-- Hypothesis fixture under #741, not accepted law; a real continuation with an illicit state-role mint. -/
def mintedStateFold : FoldObservation :=
  { mixed with assets := { mixed.assets with mint := mixed.assets.mint ++ [(registryId, 1)] } }
/-- Hypothesis fixture under #741, not accepted law; complete serialized observations. -/
def repairQuery (o : FoldObservation) : Query :=
  let ps := [.state seed] ++ o.changes.flatMap (changePreimages o)
  let cs := ps.map fun p => CodeEntry.mk p (code p)
  { (goodQuery .batch) with
    observation := o
    requests := []
    action := o.changes.head?.getD (.terminate ⟨0, 0⟩ 0)
    codes := cs
    hashes := cs.map (fun row => ⟨row.encoded, hash row.encoded⟩)
    roots := [[], o.before.trie, o.after.trie].map (fun trie => ⟨trie, commit trie⟩) }

/-- Hypothesis instance under #741, not accepted law; complete new statement premise. -/
abbrev registration_effects_premise (_m : Mutation) (_h : Hash) (_c : Codec) (_t : TrieCommit) (q : Query) : Prop := q.surface = .registration ∧ caseShape q = true
/-- Hypothesis instance under #741, not accepted law; exact independent conclusion. -/
abbrev registration_effects_claim (m : Mutation) (h : Hash) (c : Codec) (t : TrieCommit) (q : Query) : Prop := (change m h c q.release q.trie q.action q.observation).toOption = some (targetTrie q.trie q.action) ↔ (changeConditions h c q.release q.trie q.action q.observation).isOk = true
/-- Executed complete premise, not accepted law. -/
theorem registration_effects_antecedent : registration_effects_premise .none hash code commit (goodQuery .registration) := by decide
/-- Executed unmutated instance, not accepted law. -/
theorem registration_effects_candidate : registration_effects_premise .none hash code commit (goodQuery .registration) → registration_effects_claim .none hash code commit (goodQuery .registration) := by decide
/-- Executed single-guard falsification, not accepted law. -/
theorem registration_effects_mutant : ¬ (registration_effects_premise (.flip .registrationMint) hash code commit (goodQuery .registration) → registration_effects_claim (.flip .registrationMint) hash code commit (goodQuery .registration)) := by decide

/-- Hypothesis instance under #741, not accepted law; complete new statement premise. -/
abbrev termination_effects_premise (_m : Mutation) (_h : Hash) (_c : Codec) (_t : TrieCommit) (q : Query) : Prop := q.surface = .termination ∧ caseShape q = true
/-- Hypothesis instance under #741, not accepted law; exact independent conclusion. -/
abbrev termination_effects_claim (m : Mutation) (h : Hash) (c : Codec) (t : TrieCommit) (q : Query) : Prop := (change m h c q.release q.trie q.action q.observation).toOption = some (targetTrie q.trie q.action) ↔ (changeConditions h c q.release q.trie q.action q.observation).isOk = true
/-- Executed complete premise, not accepted law. -/
theorem termination_effects_antecedent : termination_effects_premise .none hash code commit (goodQuery .termination) := by decide
/-- Executed unmutated instance, not accepted law. -/
theorem termination_effects_candidate : termination_effects_premise .none hash code commit (goodQuery .termination) → termination_effects_claim .none hash code commit (goodQuery .termination) := by decide
/-- Executed single-guard falsification, not accepted law. -/
theorem termination_effects_mutant : ¬ (termination_effects_premise (.flip .terminationBurn) hash code commit (goodQuery .termination) → termination_effects_claim (.flip .terminationBurn) hash code commit (goodQuery .termination)) := by decide

/-- Hypothesis instance under #741, not accepted law; complete new statement premise. -/
abbrev batch_effects_premise (_m : Mutation) (_h : Hash) (_c : Codec) (_t : TrieCommit) (q : Query) : Prop := q.surface = .batch ∧ caseShape q = true
/-- Hypothesis instance under #741, not accepted law; exact independent conclusion. -/
abbrev batch_effects_claim (m : Mutation) (h : Hash) (c : Codec) (t : TrieCommit) (q : Query) : Prop := fold m h c t q.release q.observation = true ↔ foldConditions h c t q.release q.observation = true ∧ batchEffects t q.observation
/-- Executed complete premise, not accepted law. -/
theorem batch_effects_antecedent : batch_effects_premise .none hash code commit (goodQuery .batch) := by decide
/-- Executed unmutated instance, not accepted law. -/
theorem batch_effects_candidate : batch_effects_premise .none hash code commit (goodQuery .batch) → batch_effects_claim .none hash code commit (goodQuery .batch) := by decide
/-- Executed single-guard falsification, not accepted law. -/
theorem batch_effects_mutant : ¬ (batch_effects_premise (.flip .foldTrie) hash code commit (goodQuery .batch) → batch_effects_claim (.flip .foldTrie) hash code commit (goodQuery .batch)) := by decide

/-- Hypothesis instance under #741, not accepted law; complete new statement premise. -/
abbrev registration_separate_holdings_premise (_m : Mutation) (_h : Hash) (_c : Codec) (_t : TrieCommit) (q : Query) : Prop := q.surface = .batch ∧ caseShape q = true
/-- Hypothesis instance under #741, not accepted law; exact independent conclusion. -/
abbrev registration_separate_holdings_claim (m : Mutation) (h : Hash) (c : Codec) (t : TrieCommit) (q : Query) : Prop := fold m h c t q.release q.observation = true ↔ foldConditions h c t q.release q.observation = true ∧ holdingDelivery h c q.observation = true
/-- Executed complete premise, not accepted law. -/
theorem registration_separate_holdings_antecedent : registration_separate_holdings_premise .none hash code commit (repairQuery sharedRegistration) := by decide
/-- Executed unmutated instance, not accepted law. -/
theorem registration_separate_holdings_candidate : registration_separate_holdings_premise .none hash code commit (repairQuery sharedRegistration) → registration_separate_holdings_claim .none hash code commit (repairQuery sharedRegistration) := by decide
/-- Executed single-guard falsification, not accepted law. -/
theorem registration_separate_holdings_mutant : ¬ (registration_separate_holdings_premise (.flip .registrationPlacement) hash code commit (repairQuery sharedRegistration) → registration_separate_holdings_claim (.flip .registrationPlacement) hash code commit (repairQuery sharedRegistration)) := by decide

/-- Executed cardinality-two holding delivery, not accepted law. -/
theorem double_registration_delivery : holdingDelivery hash code doubleRegistration = true := by decide
/-- Executed refusal of the shared carrier, not accepted law. -/
theorem shared_registration_refused : fold .none hash code commit release sharedRegistration = false := by decide
/-- Executed acceptance with the one placement guard flipped, not accepted law. -/
theorem shared_registration_mutated : fold (.flip .registrationPlacement) hash code commit release sharedRegistration = true := by decide
/-- Hypothesis instance under #741, not accepted law; exact complete antecedent. -/
abbrev fold_minted_outputs_premise (m : Mutation) (h : Hash) (c : Codec) (t : TrieCommit) (q : Query) : Prop := MintedOutputsPremises m h c t q
/-- Hypothesis instance under #741, not accepted law; exact conclusion. -/
abbrev fold_minted_outputs_claim (m : Mutation) (h : Hash) (c : Codec) (t : TrieCommit) (q : Query) : Prop := MintedOutputsConclusion m h c t q
/-- Executed finite encoding premise for every changed key, not accepted law. -/
theorem fold_roles_encoding : FiniteEncoding code (foldRoleDomain mixed) := by
  intro a ha b hb he
  change a ∈ [Preimage.state seed, .active registryId 7, .active registryId 8] at ha
  change b ∈ [Preimage.state seed, .active registryId 7, .active registryId 8] at hb
  simp only [List.mem_cons, List.mem_nil_iff, or_false] at ha hb
  rcases ha with rfl | rfl | rfl <;> rcases hb with rfl | rfl | rfl
  all_goals first | rfl | exact False.elim ((by decide : _ ≠ _) he)
/-- Executed separate finite collision premise, not accepted law. -/
theorem fold_roles_collision : FiniteCollisionFree hash code (foldRoleDomain mixed) := by
  intro a ha b hb he
  change a ∈ [Preimage.state seed, .active registryId 7, .active registryId 8] at ha
  change b ∈ [Preimage.state seed, .active registryId 7, .active registryId 8] at hb
  simp only [List.mem_cons, List.mem_nil_iff, or_false] at ha hb
  rcases ha with rfl | rfl | rfl <;> rcases hb with rfl | rfl | rfl
  all_goals first | rfl | exact False.elim ((by decide : _ ≠ _) he)
/-- Executed full non-vacuous antecedent on a production-accepted mixed fold, not accepted law. -/
theorem fold_minted_outputs_antecedent : fold_minted_outputs_premise .none hash code commit (goodQuery .batch) :=
  ⟨fold_roles_encoding, fold_roles_collision, by decide⟩
/-- Executed real minted output refusal at the whole-policy boundary, not accepted law. -/
theorem fold_minted_outputs_candidate : fold_minted_outputs_premise .none hash code commit (repairQuery mintedStateFold) → fold_minted_outputs_claim .none hash code commit (repairQuery mintedStateFold) := by
  intro ⟨_, _, accepted⟩
  have refused : fold .none hash code commit release mintedStateFold = false := by decide
  change fold .none hash code commit release mintedStateFold = true at accepted
  rw [refused] at accepted
  cases accepted
/-- Executed single-whole-policy-guard falsification with a recognizable token in the fold's own continuation, not accepted law. -/
theorem fold_minted_outputs_mutant : ¬ (fold_minted_outputs_premise (.flip .foldWholePolicy) hash code commit (repairQuery mintedStateFold) → fold_minted_outputs_claim (.flip .foldWholePolicy) hash code commit (repairQuery mintedStateFold)) := by
  intro claimed
  have prem : fold_minted_outputs_premise (.flip .foldWholePolicy) hash code commit (repairQuery mintedStateFold) :=
    ⟨fold_roles_encoding, fold_roles_collision, by decide⟩
  have result := (claimed prem).2 mixed.after.state (by change mixed.after.state ∈ mixed.after.state :: _; exact List.mem_cons_self) (registryId, 1) (by change (registryId, 1) ∈ [(registryId, 1)]; exact List.mem_cons_self) (by decide) (by decide) (by decide)
  have recognized : recognizeState .none hash code release seed mixed.after.state = true := by decide
  change recognizeState .none hash code release seed mixed.after.state = false at result
  rw [recognized] at result
  cases result


/-- Executed conclusion on the production-accepted mixed fold and its actual output extent, not accepted law. -/
theorem fold_minted_outputs_accepted : fold_minted_outputs_claim .none hash code commit (goodQuery .batch) := by
  refine ⟨by decide, ?_⟩
  intro output member
  change output ∈ [mixed.outputs[0], mixed.outputs[1], mixed.outputs[2]] at member
  simp only [List.mem_cons, List.mem_nil_iff, or_false] at member
  rcases member with rfl | rfl | rfl
  · intro entry member
    change entry ∈ [(registryId, 1)] at member
    simp only [List.mem_cons, List.mem_nil_iff, or_false] at member
    subst entry
    decide
  · intro entry member
    change entry ∈ [(activeAsset hash code registryId 7, 1)] at member
    simp only [List.mem_cons, List.mem_nil_iff, or_false] at member
    subst entry
    decide
  · intro entry member
    change entry ∈ ([] : List (TokenId × Nat)) at member
    cases member


/-- Executed universal frame at the fixed mixed example, using accepted trie-update lemmas, not a general candidate proof. -/
theorem mixed_frame : FoldFrame mixed := by
  intro key outside
  have h7 : key ≠ 7 := by intro eq; subst key; exact outside (by decide)
  have h8 : key ≠ 8 := by intro eq; subst key; exact outside (by decide)
  change trieGet (trieSet (trieSet Fixtures.registry.trie 7 (.known .active)) 8 (.known .terminal)) key =
    trieGet Fixtures.registry.trie key
  rw [trieGet_set_of_ne _ 8 key _ h8, trieGet_set_of_ne _ 7 key _ h7]
/-- Hypothesis fixture under #741, not accepted law; an extra leaf accepted only through the trie guard. -/
def frameAttack : FoldObservation :=
  let trie := trieSet mixed.after.trie 999 (.known .active)
  let state := { mixed.after.state with datum := .root (commit trie) }
  let outputs := state :: mixed.outputs.drop 1
  { mixed with
    after := { mixed.after with trie, state }
    outputs := outputs
    assets := { mixed.assets with outputs := outputs.map (fun output => ⟨output.assets⟩) } }
/-- Hypothesis instance under #741, not accepted law; complete frame premise. -/
abbrev fold_untouched_keys_premise (m : Mutation) (h : Hash) (c : Codec) (t : TrieCommit) (q : Query) : Prop :=
  q.surface = .batch ∧ fold m h c t q.release q.observation = true
/-- Hypothesis instance under #741, not accepted law; exact frame conclusion. -/
abbrev fold_untouched_keys_claim (_m : Mutation) (_h : Hash) (_c : Codec) (_t : TrieCommit) (q : Query) : Prop := FoldFrame q.observation
/-- Executed non-vacuous complete frame antecedent, not accepted law. -/
theorem fold_untouched_keys_antecedent : fold_untouched_keys_premise .none hash code commit (goodQuery .batch) := by decide
/-- Executed positive frame consequence, not accepted law. -/
theorem fold_untouched_keys_accepted : fold_untouched_keys_claim .none hash code commit (goodQuery .batch) := mixed_frame
/-- Executed unmutated frame-boundary refusal, not accepted law. -/
theorem fold_untouched_keys_candidate : fold_untouched_keys_premise .none hash code commit (repairQuery frameAttack) → fold_untouched_keys_claim .none hash code commit (repairQuery frameAttack) := by
  intro ⟨_, accepted⟩
  have refused : fold .none hash code commit release frameAttack = false := by decide
  change fold .none hash code commit release frameAttack = true at accepted
  rw [refused] at accepted
  cases accepted
/-- Executed single-trie-guard frame falsification, not accepted law. -/
theorem fold_untouched_keys_mutant : ¬ (fold_untouched_keys_premise (.flip .foldTrie) hash code commit (repairQuery frameAttack) → fold_untouched_keys_claim (.flip .foldTrie) hash code commit (repairQuery frameAttack)) := by
  intro claimed
  have result := claimed (by decide) 999 (by decide)
  have unequal : trieGet frameAttack.after.trie 999 ≠ trieGet frameAttack.before.trie 999 := by decide
  exact unequal result
/-- Hypothesis instance under #741, not accepted law; complete constructive premise. -/
abbrev public_fold_effects_premise (_m : Mutation) (h : Hash) (c : Codec) (t : TrieCommit) (q : Query) : Prop := PublicPremises h c t q
/-- Hypothesis instance under #741, not accepted law; independent constructive effects. -/
abbrev public_fold_effects_claim (m : Mutation) (h : Hash) (c : Codec) (t : TrieCommit) (q : Query) : Prop :=
  PublicConclusion m h c t q ∧ batchEffects t (buildFold h c t q.release q.observation.before q.requests q.funding) ∧
    FoldFrame (buildFold h c t q.release q.observation.before q.requests q.funding)
/-- Executed complete constructive-effect antecedent, not accepted law. -/
theorem public_fold_effects_antecedent : public_fold_effects_premise .none (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) := public_fold_constructed_antecedent
/-- Executed independent public trie/root effects and frame, not accepted law. -/
theorem public_fold_effects_candidate : public_fold_effects_premise .none (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) → public_fold_effects_claim .none (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) := by
  intro _
  exact ⟨by decide, by decide, mixed_frame⟩
/-- Executed single-whole-policy-guard constructive falsification, not accepted law. -/
theorem public_fold_effects_mutant : ¬ (public_fold_effects_premise (.flip .foldWholePolicy) (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) → public_fold_effects_claim (.flip .foldWholePolicy) (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold)) := by
  intro claimed
  have bad : ¬ PublicConclusion (.flip .foldWholePolicy) (NoPin.lookupHash hashes) (queryCode (goodQuery .publicFold)) (queryCommit (goodQuery .publicFold)) (goodQuery .publicFold) := by decide
  exact bad (claimed public_fold_effects_antecedent).1


/-- Hypothesis boundary controls under #741, not accepted law; actual fold outputs and exact isolated guards. -/
def repairBadQueries : List (String × Query × Guard) :=
  [("two-registrations-share-carrier", repairQuery sharedRegistration, .registrationPlacement),
   ("minted-recognizable-state-in-fold-output", repairQuery mintedStateFold, .foldWholePolicy),
   ("unrelated-key-changed", repairQuery frameAttack, .foldTrie)]

end NoPin.ApplicationRequests.Evidence
