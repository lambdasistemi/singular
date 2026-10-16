# Model mapping and acceptance mandate

## Story

As an integrator, I want each promised behavior tied to the actual accepted declaration and its observation boundary, so that neither a theorem name nor a green test count substitutes for the transaction I need.

The model revision and tree are fixed in the [specification](spec.md). Statement identities and digests come from the [release record](../494-protected-rejection-rule/contracts/release-record.md) and `lean/theorem-debt.json`; do not duplicate or hand-edit that register. The legacy driver is not the economic oracle.

| Behavior | Authoritative definitions | Required implementation observation |
|---|---|---|
| Registration contents and clock | `Singular.registrationBookingRefusal`, `registrationContentsShape`, `registrationDeclaredLovelace`, `RegistrationRequest.operation` | Actual output value, inline datum, policy mint, full nonce commitments and finite interval; refuse surplus separately from insufficient contents. |
| Termination booking | `Singular.terminationBookingRefusal`, `terminationExactContents`, `terminationCustody` | Genuine singular tag transferred from real custody; no application tag, refund or clock. Consumer conflict remains held. |
| Tag commitments | `Singular.applicationTagAssetName`, `trieReadyTagAssetName`, `Config.trieReadyTag` | Concrete canonical preimages are compared across Aiken and Haskell. Domain separation, nonce and all declared operation fields survive translation. No hash injectivity theorem is claimed. |
| Sweep and disposal | `Singular.requestAddressSpend`, `sweepAccepted`, `requestTagsBurned` | Absence of the registry's trie-ready tag permits junk collection before datum/redeemer decoding can strand it; genuine tagged inputs require exact same-transaction disposal. |
| Retraction | `Singular.retractionRefusal`, `retractionInputsRefusal`, `retractionFundingRefusal`, `retractionAccepted` | One registration, signing refund address, whole reclaim interval, no state read/spend, ordinary funding, full per-address refund, zero donation and balance. Ledger rules may discharge duplicate-input/balance constraints only with explicit boundary evidence. |
| Expiry rejection | `Singular.rejectionRefusal`, `rejectionAccepted`, `refundObligations`, `refundRefusal` | Current authenticated reference state, no state spend, distinct requests, shared interval, expiry at both-window threshold, tag burns and summed actual refunds. |
| Economic fold | `Singular.foldAccepted`, `foldPrerequisite`, `foldMemberRefusal`, `foldRoutingRefusal`, `foldLegacyRequest` | Observed state consumption/continuation, actual tag burns, registration carrier/datum, exact donation, ordinary funding and gross-tip conservation. Termination has no processing deadline. |
| Discovery | Booking tag provenance plus issue 529's provider requirement | The real provider's indexed selection and number of read/decoded candidates, under planted junk; no address scan hidden behind a tag filter. |
| Public evidence | Constitution principles III, IV and VI | Actual receipt-derived state, observed values independent of builder expectations, public uncovered rows, no old economic row relabelled fulfilled. |

## Invariants the writer must preserve

A different registry, key, refund address, destination, operation allocation or nonce cannot reuse an authorization intended for another request. A moved tag cannot authenticate a different output condition. Every positive control has a reachable or explicitly constructed premise with its boundary named. Every adverse control invokes the actual policy, validator, provider or ledger boundary it claims to check.

No burn policy adds an owner, expiry or proof condition. No termination is expired, rejected or retracted. No rejection spends the state. No retraction reads the state. Refunds are obtained from transaction outputs, not builder predictions; two obligations sharing an address are not paid by one unsummed floor. Carrier ada is declared and checked exactly; ledger minimum calculation remains a separate builder obligation.

No code is accepted against an invented model reading. No conformance row is marked fulfilled because an old driver agrees with an old validator. Existing unmet economics remain published until evidence for their replacement exists. The issue's connected CLI/devnet obligations remain part of this ticket.

## Authority and checkpoints

The ticket owner owns these planning files, gates and acceptance. The approved Sonnet commit owner owns all code, tests, generated implementation and signed slice commits. The approved Sol auditor is mute, read-only and zero-execution, sees committed checkpoints and receipts, and answers through the ticket owner. There is no additional seat and no draft tool.

Checkpoints are the RED bundle, each requirement's GREEN evidence and pre-push. The writer continues while review runs; push requires every checkpoint approved. Concrete blocked findings are consolidated and forwarded once. An unresolved semantic finding becomes a parent question, never an expectation change.
