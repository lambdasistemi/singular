# Certification and identity binding

Singular recognizes native requests. Applications decide whether the requested application behavior is authorized. Insert needs evidence of application approval because there is no existing representative NFT leaving an application UTxO. Update/Delete use the application's authorization of that NFT's transfer into the exact request.

## Policy and script roles

| Identity | What it governs |
| --- | --- |
| Registry identity | Which registry and its rules this request belongs to |
| Singular representative policy | Creation and destruction of representative NFTs coupled to registry transitions |
| Singular request policy | Minting request tokens subject to native request format, binding and custody rules |
| Application certification policy | Approval of the particular Insert proposal |
| Application spending script | Future legal spends of the representative's application UTxO |

A certification policy ID and an application spending script hash are different roles. One multipurpose script could implement both roles, but sharing a hash is neither required nor forbidden. The same distinction applies to Singular's policy roles. The eventual implementation must say which roles share code and parameters; this document does not assume separate hashes for all of them.

Writing a policy ID into a request is not enough to make it trusted. The accepted certifier must be authenticated and bound to the registry's rules, so an attacker cannot choose a self-issued certificate. The configuration and trust-binding mechanism remain open; no mandatory global allowlist is selected.

## What Insert exposes and binds

The logical Insert proposal must expose enough information for certification and the native fold to agree on exactly what will be created:

| Logical field | Meaning |
| --- | --- |
| Registry identity | Target registry and associated rules |
| Operation and key | Insert for this exact key |
| Certification policy identity and evidence | Which accepted policy approved this proposal, with evidence bound to its contents |
| Initial application state/datum | The exact initial state required in the representative's output |
| Application destination | The required application spending script and address constraints |
| Representative/output requirements | The representative identity and quantity required by registry rules, plus any other output value constraints that the proposal requires |

The registry target, operation, key, initial state and destination must not be substitutable after certification. Native folding verifies that the created NFT output satisfies the certified requirements. This is a native check of explicit parameters, not a call to arbitrary application logic.

A certificate asset name committing to a canonical request digest is one possible encoding. It has not been selected. Field encoding, hashing, datum representation and certificate minting/consumption rules are not yet a wire protocol.

## Validation without mutable registry observation

The certifier validates application facts and the request proposal, and Singular requires that accepted approval at Insert request minting. Native format alone cannot authorize Insert; otherwise arbitrary non-application datums could claim keys. It need not read the current registry root or promise that Insert will succeed. Singular checks the current key state when applying the operation.

For Update/Delete, the application spending validator approves the operation-specific transfer of the existing NFT. Singular's request policy validates the resulting native request. Neither step needs the mutable registry UTxO merely to establish that release authorization.

Authenticated registry configuration may still be needed. The design must bind the registry, request/representative policies, certifier and application destination without circular script-hash dependencies. No concrete configuration layout or hash-cycle solution has been selected.

## Decisions still required

| Decision | Constraint already fixed |
| --- | --- |
| Registry and policy configuration | Accepted certification must be authentic; arbitrary self-selected issuers are insufficient |
| Request/certificate encoding and lifecycle | Bind the exact operation and effects; prevent request acceptance after completion |
| Insert withdrawal and refunds | Withdrawal is allowed; no representative mint or registry change; protect funds and resolve who may cancel so outsiders cannot repeatedly prevent registration |
| Representative identity across Delete/reinsert | A deleted key may be registered again; old signatures or certificates must not silently authorize a fresh incarnation |
| Batch selection and limits | Operations follow successive MPF states; no arbitrary skip semantics or capacity claim is assumed |
| Implementation and shared libraries | Singular owns these application semantics; old MPFS code or proofs do not automatically establish them |

This is an adopted design with unresolved construction details. There is no implementation, completed proof, universal application language or mandatory general-purpose validation plugin in this repository.
