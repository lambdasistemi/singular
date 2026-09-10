import Singular.NamingWire
import Singular.NamingLifecycle
import Singular.Lemmas

namespace Singular.NamingWireStatements

set_option maxRecDepth 100000 in
theorem naming_datum_serialises_byte_exact :
    serialiseNamingDatum aliceFixture = expectedNamingDatumBytes := by
  simp [serialiseNamingDatum, encodeNamingDatum, encodePaymentDestination,
    encodeRetirementQuorum, serialiseWireData, cborHead, expectedNamingDatumBytes,
    aliceFixture, controllerAddress, destinationAddress, nextControllerCommitment,
    quorumKeyHash, bytesValid, List.range']

theorem naming_datum_tree_roundtrip_and_shape :
    decodeNamingDatum (encodeNamingDatum aliceFixture) = some aliceFixture ∧
    namingDatumShape (encodeNamingDatum aliceFixture) =
      some { outerIndex := 0, innerIndex := 0, arity := 4 } ∧
    namingDatumControlBytes (encodeNamingDatum aliceFixture) = some controllerAddress.bytes ∧
    namingDatumCommitmentBytes (encodeNamingDatum aliceFixture) = some nextControllerCommitment.digest := by
  decide

theorem inline_datum_only :
    extractNamingDatum (.inline (encodeNamingDatum aliceFixture)) = some aliceFixture ∧
    extractNamingDatum (.datumHash [1, 2, 3]) = none ∧
    extractNamingDatum .absent = none := by
  decide

theorem payment_destination_zero_or_one :
    decodeNamingDatum twoDestinationDatum = none := by
  decide

theorem insert_request_fixture_is_the_queued_request :
    claimedOnce.registry.requests.head? = some aliceInsertRequest := by
  decide

set_option maxRecDepth 100000 in
theorem insert_request_serialises_byte_exact :
    serialiseInsertRequest aliceInsertRequest = some expectedAliceInsertRequestBytes := by
  simp [serialiseInsertRequest, encodeInsertRequest, aliceInsertRequest,
    aliceInsertProposal, insertAsset, encodeProposal, encodeOutput,
    encodeRepresentative, representative, entry, serialiseWireData, cborHead,
    expectedAliceInsertRequestBytes, aliceKey, demoDestination, demoDatum,
    demoValue, demoRefundAddress] <;> decide

set_option maxRecDepth 100000 in
theorem insert_request_roundtrip_and_declared_shape :
    (encodeInsertRequest aliceInsertRequest).bind decodeInsertCommitment =
      some aliceInsertProposal ∧
    (encodeInsertRequest aliceInsertRequest).bind insertRequestShape =
      some (InsertRequestShape.mk 0 1 0 6) ∧
    (encodeInsertRequest aliceInsertRequest).bind (fun encoded =>
      (decodeInsertCommitment encoded).bind fun proposal => encodeInsertRequest
        { aliceInsertRequest with proposal, token := some (insertAsset proposal) }) =
      encodeInsertRequest aliceInsertRequest ∧
    (encodeInsertRequest aliceInsertRequest).bind (fun encoded =>
      (decodeInsertCommitment encoded).bind fun proposal => serialiseInsertRequest
        { aliceInsertRequest with proposal, token := some (insertAsset proposal) }) =
      some expectedAliceInsertRequestBytes := by
  constructor
  · simp [encodeInsertRequest, decodeInsertCommitment, decodeProposal,
      decodeOutput, decodeRepresentative, encodeProposal, encodeOutput,
      encodeRepresentative, aliceInsertRequest, aliceInsertProposal, insertAsset,
      representative, entry]
  · constructor
    · rfl
    · constructor
      · rfl
      · simpa [aliceInsertRequest] using insert_request_serialises_byte_exact

set_option maxRecDepth 100000 in
theorem insert_request_malformed_and_redirect_refused :
    decodeInsertRequestCommitment aliceInsertRequest (.constr 0 []) = none ∧
    decodeInsertCommitment (.constr 0 [encodeProposal redirectedAliceInsertProposal]) =
      some redirectedAliceInsertProposal ∧
    decodeInsertRequestCommitment aliceInsertRequest
      (.constr 0 [encodeProposal redirectedAliceInsertProposal]) = none ∧
    lifecycleStep fixtureHasher cancellationPending
      (.cancelClaim 1 (demoRefundAddress + 1)) =
      .error "withdraw-refund-address" := by
  constructor
  · simp [decodeInsertRequestCommitment, encodeInsertRequest,
      decodeInsertCommitment, decodeProposal, decodeOutput,
      decodeRepresentative, aliceInsertRequest, aliceInsertProposal, insertAsset]
  · constructor
    · rfl
    · constructor
      · simp [decodeInsertRequestCommitment, encodeInsertRequest,
          decodeInsertCommitment, decodeProposal, decodeOutput,
          decodeRepresentative, aliceInsertRequest, aliceInsertProposal,
          redirectedAliceInsertProposal, insertAsset, encodeProposal, encodeOutput,
          encodeRepresentative,
          representative, entry, aliceKey, demoDestination, demoDatum, demoValue,
          demoRefundAddress]
      · rfl

end Singular.NamingWireStatements
