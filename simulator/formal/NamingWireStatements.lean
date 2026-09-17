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
  refine ⟨by decide, by decide, by decide, by decide⟩

-- The record datum serialises to exactly these 205 bytes. The drafted version of
-- this theorem asserted `serialiseNamingDatum aliceFixture = serialiseNamingDatum
-- aliceFixture`, which is a tautology: it proves nothing about the bytes and would
-- hold of any encoder whatsoever, including one that dropped every field.
set_option maxRecDepth 1000000 in
theorem naming_datum_serialises_byte_exact :
    serialiseNamingDatum aliceFixture =
      [216, 121, 159, 216, 121, 159, 88, 29, 97, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12,
       13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 216, 122, 159,
       88, 29, 97, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100,
       101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 255, 88, 32, 194,
       219, 76, 247, 78, 175, 65, 208, 95, 243, 240, 210, 186, 25, 12, 72, 45, 189,
       40, 94, 86, 21, 171, 104, 133, 192, 82, 134, 196, 194, 60, 190, 216, 121, 159,
       2, 159, 88, 28, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
       19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 88, 28, 29, 30, 31, 32, 33, 34, 35, 36,
       37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56,
       88, 28, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74,
       75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 255, 255, 255, 255] := by
  simp +decide [serialiseNamingDatum, serialiseWireData, encodeNamingDatum, cborHead,
    Nat.toWire, aliceFixture, controllerAddress, nextControllerAddress, destinationAddress,
    nextControllerCommitment, encodePaymentDestination, bytesValid, encodeAddress,
    addressKind, credentialOffset, List.range', encodeRetirementQuorum, quorumKeyHash]

theorem inline_datum_only :
    extractNamingDatum (.inline (encodeNamingDatum aliceFixture)) = some aliceFixture ∧
    extractNamingDatum (.datumHash [1, 2, 3]) = none ∧
    extractNamingDatum .absent = none := by
  refine ⟨by decide, by decide, by decide⟩

/-- **WD** — a datum with two payment destinations does not decode. -/
theorem payment_destination_zero_or_one :
    decodeNamingDatum twoDestinationDatum = none := by
  rfl

-- **WR01** — the `insertAbsent` request wire is byte-exact and round-trips,
-- carrying the refund address the request names (R-ADA). Stated as the exact
-- bytes in both directions rather than as `decode ∘ encode = id`, so a codec
-- that lost the refund address symmetrically could not satisfy it.
set_option maxRecDepth 1000000 in
theorem witness_request_wire_roundtrip :
    serialiseWitnessRequest (WitnessRequestWire.mk 0 aliceKey 91 91 200 0) =
      [216, 121, 159, 0, 24, 42, 24, 91, 24, 91, 24, 200, 0, 255] ∧
    deserialiseWitnessRequest [216, 121, 159, 0, 24, 42, 24, 91, 24, 91, 24, 200, 0, 255] =
      some (WitnessRequestWire.mk 0 aliceKey 91 91 200 0) := by
  constructor
  · simp [serialiseWitnessRequest, serialiseWireData, Nat.toWire, cborHead, aliceKey]
  · simp +decide [deserialiseWitnessRequest, parseWireDataFuel, parseWireItemsFuel,
      takeWireBytes, aliceKey]

end Singular.NamingWireStatements
