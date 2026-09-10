import Singular.NamingWire
import Singular.NamingLifecycle

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
  decide

theorem insert_request_roundtrip_and_declared_shape :
    (encodeInsertRequest aliceInsertRequest).bind decodeInsertCommitment =
      some aliceInsertProposal ∧
    (encodeInsertRequest aliceInsertRequest).bind insertRequestShape =
      some (InsertRequestShape.mk 0 1 0 6) ∧
    deserialiseInsertRequest aliceInsertRequest expectedAliceInsertRequestBytes =
      some aliceInsertProposal ∧
    (deserialiseInsertRequest aliceInsertRequest expectedAliceInsertRequestBytes).bind
      (fun proposal => serialiseInsertRequest
        { aliceInsertRequest with proposal, token := some (insertAsset proposal) }) =
      some expectedAliceInsertRequestBytes := by
  decide

theorem insert_request_malformed_and_redirect_refused :
    deserialiseInsertRequest aliceInsertRequest malformedAliceInsertRequestBytes = none ∧
    deserialiseInsertCommitment redirectedAliceInsertRequestBytes =
      some redirectedAliceInsertProposal ∧
    deserialiseInsertRequest aliceInsertRequest redirectedAliceInsertRequestBytes = none ∧
    lifecycleStep fixtureHasher cancellationPending
      (.cancelClaim 1 (demoRefundAddress + 1)) =
      .error "withdraw-refund-address" := by
  decide

end Singular.NamingWireStatements
