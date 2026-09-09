# Singular protocol specification — draft

This specification derives from the [overview](../../docs/overview.md), [lifecycle](../../docs/lifecycle.md) and [certification design](../../docs/certification.md). It records required behavior, not an implemented wire protocol. **MUST** and **MUST NOT** express requirements of the intended protocol. Open decisions below prevent treating this as a complete implementation contract.

## Purpose and scope

Singular is a permissionless registry on Cardano for unique identities and independent application state. It uses an authenticated MPF map and representative NFTs. This specification covers registry operations, native requests, certification and custody. It does not select an implementation language, a certificate encoding, a generic application plugin, a KERI integration or a shared-library API.

## Entities and terminology

A registry has an authenticated identity and a map from keys to payload-free `Active` or `Over` values. An absent key has no entry. A representative NFT identifies the active registration of a key within its registry. A request UTxO carries a native request token; Update/Delete requests also carry the existing representative. A configured application policy provides the application authorization anchor, including accepted approval for Insert. The application spending script governs legal spends of the application's NFT UTxO.

Registry identity, representative policy, request-token issuance, application authorization policy and application spending script are distinct semantic roles. Their actual script hashes may coincide if an implementation shares a script; this specification neither requires nor forbids that sharing.

The design interface target is one application-specific parameter: the configured application policy ID. Registry identity and native policy settings are separate protocol configuration; Insert initial state and destination are approved per-request values. Sufficiency of this interface for a concrete protocol is not yet proved. Whether the application policy mints request tokens directly or supplies certification to a separate native request policy remains open.

Registry **Update** means retirement. An **application update** means an application-defined state transition and is not a registry operation.

## Required behavior

### R1. Registry transitions and representative supply

A successful fold MUST apply only these transitions and their coupled representative effects:

| Operation | Required prior state | Resulting state | Representative effect |
| --- | --- | --- | --- |
| Insert | Absent | `Active` | Mint exactly the registry-prescribed unique representative into the certified application output |
| Update | `Active` | `Over` | Burn the existing representative carried by the request |
| Delete | `Active` | Absent | Burn the existing representative carried by the request |

`Over` MUST be terminal. An `Over` key MUST have no live representative. Delete MUST permit a later Insert for that key, subject to fresh valid approval and absence at that later fold. No alternative Update pair is supported.

`Active` MUST denote an outstanding representative, including while that representative is in a pending request. It MUST NOT assert an application's usability or local business state. The registry values MUST contain no application payload.

### R2. Native request construction

A recognized request MUST carry a minted token whose issuance establishes the required authorization and native request validity. Request admission MUST validate structure, operation, exact registry/key binding and required custody in the creating transaction. The issuing-policy arrangement is D2: direct minting by the configured application policy or certification checked by a separate native request policy. A token issued by an arbitrary substitute policy MUST NOT be accepted as a recognized request token.

The application constructs the transaction; the configured application policy ID is its authorization anchor. Request creation MUST be supportable without observing the mutable registry UTxO. This requirement does not prohibit application inputs, transaction-context checks or authenticated registry configuration.

### R3. Insert approval at request minting

Minting an Insert request token MUST require accepted application certification of the exact proposal. Native format validity alone MUST NOT authorize Insert. The certification MUST bind:

- target registry, Insert operation and key;
- configured application policy identity and evidence;
- initial application state/datum;
- destination application spending script and address constraints;
- representative identity/quantity as prescribed by registry rules and any other declared output value/effect constraints.

The application policy ID MUST be an authenticated Singular parameter bound to the registry's rules. A requester MUST NOT gain approval by choosing an arbitrary self-issued policy. The certification mechanism MUST prevent substitution of any bound field after approval.

Approval MUST be established when the Insert request token is minted; this requirement is not deferred to folding. Direct application-policy request minting and a separate certificate/native-request-policy arrangement are unresolved alternatives, not simultaneous requirements. Certification MUST NOT be treated as a reservation of the key or a guarantee of inclusion/order.

### R4. Insert pending, completion and withdrawal

A pending Insert request MUST contain no representative NFT. A representative for its requested key may already exist elsewhere: admission of an Insert request does not assert absence.

Successful folding MUST check absence in the applicable successive registry state and MUST produce exactly the representative output specified by the certified proposal, including its destination and initial state. Registry insertion and representative creation MUST occur atomically in that folding transaction. The fold MUST NOT accept Insert for an occupied key.

Insert requests MUST support withdrawal before successful folding. Withdrawal MUST NOT change registry state or mint a representative. Cancellation authorization MUST originate from the configured application policy, rather than a native Singular owner or signature permission rule. The exact authorization action, its binding to the pending request, conditions, refund handling and token/certificate disposal are unresolved under D3 below. Original Insert approval MUST NOT automatically be treated as cancellation approval; withdrawal availability does not authorize arbitrary third-party cancellation or arbitrary access to deposits.

### R5. Update/Delete application authorization

An Update/Delete request MUST carry the existing authentic representative for its exact registry/key, together with the native request token, at the Singular request address.

The application spending validator MUST authorize transfer from application custody into that exact request, including operation, registry/key and destination. The application remains responsible for the legality of the release under its own rules. Mere NFT spendability MUST NOT be treated as blanket authorization of any registry operation.

Native request admission MUST check format, binding and custody. It MUST NOT require a second application attestation token solely to repeat a valid operation-specific release authorization. The application MUST NOT be able to bypass Singular's representative supply or request custody requirements.

### R6. Update/Delete custody and completion

Pending Update/Delete requests MUST retain their representative until valid completion. They MUST NOT support ordinary withdrawal, rejection or sweep that releases it.

Valid completion MUST consume the request, burn its representative and apply its specified registry transition atomically. A pending representative MUST NOT also remain available for independent application rotation. A completed request MUST NOT be accepted again; the concrete request-token lifecycle must satisfy this requirement.

### R7. Folding and actor permissions

A fold MUST apply requests against successive authenticated map states, including Insert absence and Update/Delete existing-value checks. Certification recognition and explicit native output checks MUST establish the required native effects without a requirement to repeat arbitrary application validation during the fold.

Singular MUST impose no native owner, privileged requester or privileged folder gate. Anyone MAY submit a transaction satisfying the applicable protocol requirements. This does not remove application validation or establish inclusion fairness.

### R8. Replay and reincarnation

The custody rules MUST prevent two simultaneous pending Update/Delete requests from holding the same authentic representative. Consuming a request UTxO MUST prevent consuming that same UTxO again.

A later registration after Delete MUST NOT become authorized merely by replaying approval material from its previous incarnation. A concrete incarnation-binding rule is required under D4. UTxO single-spend alone MUST NOT be presented as establishing this broader property.

## Acceptance scenarios

These scenarios are specification obligations. **They have not been executed as tests or proved.** The branch's Markdown checks do not validate them.

| Scenario | Required outcome | Requirements |
| --- | --- | --- |
| Approved Insert, absent key, correct initial output | Fold creates one representative and an `Active` entry together | R1, R3, R4 |
| Well-formed Insert with no accepted application approval | Native request minting refuses it | R2, R3 |
| Requester supplies its own unaccepted certification policy | Native request minting refuses it | R3 |
| Registry, key, operation, initial datum or destination changed after certification | Altered proposal/output cannot be accepted using that approval | R3, R4 |
| Two certified pending Inserts target one key | Only an Insert seeing absence may succeed; certification reserves neither request's place | R4, R7 |
| Authorized withdrawal of a pending Insert | No representative minted and no registry mutation; authority/refund cases require D3 | R4 |
| Application performs a legal local state transition | Existing representative can move to its successor application UTxO without registry Update | R1, R5 |
| Application authorizes Delete, transaction substitutes Update | Exact-release authorization fails | R5 |
| Valid Update/Delete request is formed without reading mutable registry | Native request admission can succeed from application authorization, binding and custody | R2, R5 |
| A third party tries to withdraw the NFT from pending Update/Delete | Custody refuses the escape | R6 |
| Update completes | Representative burned; key becomes terminal `Over` | R1, R6 |
| Delete completes, then a new approved Insert is folded | Representative burned at Delete; new representative created only on the later absent-key Insert | R1, R4, R8 |
| A request names the right key but carries another registry's representative | Native binding rejects it | R2, R5 |
| A completed request or previous-incarnation authorization is replayed | Rejected; previous-incarnation construction depends on D4 | R6, R8 |
| A valid transaction is submitted by an unrelated folder | No privileged actor gate rejects it | R7 |

A concrete protocol must also demonstrate conservation of representative supply and custody across every allowed transaction shape, including attempts to bypass request creation or to mint/burn outside the coupled registry transitions.

## Open decisions

| ID | Required decision | Constraint on its resolution |
| --- | --- | --- |
| D1 | Registry identity/configuration and policy binding, including hash dependencies | Use the configured application policy ID as authorization anchor; target one application-specific parameter without claiming proved sufficiency; no global allowlist or specific hash-cycle solution is selected |
| D2 | Request-token issuer, logical-to-wire encoding and request/certificate lifecycle | Choose application-policy request minting or separate certification/native-request-policy composition; bind the whole proposal and effects; prevent acceptance after completion; specify reuse/consumption and token disposal |
| D3 | Insert withdrawal authorization action, cancellation conditions and refund disposition | Authorization comes from the configured application policy; specify exact-request binding and protect funds/registration attempts; original Insert approval is not automatic cancellation approval |
| D4 | Representative identity and approval replay protection across Delete/reinsert | Preserve key reuse while preventing stale approval from authorizing a new incarnation; choose and specify an effective fence |
| D5 | Batch selection, failure presentation and limits | Preserve sequential MPF semantics; do not assume automatic skipping of failing requests or a measured capacity advantage |
| D6 | Concrete transaction shapes and reusable library interfaces | Establish native supply/custody invariants; old MPFS proofs are not proof of Singular's protocol |

Resolving these decisions, implementing the protocol, proving its properties and verifying its ledger behavior are subsequent work. No mandatory general-purpose application callback or KERI lifecycle mapping is introduced here.
