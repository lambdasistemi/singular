import Singular.NamingWire

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

end Singular.NamingWireStatements
