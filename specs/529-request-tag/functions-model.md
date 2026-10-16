# Admission and observation interfaces

## Story

As a library or validator maintainer, I want every admission interface to receive its evidence explicitly and return a refusal or an admitted result, so that no hidden clock, guessed value or mutable global decides a request.

The signatures below are the frozen model interfaces. Concrete Aiken and Haskell entry points must preserve their input and output meanings; the writer proposes exact new language-level signatures at the representation checkpoint before the owner freezes the implementation slice. This page specifies no bodies or algorithms.

| Interface | Explicit signature | Implementation constraint |
|---|---|---|
| Registration booking | `Singular.registrationBookingRefusal (c : Config) (b : RegistrationBooking) : Option String` | Observe output, mint and interval; no reading wall clock as an oracle. |
| Termination booking | `Singular.terminationBookingRefusal (registry : RegistryState) (b : TerminationBooking) : Option String` | Observe genuine custody; no interval argument added as an admission condition. |
| Request address | `Singular.requestAddressSpend (u : EconomicUtxo) (tx : EconomicTransaction) (reference : OutRef) (exit : Option RequestExit) : Option String` | Untagged path must survive absent or malformed datum; tagged exits enforce burns. |
| Retraction | `Singular.retractionAccepted (world : World) (u : EconomicUtxo) (tx : EconomicTransaction) : Except String World` | No state access; transaction carries all ordinary funding evidence. |
| Fold | `Singular.foldAccepted (world : World) (u : EconomicUtxo) (tx : EconomicTransaction) : Except String World` | Atomic registry transition and exact economic routing; no legacy approval or admission substituted for booking evidence. |
| Rejection | `Singular.rejectionAccepted (world : World) (u : EconomicUtxo) (r : Rejection) : Except String World` | Reference read and refunds remain shared across grounds; mismatch implementation is separately owned. |

`OnChainRequest` codecs, applied script constructors and booking builder signatures are changed consumers, not authority. Their exact representation must be agreed together; adding default-zero fields to keep old callers compiling is not proof that they build valid new requests. The discovered caller list determines the scope of the signature checkpoint.
