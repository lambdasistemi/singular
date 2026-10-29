import SingularApplicationHeld.ReaderStatements

/-! Neutral custody guarantees and the application refinement boundary. -/
namespace SingularApplicationHeld.NeutralReaderStatements
open Singular SingularApplicationHeld

set_option maxHeartbeats 2000000
set_option maxRecDepth 8192

local instance : LawfulBEq TokenId where
  eq_of_beq := Proofs.token_eq _ _
  rfl := by intro a; cases a; simp

local instance : LawfulBEq ApplicationParameters where
  eq_of_beq := by intro a b same; cases a; cases b; simp_all [reduceBEq]
  rfl := by intro a; cases a; simp [reduceBEq]

local instance : LawfulBEq OutputDatum where
  eq_of_beq := by intro a b same; cases a <;> cases b <;> simp_all [reduceBEq]
  rfl := by intro a; cases a <;> simp [reduceBEq]

/-- Exactly the evidence for an active custody answer, without a decoder. -/
theorem active_inversion (h : Hash) (c : Codec) (t : TrieCommit)
    (request : ReaderRequest) (observed : ReaderObservation) (output : ObservedOutput) :
    readNeutralKey h c t request observed = .active output ↔
    ∃ release,
      observed.network = .complete request.network ∧ observed.release = some release ∧
      request.registry.policy = release.statePolicy ∧ observed.activeOutputs = .complete [output] ∧
      quantity output (activeAsset h c request.registry request.key) = 1 ∧
      output.credential = release.applicationCredential ∧ output.credential ≠ request.registry.policy := by
  constructor
  · intro answer
    simp only [readNeutralKey, bind, pure, Id.run] at answer
    all_goals repeat' (split at answer <;> try simp_all)
    all_goals grind
  · rintro ⟨release, network, published, policy, outputs, one, custody, notState⟩
    have distinct : release.applicationCredential ≠ release.statePolicy := by simpa [custody, policy] using notState
    simp [readNeutralKey, network, published, policy, outputs, one, custody, distinct]

/-- Reachable supply makes the custody answer an active leaf of this key. -/
theorem active_sound (h : Hash) (c : Codec) (t : TrieCommit)
    (release : PublishedRelease) (world : CandidateWorld) (registry : PublicRegistry)
    (network : Nat) (key : Key) (observed : ReaderObservation) (output : ObservedOutput)
    (_history : HistoryPremises h c t release world registry key)
    (_evidence : ReaderEvidenceCorrespondence h c world registry key observed)
    (_release : observed.release = some release)
    (_answer : readNeutralKey h c t ⟨network, registry.identity, key⟩ observed = .active output) :
    trieGet registry.trie key = .known .active ∧ output ∈ world.unspent ∧
    output.credential = release.applicationCredential ∧ output.credential ≠ registry.identity.policy ∧
    quantity output (activeAsset h c registry.identity key) = 1 := by
  obtain ⟨published, networkSeen, publishedSeen, policy, outputs, one, custody, notState⟩ :=
    (active_inversion h c t ⟨network, registry.identity, key⟩ observed output).mp _answer
  have same : published = release := Option.some.inj (publishedSeen.symm.trans _release)
  subst published
  have complete := _evidence.1 [output] outputs
  have filtered : output ∈ world.unspent.filter
      (fun candidate => quantity candidate (activeAsset h c registry.identity key) > 0) := by
    rw [← complete]
    simp
  have member := (List.mem_filter.mp filtered).1
  have positive : 0 < liveActiveCount h c registry.identity key world.unspent := by
    apply Nat.sum_pos_iff_exists_pos.mpr
    exact ⟨1, List.mem_map.mpr ⟨output, member, one⟩, by decide⟩
  have supply := HistoryStatements.supply_in_step h c t release world registry key _history
  have active : trieGet registry.trie key = .known .active := by
    by_cases present : trieGet registry.trie key = .known .active
    · exact present
    · simp only [SupplyAt, present, ↓reduceIte] at supply
      omega
  exact ⟨active, member, custody, notState, one⟩

theorem terminal_inversion (h : Hash) (c : Codec) (t : TrieCommit)
    (request : ReaderRequest) (observed : ReaderObservation) (state : ReaderState) :
    readNeutralKey h c t request observed = .terminal state ↔
    ∃ release,
      observed.network = .complete request.network ∧ observed.release = some release ∧
      request.registry.policy = release.statePolicy ∧ observed.activeOutputs = .complete [] ∧
      observed.state = .complete (some state.output) ∧ observed.trie = .complete state.trie ∧
      recognizeReaderState release request.registry state.output = true ∧
      state.output.datum = .root (t state.trie) ∧ trieGet state.trie request.key = .known .terminal := by
  constructor
  · intro answer
    simp only [readNeutralKey, bind, pure, Id.run] at answer
    all_goals repeat' (split at answer <;> try simp_all)
    all_goals grind
  · rintro ⟨release, network, published, policy, outputs, seen, trie, recognised, root, leaf⟩
    simp [readNeutralKey, network, published, policy, outputs, seen, trie, recognised, root, leaf]

theorem never_registered_inversion (h : Hash) (c : Codec) (t : TrieCommit)
    (request : ReaderRequest) (observed : ReaderObservation)
    (state : ReaderState) :
    readNeutralKey h c t request observed = .neverRegistered state ↔
    ∃ release,
      observed.network = .complete request.network ∧ observed.release = some release ∧
      request.registry.policy = release.statePolicy ∧ observed.activeOutputs = .complete [] ∧
      observed.state = .complete (some state.output) ∧ observed.trie = .complete state.trie ∧
      recognizeReaderState release request.registry state.output = true ∧
      state.output.datum = .root (t state.trie) ∧ trieGet state.trie request.key = .unknown := by
  constructor
  · intro answer
    simp only [readNeutralKey, bind, pure, Id.run] at answer
    all_goals repeat' (split at answer <;> try simp_all)
    all_goals grind
  · rintro ⟨release, network, published, policy, outputs, seen, trie, recognised, root, leaf⟩
    simp [readNeutralKey, network, published, policy, outputs, seen, trie, recognised, root, leaf]

theorem terminal_sound (h : Hash) (c : Codec) (t : TrieCommit)
    (release : PublishedRelease) (world : CandidateWorld) (registry : PublicRegistry)
    (network : Nat) (key : Key) (observed : ReaderObservation) (state : ReaderState)
    (_history : HistoryPremises h c t release world registry key)
    (_evidence : ReaderEvidenceCorrespondence h c world registry key observed)
    (_answer : readNeutralKey h c t ⟨network, registry.identity, key⟩ observed = .terminal state) :
    state.output = registry.state ∧ state.trie = registry.trie ∧
    trieGet registry.trie key = .known .terminal := by
  apply ReaderStatements.terminal_sound h c t (fun _ => none) release world registry network key observed state
    _history _evidence
  simp [readKey, _answer, refineReaderAnswer]

theorem never_registered_sound (h : Hash) (c : Codec) (t : TrieCommit)
    (release : PublishedRelease) (world : CandidateWorld) (registry : PublicRegistry)
    (network : Nat) (key : Key) (observed : ReaderObservation) (state : ReaderState)
    (_history : HistoryPremises h c t release world registry key)
    (_evidence : ReaderEvidenceCorrespondence h c world registry key observed)
    (_answer : readNeutralKey h c t ⟨network, registry.identity, key⟩ observed = .neverRegistered state) :
    state.output = registry.state ∧ state.trie = registry.trie ∧ trieGet registry.trie key = .unknown := by
  apply ReaderStatements.never_registered_sound h c t (fun _ => none) release world registry network key observed state
    _history _evidence
  simp [readKey, _answer, refineReaderAnswer]

theorem no_absence_from_missing_evidence (h : Hash) (c : Codec) (t : TrieCommit)
    (request : ReaderRequest) (observed : ReaderObservation)
    (_missing : observed.network = .missing ∨
      (∀ magic, observed.network ≠ .complete magic) ∨
      (∀ outputs, observed.activeOutputs ≠ .complete outputs) ∨
      (((∀ output, observed.state ≠ .complete (some output)) ∨
        (∀ trie, observed.trie ≠ .complete trie)) ∧ observed.activeOutputs = .complete [])) :
    (readNeutralKey h c t request observed).isAbsence = false := by
  cases answer : readNeutralKey h c t request observed with
  | active output => rfl
  | unavailable read reason => rfl
  | refused reason => rfl
  | terminal state =>
    obtain ⟨release, networkSeen, published, policy, outputs, stateSeen, trieSeen, recognised, root, leaf⟩ :=
      (terminal_inversion h c t request observed state).mp answer
    rcases _missing with missing | noNetwork | noOutputs | ⟨noState | noTrie, empty⟩
    · simp_all
    · exact False.elim (noNetwork request.network networkSeen)
    · exact False.elim (noOutputs [] outputs)
    · exact False.elim (noState state.output stateSeen)
    · exact False.elim (noTrie state.trie trieSeen)
  | neverRegistered state =>
    obtain ⟨release, networkSeen, published, policy, outputs, stateSeen, trieSeen, recognised, root, leaf⟩ :=
      (never_registered_inversion h c t request observed state).mp answer
    rcases _missing with missing | noNetwork | noOutputs | ⟨noState | noTrie, empty⟩
    · simp_all
    · exact False.elim (noNetwork request.network networkSeen)
    · exact False.elim (noOutputs [] outputs)
    · exact False.elim (noState state.output stateSeen)
    · exact False.elim (noTrie state.trie trieSeen)

theorem network_unavailable (h : Hash) (c : Codec) (t : TrieCommit)
    (request : ReaderRequest) (observed : ReaderObservation)
    (reason : ReaderUnavailable) (_failure : observed.network.unavailableReason = some reason) :
    readNeutralKey h c t request observed = .unavailable .network reason := by
  cases answer : observed.network <;> simp_all [readNeutralKey, ReaderRead.unavailableReason]

theorem active_outputs_unavailable (h : Hash) (c : Codec) (t : TrieCommit)
    (request : ReaderRequest) (observed : ReaderObservation)
    (release : PublishedRelease) (reason : ReaderUnavailable)
    (_network : observed.network = .complete request.network) (_release : observed.release = some release)
    (_policy : request.registry.policy = release.statePolicy)
    (_failure : observed.activeOutputs.unavailableReason = some reason) :
    readNeutralKey h c t request observed = .unavailable .activeOutputs reason := by
  cases answer : observed.activeOutputs <;> simp_all [readNeutralKey, ReaderRead.unavailableReason]

theorem state_unavailable (h : Hash) (c : Codec) (t : TrieCommit)
    (request : ReaderRequest) (observed : ReaderObservation)
    (release : PublishedRelease) (reason : ReaderUnavailable)
    (_network : observed.network = .complete request.network) (_release : observed.release = some release)
    (_policy : request.registry.policy = release.statePolicy) (_outputs : observed.activeOutputs = .complete [])
    (_failure : observed.state.unavailableReason = some reason) :
    readNeutralKey h c t request observed = .unavailable .state reason := by
  cases answer : observed.state <;> simp_all [readNeutralKey, ReaderRead.unavailableReason]

theorem trie_unavailable (h : Hash) (c : Codec) (t : TrieCommit)
    (request : ReaderRequest) (observed : ReaderObservation)
    (release : PublishedRelease) (output : ObservedOutput) (reason : ReaderUnavailable)
    (_network : observed.network = .complete request.network) (_release : observed.release = some release)
    (_policy : request.registry.policy = release.statePolicy) (_outputs : observed.activeOutputs = .complete [])
    (_state : observed.state = .complete (some output))
    (_recognised : recognizeReaderState release request.registry output = true)
    (_failure : observed.trie.unavailableReason = some reason) :
    readNeutralKey h c t request observed = .unavailable .trie reason := by
  cases answer : observed.trie <;> simp_all [readNeutralKey, ReaderRead.unavailableReason]

theorem wrong_network_first (h : Hash) (c : Codec) (t : TrieCommit)
    (request : ReaderRequest) (observed : ReaderObservation)
    (served : Nat) (_network : observed.network = .complete served)
    (_different : served ≠ request.network) :
    readNeutralKey h c t request observed = .refused (.wrongNetwork request.network served) := by
  simp_all [readNeutralKey]

theorem unknown_state_policy (h : Hash) (c : Codec) (t : TrieCommit)
    (request : ReaderRequest) (observed : ReaderObservation)
    (_network : observed.network = .complete request.network) (_release : observed.release = none) :
    readNeutralKey h c t request observed = .refused (.unknownStatePolicy request.registry.policy) := by
  simp_all [readNeutralKey]

theorem foreign_state_policy (h : Hash) (c : Codec) (t : TrieCommit)
    (request : ReaderRequest) (observed : ReaderObservation)
    (release : PublishedRelease) (_network : observed.network = .complete request.network)
    (_release : observed.release = some release) (_foreign : request.registry.policy ≠ release.statePolicy) :
    readNeutralKey h c t request observed =
      .refused (.foreignStatePolicy request.registry.policy release.statePolicy) := by
  simp_all [readNeutralKey]

theorem token_outside_custody (h : Hash) (c : Codec) (t : TrieCommit)
    (request : ReaderRequest) (observed : ReaderObservation)
    (release : PublishedRelease) (output : ObservedOutput)
    (_network : observed.network = .complete request.network) (_release : observed.release = some release)
    (_policy : request.registry.policy = release.statePolicy) (_outputs : observed.activeOutputs = .complete [output])
    (_quantity : quantity output (activeAsset h c request.registry request.key) = 1)
    (_outside : output.credential ≠ release.applicationCredential ∨ output.credential = request.registry.policy) :
    readNeutralKey h c t request observed =
      .refused (.tokenOutsideApplicationCustody output.reference output.credential) := by
  rcases _outside with outside | atState
  · simp_all [readNeutralKey]
  · simp_all [readNeutralKey]

theorem conflicting_outputs (h : Hash) (c : Codec) (t : TrieCommit)
    (request : ReaderRequest) (observed : ReaderObservation)
    (release : PublishedRelease) (outputs : List ObservedOutput)
    (_network : observed.network = .complete request.network) (_release : observed.release = some release)
    (_policy : request.registry.policy = release.statePolicy) (_outputs : observed.activeOutputs = .complete outputs)
    (_multiple : 1 < outputs.length) :
    readNeutralKey h c t request observed = .refused .conflictingEvidence := by
  cases outputs with
  | nil => simp_all
  | cons first rest =>
    cases rest with
    | nil => simp_all
    | cons second rest => simp_all [readNeutralKey]

theorem conflicting_quantity (h : Hash) (c : Codec) (t : TrieCommit)
    (request : ReaderRequest) (observed : ReaderObservation)
    (release : PublishedRelease) (output : ObservedOutput)
    (_network : observed.network = .complete request.network) (_release : observed.release = some release)
    (_policy : request.registry.policy = release.statePolicy) (_outputs : observed.activeOutputs = .complete [output])
    (_quantity : quantity output (activeAsset h c request.registry request.key) ≠ 1) :
    readNeutralKey h c t request observed = .refused .conflictingEvidence := by
  simp_all [readNeutralKey]

theorem state_not_found (h : Hash) (c : Codec) (t : TrieCommit)
    (request : ReaderRequest) (observed : ReaderObservation)
    (release : PublishedRelease)
    (_network : observed.network = .complete request.network) (_release : observed.release = some release)
    (_policy : request.registry.policy = release.statePolicy) (_outputs : observed.activeOutputs = .complete [])
    (_state : observed.state = .complete none) :
    readNeutralKey h c t request observed = .unavailable .state .stateNotFound := by
  simp_all [readNeutralKey]

theorem state_not_recognized (h : Hash) (c : Codec) (t : TrieCommit)
    (request : ReaderRequest) (observed : ReaderObservation)
    (release : PublishedRelease) (output : ObservedOutput)
    (_network : observed.network = .complete request.network) (_release : observed.release = some release)
    (_policy : request.registry.policy = release.statePolicy) (_outputs : observed.activeOutputs = .complete [])
    (_state : observed.state = .complete (some output))
    (_unrecognised : recognizeReaderState release request.registry output = false) :
    readNeutralKey h c t request observed = .unavailable .state .stateNotRecognized := by
  simp_all [readNeutralKey]

theorem trie_root_mismatch (h : Hash) (c : Codec) (t : TrieCommit)
    (request : ReaderRequest) (observed : ReaderObservation)
    (release : PublishedRelease) (output : ObservedOutput) (trie : Trie)
    (_network : observed.network = .complete request.network) (_release : observed.release = some release)
    (_policy : request.registry.policy = release.statePolicy) (_outputs : observed.activeOutputs = .complete [])
    (_state : observed.state = .complete (some output))
    (_recognised : recognizeReaderState release request.registry output = true)
    (_trie : observed.trie = .complete trie) (_mismatch : output.datum ≠ .root (t trie)) :
    readNeutralKey h c t request observed = .unavailable .trie .trieRootMismatch := by
  simp_all [readNeutralKey]

theorem known_nonterminal_leaf_without_token (h : Hash) (c : Codec) (t : TrieCommit)
    (request : ReaderRequest) (observed : ReaderObservation)
    (release : PublishedRelease) (output : ObservedOutput) (trie : Trie) (leaf : State)
    (_network : observed.network = .complete request.network) (_release : observed.release = some release)
    (_policy : request.registry.policy = release.statePolicy) (_outputs : observed.activeOutputs = .complete [])
    (_state : observed.state = .complete (some output))
    (_recognised : recognizeReaderState release request.registry output = true)
    (_trie : observed.trie = .complete trie) (_root : output.datum = .root (t trie))
    (_leaf : trieGet trie request.key = .known leaf) (_notTerminal : leaf ≠ .terminal) :
    readNeutralKey h c t request observed = .refused .conflictingEvidence := by
  cases leaf <;> simp_all [readNeutralKey]

/-- An active custody result needs neither state nor trie observations. -/
theorem holding_answer_ignores_state (h : Hash) (c : Codec) (t : TrieCommit)
    (request : ReaderRequest) (observed : ReaderObservation)
    (state : ReaderRead (Option ObservedOutput)) (trie : ReaderRead Trie)
    (_holding : ∃ output, readNeutralKey h c t request observed = .active output) :
    readNeutralKey h c t request {observed with state, trie} =
      readNeutralKey h c t request observed := by
  obtain ⟨output, active⟩ := _holding
  rw [active]
  apply (active_inversion h c t request {observed with state, trie} output).mpr
  exact (active_inversion h c t request observed output).mp active

/-- The two readers share the same observations; only active custody is refined. -/
theorem application_refines_neutral (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (request : ReaderRequest) (observed : ReaderObservation) :
    readKey h c t decode request observed =
      refineReaderAnswer h c decode request observed.release (readNeutralKey h c t request observed) := by
  rfl

/-- The application keeps the neutral refusal result exactly. -/
theorem application_keeps_refusal (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (request : ReaderRequest) (observed : ReaderObservation)
    (reason : ReaderRefusal) (_neutral : readNeutralKey h c t request observed = .refused reason) :
    readKey h c t decode request observed = .refused reason := by
  simp [readKey, _neutral, refineReaderAnswer]

/-- The application keeps the neutral unavailable result exactly. -/
theorem application_keeps_unavailable (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (request : ReaderRequest) (observed : ReaderObservation)
    (read : ReaderReadName) (reason : ReaderUnavailable) (_neutral : readNeutralKey h c t request observed = .unavailable read reason) :
    readKey h c t decode request observed = .unavailable read reason := by
  simp [readKey, _neutral, refineReaderAnswer]

/-- The application keeps the neutral terminal result exactly. -/
theorem application_keeps_terminal (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (request : ReaderRequest) (observed : ReaderObservation)
    (state : ReaderState) (_neutral : readNeutralKey h c t request observed = .terminal state) :
    readKey h c t decode request observed = .terminal state := by
  simp [readKey, _neutral, refineReaderAnswer]

/-- The application keeps the neutral never registered result exactly. -/
theorem application_keeps_never_registered (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (request : ReaderRequest) (observed : ReaderObservation)
    (state : ReaderState) (_neutral : readNeutralKey h c t request observed = .neverRegistered state) :
    readKey h c t decode request observed = .neverRegistered state := by
  simp [readKey, _neutral, refineReaderAnswer]

end SingularApplicationHeld.NeutralReaderStatements
