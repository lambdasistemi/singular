import Singular.NamingLifecycle

namespace Singular.NamingLifecycleStatements

private def activeOnce : NamingState :=
  match namingRegister namingInitial aliceKey 5 aliceFixture with
  | .ok s => s
  | .error _ => namingInitial

private def pendingOnce : NamingState :=
  match namingRetireLifecycle activeOnce aliceKey
      [quorumKeyHash 1, quorumKeyHash 29] none with
  | .ok state => state
  | .error _ => activeOnce

private def pendingAttempt : RetirementCompletion :=
  match pendingOnce.pendingRetirements.head? with
  | some pending => completionFor pending
  | none =>
      { key := aliceKey
      , requestValidatorHash := pendingOnce.parameters.requestValidatorHash
      , requestToken := pendingOnce.parameters.cageTokenName
      , approval := none }

private def mismatchedPendingApproval : Option Approval :=
  match pendingAttempt.approval with
  | none => none
  | some approval => some { approval with key := approval.key + 1 }

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
      .error "naming-retirement-uncertified" ∧
    namingRetireLifecycle activeOnce aliceKey
      [controllerAddress.bytes] none = .error "naming-retirement-uncertified" := by
  refine ⟨by rfl, by rfl, by rfl, by rfl⟩

/-- **D-157-REQUEST-HOME retirement inversion** — the authorized retirement
ends with the leaf still active, the record removed, its active token in
completion custody, and exactly one pending `updateTerminal` request whose
home and token are the immutable same-registry parameters. -/
theorem retirement_pending_inversion :
    (trieGet pendingOnce.registry.trie aliceKey == .known .active &&
    (pendingOnce.records.find? (·.key == aliceKey)).isNone &&
    kindCount pendingOnce.registry .active aliceKey == 1 &&
    (pendingOnce.registry.held.find? (fun holding =>
      holding.key == aliceKey && holding.kind == .active)).map (·.output) ==
        some pendingOnce.parameters.retirementCustody &&
    (match pendingOnce.pendingRetirements with
    | [pending] =>
        pending.requestValidatorHash == pendingOnce.parameters.requestValidatorHash &&
        pending.requestValidatorHash == appliedRequestValidatorHashFor
          pendingOnce.parameters.registryStatePolicy pendingOnce.parameters.cageTokenName &&
        pending.requestToken == pendingOnce.parameters.cageTokenName &&
        pending.request.edge == .updateTerminal &&
        pending.request.key == aliceKey && pending.request.approval.isSome
    | _ => false)) = true := by
  decide

/-- **D-157-REQUEST-HOME completion inversion** — completion consumes the
request produced above; it is the step that writes terminal, removes the held
active token, and removes the pending request. -/
theorem retirement_completion_inversion :
    (match namingCompleteRetirement pendingOnce pendingAttempt with
    | .ok completed =>
        trieGet completed.registry.trie aliceKey == .known .terminal &&
        kindCount completed.registry .active aliceKey == 0 &&
        (completed.pendingRetirements.find? (·.request.key == aliceKey)).isNone
    | .error _ => false) = true := by
  decide

/-- The four request-boundary refusals, each paired with the unchanged
connected positive control that consumes the co-created request. -/
theorem retirement_completion_refusals :
    ((match namingCompleteRetirement pendingOnce
        { pendingAttempt with requestValidatorHash := pendingAttempt.requestValidatorHash + 1 } with
      | .error "retirement-request-validator-mismatch" => true | _ => false) &&
    (namingCompleteRetirement pendingOnce pendingAttempt).isOk &&
    (match namingCompleteRetirement pendingOnce
        { pendingAttempt with requestToken := pendingAttempt.requestToken + 1 } with
      | .error "retirement-request-token-mismatch" => true | _ => false) &&
    (namingCompleteRetirement pendingOnce pendingAttempt).isOk &&
    (match namingCompleteRetirement pendingOnce { pendingAttempt with approval := none } with
      | .error "retirement-approval-missing" => true | _ => false) &&
    (namingCompleteRetirement pendingOnce pendingAttempt).isOk &&
    (match namingCompleteRetirement pendingOnce
        { pendingAttempt with approval := mismatchedPendingApproval } with
      | .error "retirement-approval-mismatch" => true | _ => false) &&
    (namingCompleteRetirement pendingOnce pendingAttempt).isOk) = true := by
  decide

/-- **LI** — the consumer binding pins the datum's policies; substitutions are
refused. -/
theorem consumer_binding_pins_policies :
    initializeConsumer namingConsumerBinding canonicalInitialization = .ok () ∧
    initializeConsumer namingConsumerBinding
      { canonicalInitialization with activePolicy := 99 } = .error "active-policy" ∧
    initializeConsumer namingConsumerBinding
      { canonicalInitialization with registry := 2 } = .error "registry-authenticity" ∧
    initializeConsumer namingConsumerBinding
      { canonicalInitialization with cageTokenName :=
        canonicalInitialization.cageTokenName + 1 } = .error "cage-token" ∧
    initializeConsumer namingConsumerBinding
      { canonicalInitialization with requestValidatorHash :=
        canonicalInitialization.requestValidatorHash + 1 } = .error "request-validator" := by
  refine ⟨by rfl, by rfl, by rfl, by rfl, by rfl⟩

end Singular.NamingLifecycleStatements
