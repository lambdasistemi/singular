import Singular.NamingLifecycle

namespace Singular.NamingLifecycleStatements

theorem supported_address_roundtrips :
    decodeAddress nextControllerAddress.bytes = some nextControllerAddress ∧
    encodeAddress nextControllerAddress = some nextControllerAddress.bytes ∧
    paymentKeyAddress nextControllerAddress = true := by
  decide

theorem commitment_vectors_are_distinct_and_32_bytes :
    nextControllerCommitment.digest.length = 32 ∧
    freshControllerCommitment.digest.length = 32 ∧
    wrongDomainCommitment.digest.length = 32 ∧
    nextControllerCommitment != freshControllerCommitment ∧
    nextControllerCommitment != wrongDomainCommitment := by
  decide

theorem hash_contract_publishes_complete_preimage :
    nextControlHashContract.algorithm = "BLAKE2b-256" ∧
    nextControlHashContract.digestBytes = 32 ∧
    nextControlHashInput nextControllerAddress =
      nextControlDomain ++ [0] ++ nextControllerAddress.bytes := by
  constructor
  · rfl
  · constructor <;> rfl

theorem cancellation_stored_refund_committed_and_accepts :
    cancellationPending.registry.requests.head?.map
        (fun request => request.proposal.refundAddress) = some demoRefundAddress ∧
    cancellationPending.registry.requests.head?.map
        (fun request => request.token == some (insertAsset request.proposal)) = some true ∧
    (lifecycleStep fixtureHasher cancellationPending
      (.cancelClaim 1 demoRefundAddress)).isOk = true := by
  decide

theorem cancellation_redirect_refused :
    lifecycleStep fixtureHasher cancellationPending
      (.cancelClaim 1 (demoRefundAddress + 1)) =
      .error "withdraw-refund-address" := by
  rfl

theorem insert_attestation_alone_cannot_cancel :
    lifecycleStep fixtureHasher claimedOnce (.cancelClaim 1 demoRefundAddress) =
      .error "withdraw-binding" := by
  rfl

theorem folded_claim_cancellation_refused :
    lifecycleStep fixtureHasher activeOnce (.cancelClaim 1 demoRefundAddress) =
      .error "request-unavailable" := by
  rfl

theorem cancellation_replay_refused :
    lifecycleStep fixtureHasher cancelledClaim (.cancelClaim 1 demoRefundAddress) =
      .error "request-unavailable" := by
  rfl

theorem destination_clear_accepts :
    (lifecycleStep fixtureHasher activeOnce maintainClear).isOk = true := by
  decide

theorem destination_change_preserves_registry_control_commitment_quorum :
    let changed := afterLifecycle activeOnce maintainClear
    changed.registry.entries = activeOnce.registry.entries ∧
    changed.records.head?.map (fun record => record.representative) =
      activeOnce.records.head?.map (fun record => record.representative) ∧
    changed.records.head?.map (fun record => record.fixture.controlAddress) = some controllerAddress ∧
    changed.records.head?.map (fun record => record.fixture.nextControlCommitment) =
      some nextControllerCommitment ∧
    changed.records.head?.map (fun record => record.fixture.retirementQuorum) =
      activeOnce.records.head?.map (fun record => record.fixture.retirementQuorum) := by
  decide

theorem destination_unauthorized_refused :
    lifecycleStep fixtureHasher activeOnce (.maintain 3 4 aliceKey clearedFixture {}) =
      .error "controller-signature" := by
  rfl

theorem destination_commitment_tamper_refused :
    lifecycleStep fixtureHasher activeOnce
      (.maintain 3 4 aliceKey { clearedFixture with nextControlCommitment := freshControllerCommitment }
        { requiredSigners := [controllerAddress] }) =
      .error "destination-field-preservation" := by
  rfl

theorem maintenance_quorum_alteration_refused :
    lifecycleStep fixtureHasher activeOnce maintainQuorumTamper =
      .error "destination-field-preservation" := by
  rfl

theorem recovery_accepts_without_old_controller :
    (lifecycleStep fixtureHasher activeOnce recoverWithNext).isOk = true := by
  decide

theorem recovery_installs_controller_and_fresh_commitment :
    let recovered := afterLifecycle activeOnce recoverWithNext
    recovered.records.head?.map (fun record => record.fixture.controlAddress) =
      some nextControllerAddress ∧
    recovered.records.head?.map (fun record => record.fixture.nextControlCommitment) =
      some freshControllerCommitment ∧
    recovered.records.head?.map (fun record => record.representative) =
      activeOnce.records.head?.map (fun record => record.representative) := by
  decide

theorem wrong_recovery_reveal_refused :
    lifecycleStep fixtureHasher activeOnce
      (.recover 3 4 aliceKey freshControllerAddress namingConsumerBinding.registry
        (representative activeOnce.registry aliceKey) recoveredFixture
        { requiredSigners := [freshControllerAddress] }) =
      .error "recovery-commitment" := by
  rfl

theorem recovery_requires_revealed_payment_key_signer :
    lifecycleStep fixtureHasher activeOnce
      (.recover 3 4 aliceKey nextControllerAddress namingConsumerBinding.registry
        (representative activeOnce.registry aliceKey) recoveredFixture {}) =
      .error "recovery-required-signer" := by
  rfl

theorem correct_reveal_wrong_payment_key_signer_refused :
    lifecycleStep fixtureHasher activeOnce recoverWrongPaymentKeySigner =
      .error "recovery-required-signer" := by
  rfl

theorem recovery_missing_fresh_commitment_refused :
    lifecycleStep fixtureHasher activeOnce recoverMissingFreshCommitment =
      .error "recovery-fresh-commitment" := by
  rfl

theorem recovery_representative_tamper_refused :
    lifecycleStep fixtureHasher activeOnce recoverRepresentativeTamper =
      .error "recovery-representative" := by
  rfl

theorem recovery_registry_tamper_refused :
    lifecycleStep fixtureHasher activeOnce recoverRegistryTamper =
      .error "recovery-registry" := by
  rfl

theorem recovery_quorum_tamper_refused :
    lifecycleStep fixtureHasher activeOnce recoverQuorumTamper =
      .error "recovery-field-preservation" := by
  rfl

theorem recovery_replay_refused :
    let recovered := afterLifecycle activeOnce recoverWithNext
    lifecycleStep fixtureHasher recovered
      (.recover 4 5 aliceKey nextControllerAddress recovered.registry.config.registry
        (representative recovered.registry aliceKey) recoveredFixture
        { requiredSigners := [nextControllerAddress] }) =
      .error "recovery-commitment" := by
  rfl

theorem old_controller_dead_after_recovery :
    let recovered := afterLifecycle activeOnce recoverWithNext
    lifecycleStep fixtureHasher recovered
      (.maintain 4 5 aliceKey { recoveredFixture with paymentDestination := none }
        { requiredSigners := [controllerAddress] }) =
      .error "controller-signature" := by
  rfl

theorem controller_and_quorum_retirement_accept :
    (lifecycleStep fixtureHasher activeOnce retirementByController).isOk = true ∧
    (lifecycleStep fixtureHasher activeOnce retirementByQuorum).isOk = true := by
  decide

theorem insufficient_quorum_refused :
    lifecycleStep fixtureHasher activeOnce retirementInsufficient =
      .error "retirement-authorization" := by
  rfl

theorem quorum_only_control_takeover_refused :
    lifecycleStep fixtureHasher activeOnce quorumControlTakeover =
      .error "controller-signature" := by
  rfl

theorem quorum_only_payment_redirection_refused :
    lifecycleStep fixtureHasher activeOnce quorumPaymentRedirection =
      .error "controller-signature" := by
  rfl

theorem retirement_withdrawal_refused :
    lifecycleStep fixtureHasher retirementPending (.withdrawRetirement 4) =
      .error "retirement-withdrawal-refused" := by
  rfl

theorem wrong_retirement_request_custody_refused :
    lifecycleStep fixtureHasher activeOnce retirementWrongCustody =
      .error "retirement-request" := by
  rfl

theorem retirement_replay_refused :
    lifecycleStep fixtureHasher retirementPending retirementByController =
      .error "naming-record-unavailable" := by
  rfl

theorem retirement_pending_then_over :
    namingResolve retirementPending aliceKey true = .ok .pending ∧
    namingResolve retirementOver aliceKey true = .ok .retired := by
  constructor
  · rfl
  · rfl

theorem re_registration_after_over_refused :
    retiredReRegistration = .error "occupied-key" := by
  rfl

theorem forged_public_digest_cannot_override_trusted_hash :
    fixtureHasher nonFixtureControllerAddress = wrongDomainCommitment ∧
    lifecycleStep fixtureHasher activeOnce
      (.recover 3 4 aliceKey nonFixtureControllerAddress namingConsumerBinding.registry
        (representative activeOnce.registry aliceKey) forgedRecoveryFixture
        { requiredSigners := [nonFixtureControllerAddress] }) =
      .error "recovery-commitment" := by
  constructor
  · rfl
  · rfl

theorem alternate_registry_seed_refused :
    initializeConsumer namingConsumerBinding alternateSeedInitialization =
      .error "canonical-seed" := by
  rfl

theorem canonical_consumer_initialization_accepts :
    initializeConsumer namingConsumerBinding canonicalInitialization = .ok () := by
  rfl

theorem canonical_seed_is_consumed_once :
    initializeConsumerTransition namingConsumerBinding {} canonicalInitialization =
      .ok { consumedSeeds := [400] } ∧
    initializeConsumer namingConsumerBinding canonicalInitialization = .ok () ∧
    initializeConsumerTransition namingConsumerBinding canonicalInitializedState
      canonicalInitialization = .error "canonical-seed-consumed" := by
  constructor
  · rfl
  constructor <;> rfl

theorem second_seed_rival_registry_refused :
    initializeConsumer namingConsumerBinding rivalRegistryInitialization =
      .error "canonical-seed" := by
  rfl

theorem substituted_registry_refused :
    initializeConsumer namingConsumerBinding substitutedRegistryInitialization =
      .error "registry-authenticity" := by
  rfl

theorem substituted_policy_refused :
    initializeConsumer namingConsumerBinding substitutedPolicyInitialization =
      .error "application-policy" := by
  rfl

theorem substituted_representative_policy_refused :
    initializeConsumer namingConsumerBinding substitutedRepresentativeInitialization =
      .error "representative-policy" := by
  rfl

theorem substituted_validator_script_refused :
    initializeConsumer namingConsumerBinding substitutedValidatorInitialization =
      .error "validator-script" := by
  rfl

theorem executing_witness_is_derived_per_example :
    (lifecycleExecutingWitness maintainClear).applicationSpend = true ∧
    (lifecycleExecutingWitness recoverWithNext).requiredSigners = [nextControllerAddress] ∧
    (lifecycleExecutingWitness retirementByQuorum).quorumSigners =
      [quorumKeyHash 1, quorumKeyHash 29] ∧
    (lifecycleExecutingWitness (.completeRetirement 4)).nativeSpend = true ∧
    (lifecycleExecutingWitness (.completeRetirement 4)).representativeMint = true := by
  decide

end Singular.NamingLifecycleStatements
