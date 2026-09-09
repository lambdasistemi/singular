# Certification and identity binding

Singular recognizes native requests. Applications decide whether the requested application behavior is authorized. Insert needs evidence of application approval because there is no existing representative NFT leaving an application UTxO. Update/Delete use the application's authorization of that NFT's transfer into the exact request.

## Policy and script roles

| Identity | What it governs |
| --- | --- |
| Registry identity | Which registry and its rules this request belongs to |
| Singular representative policy | Creation and destruction of representative NFTs coupled to registry transitions |
| Configured application policy | Application authorization, including approval of the particular Insert proposal and the source of cancellation authorization |
| Request-token issuing policy | Mints recognized requests; direct use of the application policy versus a separate native request policy remains open |
| Application spending script | Future legal spends of the representative's application UTxO |

The configured application policy ID and an application spending script hash are different roles. One multipurpose script could implement both roles, but sharing a hash is neither required nor forbidden. The same distinction applies to the native policy roles. The eventual implementation must say which roles share code and parameters; this document does not assume separate hashes for all of them.

Writing a policy ID into a request is not enough to make it trusted. The accepted certifier must be authenticated and bound to the registry's rules, so an attacker cannot choose a self-issued certificate. The application policy ID is configured as a Singular parameter; the concrete configuration and binding mechanism remain open. No mandatory global allowlist is selected.

The interface target is **one application-specific parameter: the application policy ID**. Registry identity and native policy settings are separate protocol configuration. Insert initial state and application destination are approved per-request values, not additional fixed application parameters. This target is not yet proved sufficient for a concrete protocol.

The token arrangement is unresolved: the configured application policy may mint the request token itself, or it may provide certification required by a separate native request policy. Both must establish the required approval at request creation. A distinct representative NFT and request token are still required roles; a separate certificate token is not yet selected.

## What Insert exposes and binds

The logical Insert proposal must expose enough information for certification and the native fold to agree on exactly what will be created:

| Logical field | Meaning |
| --- | --- |
| Registry identity | Target registry and associated rules |
| Operation and key | Insert for this exact key |
| Configured application policy identity and evidence | Which configured policy approved this proposal, with evidence bound to its contents |
| Initial application state/datum | The exact initial state required in the representative's output |
| Application destination | The required application spending script and address constraints |
| Representative/output requirements | The representative identity and quantity required by registry rules, plus any other output value constraints that the proposal requires |

The registry target, operation, key, initial state and destination must not be substitutable after certification. Native folding verifies that the created NFT output satisfies the certified requirements. This is a native check of explicit parameters, not a call to arbitrary application logic.

A certificate asset name committing to a canonical request digest is one possible encoding. It has not been selected. Field encoding, hashing, datum representation and certificate minting/consumption rules are not yet a wire protocol.

## Validation without mutable registry observation

The certifier validates application facts and the request proposal, and Singular requires that accepted approval at Insert request minting. Native format alone cannot authorize Insert; otherwise arbitrary non-application datums could claim keys. It need not read the current registry root or promise that Insert will succeed. Singular checks the current key state when applying the operation.

For Update/Delete, the application spending validator approves the operation-specific transfer of the existing NFT. Native request admission validates the resulting request. Neither step needs the mutable registry UTxO merely to establish that release authorization.

Authenticated registry configuration may still be needed. The design must bind the registry, request/representative policies, certifier and application destination without circular script-hash dependencies. No concrete configuration layout or hash-cycle solution has been selected.

## Decisions still required

| Decision | Constraint already fixed |
| --- | --- |
| Registry and policy configuration | Accepted certification must be authentic; arbitrary self-selected issuers are insufficient |
| Request-token issuer and certificate arrangement | Choose direct application-policy minting or certification required by a native request policy |
| Request/certificate encoding and lifecycle | Bind the exact operation and effects; prevent request acceptance after completion |
| Insert withdrawal and refunds | Withdrawal is allowed; authorization comes from the configured application policy, not a native owner/signature rule; specify fresh action/binding/refunds without assuming original Insert approval permits cancellation |
| Representative identity across Delete/reinsert | A deleted key may be registered again; old signatures or certificates must not silently authorize a fresh incarnation |
| Batch selection and limits | Operations follow successive MPF states; no arbitrary skip semantics or capacity claim is assumed |
| Implementation and shared libraries | Singular owns these application semantics; old MPFS code or proofs do not automatically establish them |

This is an adopted design with unresolved construction details. There is no implementation, completed proof, universal application language or mandatory general-purpose validation plugin in this repository.
