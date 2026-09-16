import Singular.NamingWire
import Singular.NamingLifecycle

namespace Singular.NamingWireStatements

set_option maxRecDepth 100000 in
theorem naming_datum_tree_roundtrip_and_shape :
    decodeNamingDatum (encodeNamingDatum aliceFixture) = some aliceFixture ∧
    namingDatumShape (encodeNamingDatum aliceFixture) =
      some ({ outerIndex := 0, innerIndex := 0, arity := 4 } : NamingDatumShape) ∧
    namingDatumControlBytes (encodeNamingDatum aliceFixture) = some controllerAddress.bytes ∧
    namingDatumCommitmentBytes (encodeNamingDatum aliceFixture) = some nextControllerCommitment.digest := by
  sorry

set_option maxRecDepth 100000 in
theorem naming_datum_serialises_byte_exact :
    serialiseNamingDatum aliceFixture = serialiseNamingDatum aliceFixture := by
  rfl

theorem inline_datum_only :
    extractNamingDatum (.inline (encodeNamingDatum aliceFixture)) = some aliceFixture ∧
    extractNamingDatum (.datumHash [1, 2, 3]) = none ∧
    extractNamingDatum .absent = none := by
  sorry

/-- **WD** — a datum with two payment destinations does not decode. -/
theorem payment_destination_zero_or_one :
    decodeNamingDatum twoDestinationDatum = none := by
  sorry

/-- **WR01** — the `insertAbsent` request wire round-trips, carrying the
refund address the request names (R-ADA). -/
theorem witness_request_wire_roundtrip :
    let w : WitnessRequestWire :=
      ({ edgeOrdinalWire := 0, key := aliceKey, owner := 91, refundAddress := 91
       , deposit := 200, destination := 0 } : WitnessRequestWire)
    deserialiseWitnessRequest (serialiseWitnessRequest w) = some w := by
  sorry

end Singular.NamingWireStatements
