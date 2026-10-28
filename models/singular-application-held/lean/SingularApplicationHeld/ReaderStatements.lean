import SingularApplicationHeld.Reader

/-! Reader guarantees over observed evidence. -/
namespace SingularApplicationHeld.ReaderStatements
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

/-- Recognition by a known registry identity is the existing state recognition. -/
theorem state_recognition (h : Hash) (c : Codec) (release : PublishedRelease)
    (seed : OutRef) (output : ObservedOutput) :
    recognizeReaderState release (stateAsset h c release seed) output =
      recognizeState .none h c release seed output := by
  apply Bool.eq_iff_iff.mpr
  rcases output with ⟨reference, credential, value, datum, assets⟩
  cases assets with
  | nil => simp [recognizeReaderState, recognizeState, Proofs.applyGuard_none]
  | cons entry rest =>
    rcases entry with ⟨⟨policy, name⟩, amount⟩
    cases rest <;> simp [recognizeReaderState, recognizeState, Proofs.applyGuard_none,
      stateAsset, Bool.and_eq_true, and_assoc]
    all_goals intros <;> rfl

/-- Exact evidence permitting the live branch; the state is not an input to it. -/
theorem live_inversion (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (request : ReaderRequest) (observed : ReaderObservation) (output : ObservedOutput) :
    readKey h c t decode request observed = .live output ↔
    ∃ release control payload,
      observed.network = .complete request.network ∧ observed.release = some release ∧
      request.registry.policy = release.statePolicy ∧ observed.activeOutputs = .complete [output] ∧
      quantity output (activeAsset h c request.registry request.key) = 1 ∧
      output.credential = release.applicationCredential ∧ output.credential ≠ request.registry.policy ∧
      terminationShape .none h c release output request.registry request.key = false ∧
      decoded decode output = some (.live control payload) ∧
      control.registry = request.registry ∧ control.key = request.key ∧
      control.activeAsset = activeAsset h c request.registry request.key ∧
      control.deposit ≤ output.lovelace := by
  constructor
  · intro answer
    simp only [readKey, bind, pure, Id.run] at answer
    all_goals repeat' (split at answer <;> try simp_all [and_assoc])
    all_goals grind
  · rintro ⟨release, control, payload, network, published, policy, outputs, one,
      custody, notState, pending, decoding, registry, key, asset, deposit⟩
    have distinct : release.applicationCredential ≠ release.statePolicy := by simpa [custody, policy] using notState
    simp [readKey, network, published, policy, outputs, one, custody, distinct,
      pending, decoding, registry, key, asset, deposit]

/-- Pending is the application's exact termination request, including its active token. -/
theorem pending_termination_inversion (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (request : ReaderRequest) (observed : ReaderObservation)
    (output : ObservedOutput) :
    readKey h c t decode request observed = .pendingTermination output ↔
    ∃ release,
      observed.network = .complete request.network ∧ observed.release = some release ∧
      request.registry.policy = release.statePolicy ∧ observed.activeOutputs = .complete [output] ∧
      quantity output (activeAsset h c request.registry request.key) = 1 ∧
      output.credential = release.applicationCredential ∧ output.credential ≠ request.registry.policy ∧
      terminationShape .none h c release output request.registry request.key = true := by
  constructor
  · intro answer
    simp only [readKey, bind, pure, Id.run] at answer
    all_goals repeat' (split at answer <;> try simp_all [and_assoc])
    all_goals grind
  · rintro ⟨release, network, published, policy, outputs, one, custody, notState, pending⟩
    have distinct : release.applicationCredential ≠ release.statePolicy := by simpa [custody, policy] using notState
    simp [readKey, network, published, policy, outputs, one, custody, distinct, pending]

/-- Terminal needs both a recognised state and the key's terminal trie lookup. -/
theorem terminal_inversion (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (request : ReaderRequest) (observed : ReaderObservation) (state : ReaderState) :
    readKey h c t decode request observed = .terminal state ↔
    ∃ release,
      observed.network = .complete request.network ∧ observed.release = some release ∧
      request.registry.policy = release.statePolicy ∧ observed.activeOutputs = .complete [] ∧
      observed.state = .complete (some state.output) ∧ observed.trie = .complete state.trie ∧
      recognizeReaderState release request.registry state.output = true ∧
      state.output.datum = .root (t state.trie) ∧ trieGet state.trie request.key = .known .terminal := by
  constructor
  · intro answer
    simp only [readKey, bind, pure, Id.run] at answer
    all_goals repeat' (split at answer <;> try simp_all [and_assoc])
    all_goals grind
  · rintro ⟨release, network, published, policy, outputs, seen, trie, recognised, root, leaf⟩
    simp [readKey, network, published, policy, outputs, seen, trie, recognised, root, leaf]

/-- Unknown is a lookup in the recognised state's trie, never an empty asset answer. -/
theorem never_registered_inversion (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (request : ReaderRequest) (observed : ReaderObservation)
    (state : ReaderState) :
    readKey h c t decode request observed = .neverRegistered state ↔
    ∃ release,
      observed.network = .complete request.network ∧ observed.release = some release ∧
      request.registry.policy = release.statePolicy ∧ observed.activeOutputs = .complete [] ∧
      observed.state = .complete (some state.output) ∧ observed.trie = .complete state.trie ∧
      recognizeReaderState release request.registry state.output = true ∧
      state.output.datum = .root (t state.trie) ∧ trieGet state.trie request.key = .unknown := by
  constructor
  · intro answer
    simp only [readKey, bind, pure, Id.run] at answer
    all_goals repeat' (split at answer <;> try simp_all [and_assoc])
    all_goals grind
  · rintro ⟨release, network, published, policy, outputs, seen, trie, recognised, root, leaf⟩
    simp [readKey, network, published, policy, outputs, seen, trie, recognised, root, leaf]

private theorem token_implies_active (h : Hash) (c : Codec) (t : TrieCommit)
    (release : PublishedRelease) (world : CandidateWorld) (registry : PublicRegistry)
    (key : Key) (observed : ReaderObservation) (output : ObservedOutput)
    (history : HistoryPremises h c t release world registry key)
    (evidence : ReaderEvidenceCorrespondence h c world registry key observed)
    (outputs : observed.activeOutputs = .complete [output])
    (one : quantity output (activeAsset h c registry.identity key) = 1) :
    trieGet registry.trie key = .known .active ∧ output ∈ world.unspent := by
  have complete := evidence.1 [output] outputs
  have filtered : output ∈ world.unspent.filter
      (fun candidate => quantity candidate (activeAsset h c registry.identity key) > 0) := by
    rw [← complete]
    simp
  have member := (List.mem_filter.mp filtered).1
  have positive : 0 < liveActiveCount h c registry.identity key world.unspent := by
    apply Nat.sum_pos_iff_exists_pos.mpr
    exact ⟨1, List.mem_map.mpr ⟨output, member, one⟩, by decide⟩
  have supply := HistoryStatements.supply_in_step h c t release world registry key history
  have active : trieGet registry.trie key = .known .active := by
    by_cases present : trieGet registry.trie key = .known .active
    · exact present
    · simp only [SupplyAt, present, ↓reduceIte] at supply
      omega
  exact ⟨active, member⟩

/-- In every reachable world a live answer has an active leaf and genuine custody. -/
theorem live_sound (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (world : CandidateWorld) (registry : PublicRegistry)
    (network : Nat) (key : Key) (observed : ReaderObservation) (output : ObservedOutput)
    (_history : HistoryPremises h c t release world registry key)
    (_evidence : ReaderEvidenceCorrespondence h c world registry key observed)
    (_release : observed.release = some release)
    (_answer : readKey h c t decode ⟨network, registry.identity, key⟩ observed = .live output) :
    trieGet registry.trie key = .known .active ∧ output ∈ world.unspent ∧
    output.credential = release.applicationCredential ∧
    quantity output (activeAsset h c registry.identity key) = 1 ∧
    ∃ control payload, decoded decode output = some (.live control payload) ∧
      control.registry = registry.identity ∧ control.key = key ∧
      control.activeAsset = activeAsset h c registry.identity key ∧
      control.deposit ≤ output.lovelace := by
  obtain ⟨actual, control, payload, networkSeen, published, policy, outputs, one,
    custody, notState, pending, decoding, registryBinding, keyBinding, assetBinding, deposit⟩ :=
      (live_inversion h c t decode ⟨network, registry.identity, key⟩ observed output).mp _answer
  have same : actual = release := Option.some.inj (published.symm.trans _release)
  subst actual
  have result := token_implies_active h c t release world registry key observed output _history _evidence outputs one
  exact ⟨result.1, result.2, custody, one, control, payload, decoding,
    registryBinding, keyBinding, assetBinding, deposit⟩

/-- Booking does not turn the leaf terminal; its token stays in this key's request. -/
theorem pending_termination_sound (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (release : PublishedRelease) (world : CandidateWorld)
    (registry : PublicRegistry) (network : Nat) (key : Key) (observed : ReaderObservation)
    (output : ObservedOutput)
    (_history : HistoryPremises h c t release world registry key)
    (_evidence : ReaderEvidenceCorrespondence h c world registry key observed)
    (_release : observed.release = some release)
    (_answer : readKey h c t decode ⟨network, registry.identity, key⟩ observed = .pendingTermination output) :
    trieGet registry.trie key = .known .active ∧ output ∈ world.unspent ∧
    terminationShape .none h c release output registry.identity key = true := by
  obtain ⟨actual, networkSeen, published, policy, outputs, one, custody, notState, pending⟩ :=
    (pending_termination_inversion h c t decode ⟨network, registry.identity, key⟩ observed output).mp _answer
  have same : actual = release := Option.some.inj (published.symm.trans _release)
  subst actual
  have result := token_implies_active h c t release world registry key observed output _history _evidence outputs one
  exact ⟨result.1, result.2, pending⟩

/-- State and lookup correspondence bind the returned terminal leaf to the reachable world. -/
theorem terminal_sound (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (world : CandidateWorld) (registry : PublicRegistry)
    (network : Nat) (key : Key) (observed : ReaderObservation) (state : ReaderState)
    (_history : HistoryPremises h c t release world registry key)
    (_evidence : ReaderEvidenceCorrespondence h c world registry key observed)
    (_answer : readKey h c t decode ⟨network, registry.identity, key⟩ observed = .terminal state) :
    state.output = registry.state ∧ state.trie = registry.trie ∧
    trieGet registry.trie key = .known .terminal := by
  obtain ⟨actual, networkSeen, published, policy, outputs, stateSeen, trieSeen, recognised, root, leaf⟩ :=
    (terminal_inversion h c t decode ⟨network, registry.identity, key⟩ observed state).mp _answer
  have stateEqual := _evidence.2.1 state.output stateSeen
  have trieEqual := _evidence.2.2 state.trie trieSeen
  exact ⟨stateEqual, trieEqual, by simpa [trieEqual] using leaf⟩

/-- A never-registered conclusion means this key is unknown in the reachable trie. -/
theorem never_registered_sound (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (world : CandidateWorld) (registry : PublicRegistry)
    (network : Nat) (key : Key) (observed : ReaderObservation) (state : ReaderState)
    (_history : HistoryPremises h c t release world registry key)
    (_evidence : ReaderEvidenceCorrespondence h c world registry key observed)
    (_answer : readKey h c t decode ⟨network, registry.identity, key⟩ observed = .neverRegistered state) :
    state.output = registry.state ∧ state.trie = registry.trie ∧ trieGet registry.trie key = .unknown := by
  obtain ⟨actual, networkSeen, published, policy, outputs, stateSeen, trieSeen, recognised, root, leaf⟩ :=
    (never_registered_inversion h c t decode ⟨network, registry.identity, key⟩ observed state).mp _answer
  have stateEqual := _evidence.2.1 state.output stateSeen
  have trieEqual := _evidence.2.2 state.trie trieSeen
  exact ⟨stateEqual, trieEqual, by simpa [trieEqual] using leaf⟩

/-- Missing or failed observations never supply either negative conclusion. -/
theorem no_absence_from_missing_evidence (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (request : ReaderRequest) (observed : ReaderObservation)
    (_missing : observed.network = .missing ∨
      (∀ magic, observed.network ≠ .complete magic) ∨
      (∀ outputs, observed.activeOutputs ≠ .complete outputs) ∨
      (((∀ output, observed.state ≠ .complete (some output)) ∨
        (∀ trie, observed.trie ≠ .complete trie)) ∧ observed.activeOutputs = .complete [])) :
    (readKey h c t decode request observed).isAbsence = false := by
  cases answer : readKey h c t decode request observed with
  | live output => rfl
  | pendingTermination output => rfl
  | unavailable read reason => rfl
  | refused reason => rfl
  | terminal state =>
    obtain ⟨release, networkSeen, published, policy, outputs, stateSeen, trieSeen, recognised, root, leaf⟩ :=
      (terminal_inversion h c t decode request observed state).mp answer
    rcases _missing with missing | noNetwork | noOutputs | ⟨noState | noTrie, empty⟩
    · simp_all
    · exact False.elim (noNetwork request.network networkSeen)
    · exact False.elim (noOutputs [] outputs)
    · exact False.elim (noState state.output stateSeen)
    · exact False.elim (noTrie state.trie trieSeen)
  | neverRegistered state =>
    obtain ⟨release, networkSeen, published, policy, outputs, stateSeen, trieSeen, recognised, root, leaf⟩ :=
      (never_registered_inversion h c t decode request observed state).mp answer
    rcases _missing with missing | noNetwork | noOutputs | ⟨noState | noTrie, empty⟩
    · simp_all
    · exact False.elim (noNetwork request.network networkSeen)
    · exact False.elim (noOutputs [] outputs)
    · exact False.elim (noState state.output stateSeen)
    · exact False.elim (noTrie state.trie trieSeen)

/-- Failed, missing and incomplete network answers retain their read name and reason. -/
theorem network_unavailable (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (request : ReaderRequest) (observed : ReaderObservation)
    (reason : ReaderUnavailable) (_failure : observed.network.unavailableReason = some reason) :
    readKey h c t decode request observed = .unavailable .network reason := by
  cases answer : observed.network <;> simp_all [readKey, ReaderRead.unavailableReason]

/-- A failed active-token lookup is unavailable, not a negative lookup. -/
theorem active_outputs_unavailable (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (request : ReaderRequest) (observed : ReaderObservation)
    (release : PublishedRelease) (reason : ReaderUnavailable)
    (_network : observed.network = .complete request.network) (_release : observed.release = some release)
    (_policy : request.registry.policy = release.statePolicy)
    (_failure : observed.activeOutputs.unavailableReason = some reason) :
    readKey h c t decode request observed = .unavailable .activeOutputs reason := by
  cases answer : observed.activeOutputs <;> simp_all [readKey, ReaderRead.unavailableReason]

/-- The state read's failure remains named after an empty complete asset answer. -/
theorem state_unavailable (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (request : ReaderRequest) (observed : ReaderObservation)
    (release : PublishedRelease) (reason : ReaderUnavailable)
    (_network : observed.network = .complete request.network) (_release : observed.release = some release)
    (_policy : request.registry.policy = release.statePolicy) (_outputs : observed.activeOutputs = .complete [])
    (_failure : observed.state.unavailableReason = some reason) :
    readKey h c t decode request observed = .unavailable .state reason := by
  cases answer : observed.state <;> simp_all [readKey, ReaderRead.unavailableReason]

/-- A recognised state cannot turn a failed trie read into an absence. -/
theorem trie_unavailable (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (request : ReaderRequest) (observed : ReaderObservation)
    (release : PublishedRelease) (output : ObservedOutput) (reason : ReaderUnavailable)
    (_network : observed.network = .complete request.network) (_release : observed.release = some release)
    (_policy : request.registry.policy = release.statePolicy) (_outputs : observed.activeOutputs = .complete [])
    (_state : observed.state = .complete (some output))
    (_recognised : recognizeReaderState release request.registry output = true)
    (_failure : observed.trie.unavailableReason = some reason) :
    readKey h c t decode request observed = .unavailable .trie reason := by
  cases answer : observed.trie <;> simp_all [readKey, ReaderRead.unavailableReason]

/-- Live and pending answers need no state or trie read. -/
theorem holding_answer_ignores_state (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (request : ReaderRequest) (observed : ReaderObservation)
    (state : ReaderRead (Option ObservedOutput)) (trie : ReaderRead Trie)
    (_holding : ∃ output, readKey h c t decode request observed = .live output ∨
      readKey h c t decode request observed = .pendingTermination output) :
    readKey h c t decode request {observed with state, trie} =
      readKey h c t decode request observed := by
  obtain ⟨output, live | pending⟩ := _holding
  · rw [live]
    apply (live_inversion h c t decode request {observed with state, trie} output).mpr
    exact (live_inversion h c t decode request observed output).mp live
  · rw [pending]
    apply (pending_termination_inversion h c t decode request {observed with state, trie} output).mpr
    exact (pending_termination_inversion h c t decode request observed output).mp pending

/-- The network answer has precedence over every later observation. -/
theorem wrong_network_first (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (request : ReaderRequest) (observed : ReaderObservation)
    (served : Nat) (_network : observed.network = .complete served)
    (_different : served ≠ request.network) :
    readKey h c t decode request observed = .refused (.wrongNetwork request.network served) := by
  simp_all [readKey]

/-- An unpublished policy is refused before looking for the active token. -/
theorem unknown_state_policy (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (request : ReaderRequest) (observed : ReaderObservation)
    (_network : observed.network = .complete request.network) (_release : observed.release = none) :
    readKey h c t decode request observed = .refused (.unknownStatePolicy request.registry.policy) := by
  simp_all [readKey]

/-- A release for another state policy cannot authorize a conclusion. -/
theorem foreign_state_policy (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (request : ReaderRequest) (observed : ReaderObservation)
    (release : PublishedRelease) (_network : observed.network = .complete request.network)
    (_release : observed.release = some release) (_foreign : request.registry.policy ≠ release.statePolicy) :
    readKey h c t decode request observed =
      .refused (.foreignStatePolicy request.registry.policy release.statePolicy) := by
  simp_all [readKey]

/-- Even a correctly named token at the state address is outside application custody. -/
theorem token_outside_custody (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (request : ReaderRequest) (observed : ReaderObservation)
    (release : PublishedRelease) (output : ObservedOutput)
    (_network : observed.network = .complete request.network) (_release : observed.release = some release)
    (_policy : request.registry.policy = release.statePolicy) (_outputs : observed.activeOutputs = .complete [output])
    (_quantity : quantity output (activeAsset h c request.registry request.key) = 1)
    (_outside : output.credential ≠ release.applicationCredential ∨ output.credential = request.registry.policy) :
    readKey h c t decode request observed =
      .refused (.tokenOutsideApplicationCustody output.reference output.credential) := by
  rcases _outside with outside | atState
  · simp_all [readKey]
  · simp_all [readKey]

/-- More than one returned output is conflicting, regardless of datum or location. -/
theorem conflicting_outputs (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (request : ReaderRequest) (observed : ReaderObservation)
    (release : PublishedRelease) (outputs : List ObservedOutput)
    (_network : observed.network = .complete request.network) (_release : observed.release = some release)
    (_policy : request.registry.policy = release.statePolicy) (_outputs : observed.activeOutputs = .complete outputs)
    (_multiple : 1 < outputs.length) :
    readKey h c t decode request observed = .refused .conflictingEvidence := by
  cases outputs with
  | nil => simp_all
  | cons first rest =>
    cases rest with
    | nil => simp_all
    | cons second rest => simp_all [readKey]

/-- A non-unit quantity never becomes evidence of a key's status. -/
theorem conflicting_quantity (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (request : ReaderRequest) (observed : ReaderObservation)
    (release : PublishedRelease) (output : ObservedOutput)
    (_network : observed.network = .complete request.network) (_release : observed.release = some release)
    (_policy : request.registry.policy = release.statePolicy) (_outputs : observed.activeOutputs = .complete [output])
    (_quantity : quantity output (activeAsset h c request.registry request.key) ≠ 1) :
    readKey h c t decode request observed = .refused .conflictingEvidence := by
  simp_all [readKey]

/-- A complete empty state answer is unavailable, not an unknown key. -/
theorem state_not_found (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (request : ReaderRequest) (observed : ReaderObservation)
    (release : PublishedRelease)
    (_network : observed.network = .complete request.network) (_release : observed.release = some release)
    (_policy : request.registry.policy = release.statePolicy) (_outputs : observed.activeOutputs = .complete [])
    (_state : observed.state = .complete none) :
    readKey h c t decode request observed = .unavailable .state .stateNotFound := by
  simp_all [readKey]

/-- Extra assets, a non-root datum or any other failed state recognition cannot
supply a conclusion; the exact answer is a named unavailable state read. -/
theorem state_not_recognized (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (request : ReaderRequest) (observed : ReaderObservation)
    (release : PublishedRelease) (output : ObservedOutput)
    (_network : observed.network = .complete request.network) (_release : observed.release = some release)
    (_policy : request.registry.policy = release.statePolicy) (_outputs : observed.activeOutputs = .complete [])
    (_state : observed.state = .complete (some output))
    (_unrecognised : recognizeReaderState release request.registry output = false) :
    readKey h c t decode request observed = .unavailable .state .stateNotRecognized := by
  simp_all [readKey]

/-- The recognised state does not authenticate trie content with another root. -/
theorem trie_root_mismatch (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (request : ReaderRequest) (observed : ReaderObservation)
    (release : PublishedRelease) (output : ObservedOutput) (trie : Trie)
    (_network : observed.network = .complete request.network) (_release : observed.release = some release)
    (_policy : request.registry.policy = release.statePolicy) (_outputs : observed.activeOutputs = .complete [])
    (_state : observed.state = .complete (some output))
    (_recognised : recognizeReaderState release request.registry output = true)
    (_trie : observed.trie = .complete trie) (_mismatch : output.datum ≠ .root (t trie)) :
    readKey h c t decode request observed = .unavailable .trie .trieRootMismatch := by
  simp_all [readKey]

/-- A unit token in custody with a datum that decodes as neither holding nor
termination request is conflicting evidence. -/
theorem undecodable_holding (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (request : ReaderRequest) (observed : ReaderObservation)
    (release : PublishedRelease) (output : ObservedOutput)
    (_network : observed.network = .complete request.network) (_release : observed.release = some release)
    (_policy : request.registry.policy = release.statePolicy) (_outputs : observed.activeOutputs = .complete [output])
    (_quantity : quantity output (activeAsset h c request.registry request.key) = 1)
    (_custody : output.credential = release.applicationCredential ∧ output.credential ≠ request.registry.policy)
    (_notPending : terminationShape .none h c release output request.registry request.key = false)
    (_decode : decoded decode output = none) :
    readKey h c t decode request observed = .refused .conflictingEvidence := by
  rcases _custody with ⟨atApp, notState⟩
  simp_all [readKey]

/-- A pending registration datum is not a live holding of an existing token. -/
theorem registration_is_not_a_holding (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (request : ReaderRequest) (observed : ReaderObservation)
    (release : PublishedRelease) (output : ObservedOutput) (data : RegistrationData)
    (_network : observed.network = .complete request.network) (_release : observed.release = some release)
    (_policy : request.registry.policy = release.statePolicy) (_outputs : observed.activeOutputs = .complete [output])
    (_quantity : quantity output (activeAsset h c request.registry request.key) = 1)
    (_custody : output.credential = release.applicationCredential ∧ output.credential ≠ request.registry.policy)
    (_notPending : terminationShape .none h c release output request.registry request.key = false)
    (_decode : decoded decode output = some (.registration data)) :
    readKey h c t decode request observed = .refused .conflictingEvidence := by
  rcases _custody with ⟨atApp, notState⟩
  simp_all [readKey]

/-- Any wrong registry, key, active asset or uncovered deposit in a decoded live
control is conflicting evidence, even when the token itself is correct. -/
theorem invalid_live_control (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (request : ReaderRequest) (observed : ReaderObservation)
    (release : PublishedRelease) (output : ObservedOutput) (control : ProtectedControl) (payload : Nat)
    (_network : observed.network = .complete request.network) (_release : observed.release = some release)
    (_policy : request.registry.policy = release.statePolicy) (_outputs : observed.activeOutputs = .complete [output])
    (_quantity : quantity output (activeAsset h c request.registry request.key) = 1)
    (_custody : output.credential = release.applicationCredential ∧ output.credential ≠ request.registry.policy)
    (_notPending : terminationShape .none h c release output request.registry request.key = false)
    (_decode : decoded decode output = some (.live control payload))
    (_invalid : control.registry ≠ request.registry ∨ control.key ≠ request.key ∨
      control.activeAsset ≠ activeAsset h c request.registry request.key ∨ output.lovelace < control.deposit) :
    readKey h c t decode request observed = .refused .conflictingEvidence := by
  rcases _custody with ⟨atApp, notState⟩
  rcases _invalid with registry | key | asset | deposit
  · simp_all [readKey]
  · simp_all [readKey]
  · simp_all [readKey]
  · have uncovered : ¬control.deposit ≤ output.lovelace := by omega
    have distinct : release.applicationCredential ≠ release.statePolicy := by simpa [atApp, _policy] using notState
    simp [readKey, _network, _release, _policy, _outputs, _quantity, atApp, distinct,
      _notPending, _decode, uncovered]

/-- With no token, an active leaf is a conflict, not an absence. The same exact
answer covers the legacy known-absent leaf; only unknown and terminal conclude. -/
theorem known_nonterminal_leaf_without_token (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (request : ReaderRequest) (observed : ReaderObservation)
    (release : PublishedRelease) (output : ObservedOutput) (trie : Trie) (leaf : State)
    (_network : observed.network = .complete request.network) (_release : observed.release = some release)
    (_policy : request.registry.policy = release.statePolicy) (_outputs : observed.activeOutputs = .complete [])
    (_state : observed.state = .complete (some output))
    (_recognised : recognizeReaderState release request.registry output = true)
    (_trie : observed.trie = .complete trie) (_root : output.datum = .root (t trie))
    (_leaf : trieGet trie request.key = .known leaf) (_notTerminal : leaf ≠ .terminal) :
    readKey h c t decode request observed = .refused .conflictingEvidence := by
  cases leaf <;> simp_all [readKey]

end SingularApplicationHeld.ReaderStatements
