import Singular.NamingLifecycle

namespace Singular.NamingLifecycleStatements

private def activeOnce : NamingState :=
  match namingRegister namingInitial aliceKey 5 aliceFixture with
  | .ok s => s
  | .error _ => namingInitial

theorem supported_address_roundtrips :
    decodeAddress nextControllerAddress.bytes = some nextControllerAddress ∧
    encodeAddress nextControllerAddress = some nextControllerAddress.bytes ∧
    paymentKeyAddress nextControllerAddress = true := by
  refine ⟨by rfl, by rfl, by rfl⟩

theorem commitment_vectors_are_distinct_and_32_bytes :
    nextControllerCommitment.digest.length = 32 ∧
    freshControllerCommitment.digest.length = 32 ∧
    wrongDomainCommitment.digest.length = 32 ∧
    nextControllerCommitment != freshControllerCommitment ∧
    nextControllerCommitment != wrongDomainCommitment := by
  refine ⟨by rfl, by rfl, by rfl, by rfl, by rfl⟩

/-- **NM2** — maintenance preserves the untouched control fields and refuses
an unauthorized signature. -/
theorem destination_preserves_and_refuses :
    (maintainDestination activeOnce aliceKey clearedFixture
      [controllerAddress]).isOk = true ∧
    maintainDestination activeOnce aliceKey clearedFixture [] =
      .error "controller-signature" ∧
    maintainDestination activeOnce aliceKey
      { aliceFixture with controlAddress := otherControllerAddress }
      [controllerAddress] = .error "destination-field-preservation" := by
  refine ⟨by rfl, by rfl, by rfl⟩

theorem recovery_installs_and_refuses :
    (recoverController fixtureHasher activeOnce aliceKey nextControllerAddress
      recoveredFixture [nextControllerAddress]).isOk = true ∧
    recoverController fixtureHasher activeOnce aliceKey freshControllerAddress
      recoveredFixture [freshControllerAddress] =
      .error "recovery-commitment" := by
  refine ⟨by rfl, by rfl⟩

/-- **NM3 / R-NM4** — retirement by quorum or by the committed recovery key
accepts; below quorum without the recovery key refuses. -/
theorem retirement_authorization_rows :
    (namingRetireLifecycle activeOnce aliceKey
      [quorumKeyHash 1, quorumKeyHash 29] none).isOk = true ∧
    (namingRetireLifecycle activeOnce aliceKey
      [] (some nextControllerAddress)).isOk = true ∧
    namingRetireLifecycle activeOnce aliceKey [quorumKeyHash 1] none =
      .error "naming-no-delete" ∧
    namingRetireLifecycle activeOnce aliceKey
      [controllerAddress.bytes] none = .error "naming-no-delete" := by
  refine ⟨by rfl, by rfl, by rfl, by rfl⟩

/-- **LI** — the consumer binding pins the datum's policies; substitutions are
refused. -/
theorem consumer_binding_pins_policies :
    initializeConsumer namingConsumerBinding canonicalInitialization = .ok () ∧
    initializeConsumer namingConsumerBinding
      { canonicalInitialization with activePolicy := 99 } = .error "active-policy" ∧
    initializeConsumer namingConsumerBinding
      { canonicalInitialization with registry := 2 } = .error "registry-authenticity" := by
  refine ⟨by rfl, by rfl, by rfl⟩

end Singular.NamingLifecycleStatements
