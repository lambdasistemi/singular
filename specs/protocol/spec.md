# Singular protocol specification — draft

This specification derives from the [overview](../../docs/overview.md), [lifecycle](../../docs/lifecycle.md) and [certification design](../../docs/certification.md). It records required behavior, not an implemented wire protocol. **MUST** and **MUST NOT** express requirements of the intended protocol. Open decisions below prevent treating this as a complete implementation contract.

## Purpose and scope

Singular is a permissionless registry on Cardano for unique identities and independent application state. It uses an authenticated MPF map and representative NFTs. This specification covers registry operations, native requests, certification and custody. It does not select an implementation language, a certificate encoding, a generic application plugin, a KERI integration or a shared-library API.

## Entities and terminology

A registry has an authenticated identity and a map from keys to payload-free `Active` or `Over` values. An absent key has no entry. A representative NFT identifies the active registration of a key within its registry. An Insert request UTxO carries an application-minted Insert action token; Update/Delete requests carry the existing representative. Any additional Update/Delete request-token construction remains open. A configured application policy provides the application authorization anchor, including accepted approval for Insert. The application spending script governs legal spends of the application's NFT UTxO.

Registry identity, representative policy, request-token issuance, application authorization policy and application spending script are distinct semantic roles. Their actual script hashes may coincide if an implementation shares a script; this specification neither requires nor forbids that sharing.

The design interface target is one application-specific parameter: the configured application policy ID. Registry identity and native policy settings are separate protocol configuration; Insert initial state and destination are approved per-request values. Sufficiency of this interface for a concrete protocol is not yet proved. The application policy mints Insert and Withdraw action tokens directly. Singular recognizes the configured policy ID and recomputes their action-bound asset names; no second mandatory native request policy/token is required for these actions.

**Withdraw** cancels a pending Insert; it is neither registry Delete nor a staking-reward withdrawal/plugin invocation. Registry **Update** means retirement. An **application update** means an application-defined state transition and is not a registry operation.

## Required behavior

### R1. Registry transitions and representative supply

A successful fold MUST apply only these transitions and their coupled representative effects:

| Operation | Required prior state | Resulting state | Representative effect |
| --- | --- | --- | --- |
| Insert | Absent | `Active` | Mint exactly the registry-prescribed unique representative into the certified application output |
| Update | `Active` | `Over` | Burn the existing representative carried by the request |
| Delete | `Active` | Absent | Burn the existing representative carried by the request |

`Over` MUST be terminal. An `Over` key MUST have no live representative. Delete MUST permit a later Insert for that key, subject to approval valid for that registration and absence at that later fold. No alternative Update pair is supported.

`Active` MUST denote an outstanding representative, including while that representative is in a pending request. It MUST NOT assert an application's usability or local business state. The registry values MUST contain no application payload.

### R2. Native request construction

Insert and Withdraw MUST use action tokens minted under the configured application policy. Request admission MUST validate the applicable native structure, operation, exact registry/key or request binding and custody. Singular MUST recognize the configured policy ID and recompute the expected action-bound asset name. Tokens issued by an arbitrary substitute policy MUST NOT be accepted. Any additional Update/Delete request token and its issuer remain a construction detail under D2.

Action-token asset names MUST hash an unambiguous canonical encoding with domain separation between Insert and Withdraw. The specific hash function and binary schema remain open.

The application constructs the transaction; the configured application policy ID is its authorization anchor. Request creation MUST be supportable without observing the mutable registry UTxO. This requirement does not prohibit application inputs, transaction-context checks or authenticated registry configuration.

### R3. Insert approval at request minting

Minting an Insert request token MUST require accepted application certification of the exact proposal. Native format validity alone MUST NOT authorize Insert. The certification MUST bind:

- target registry, Insert operation and key;
- configured application policy identity and evidence;
- initial application state/datum;
- destination application spending script and address constraints;
- representative identity/quantity as prescribed by registry rules and any other declared output value/effect constraints.

The application policy ID MUST be an authenticated Singular parameter bound to the registry's rules. A requester MUST NOT gain approval by choosing an arbitrary self-issued policy. The certification mechanism MUST prevent substitution of any bound field after approval.

Approval MUST be established when the Insert request token is minted; this requirement is not deferred to folding. The configured application policy MUST mint the Insert action token directly. Its asset name MUST commit to the Insert tag, registry, key, initial application datum, destination and declared required effects. Singular MUST recompute and match this name. Certification MUST NOT be treated as a reservation of the key or a guarantee of inclusion/order.

### R4. Insert pending, completion and withdrawal

A pending Insert request MUST contain no representative NFT. A representative for its requested key may already exist elsewhere: admission of an Insert request does not assert absence.

Successful folding MUST check absence in the applicable successive registry state and MUST produce exactly the representative output specified by the certified proposal, including its destination and initial state. Registry insertion and representative creation MUST occur atomically in that folding transaction. The fold MUST NOT accept Insert for an occupied key.

Insert requests MUST support withdrawal before successful folding. Withdrawal MUST NOT change registry state or mint a representative. Cancellation authorization MUST originate from a separate Withdraw action token minted by the configured application policy. Its asset name MUST commit to the Withdraw tag, registry, exact pending Insert UTxO and required refund terms/effects. Singular MUST check the configured policy and this exact action binding when consuming the pending Insert. An Insert action token alone MUST NOT authorize Withdraw.

The application's approval conditions, precise refund economics and token disposal remain open under D2/D3. No representative minting or registry transition is permitted during Withdraw. The protocol MUST NOT interpret withdrawal availability as arbitrary access to deposits or arbitrary cancellation authority.

### R5. Update/Delete application authorization

An Update/Delete request MUST carry the existing authentic representative for its exact registry/key, at the Singular request address. An additional request token, if any, is a construction detail under D2.

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

Approval from a previous registration MUST NOT authorize a later incarnation outside its certified scope. If approval was limited to the previous incarnation, the later registration needs fresh approval; deliberately reusable approval is not ruled out if the application protocol selects and bounds it. A concrete scope/incarnation-binding rule is required under D4. UTxO single-spend alone MUST NOT be presented as establishing this broader property.

## Acceptance scenarios

These scenarios are specification obligations. **They have not been executed as tests or proved.** The branch's Markdown checks do not validate them.

| Scenario | Required outcome | Requirements |
| --- | --- | --- |
| Approved Insert, absent key, correct initial output | Fold creates one representative and an `Active` entry together | R1, R3, R4 |
| Well-formed Insert with no accepted application approval | Native request minting refuses it | R2, R3 |
| Requester supplies its own unaccepted certification policy | Native request minting refuses it | R3 |
| Registry, key, operation, initial datum or destination changed after certification | Altered proposal/output cannot be accepted using that approval | R3, R4 |
| Two certified pending Inserts target one key | Only an Insert seeing absence may succeed; certification reserves neither request's place | R4, R7 |
| Withdraw action token binds exact pending Insert and required effects | Consume that Insert with no representative mint or registry mutation; concrete refund/disposal cases require D2/D3 | R2, R4 |
| Insert token alone or a Withdraw token for a different pending Insert is supplied to cancel | Withdrawal refuses the mismatched authorization | R2, R4 |
| Application performs a legal local state transition | Existing representative can move to its successor application UTxO without registry Update | R1, R5 |
| Application authorizes Delete, transaction substitutes Update | Exact-release authorization fails | R5 |
| Valid Update/Delete request is formed without reading mutable registry | Native request admission can succeed from application authorization, binding and custody | R2, R5 |
| A third party tries to withdraw the NFT from pending Update/Delete | Custody refuses the escape | R6 |
| Update completes | Representative burned; key becomes terminal `Over` | R1, R6 |
| Delete completes, then a new approved Insert is folded | Representative burned at Delete; new representative created only on the later absent-key Insert | R1, R4, R8 |
| A request names the right key but carries another registry's representative | Native binding rejects it | R2, R5 |
| A completed request or approval outside its certified incarnation/scope is replayed | Rejected; approval reuse within its intended scope and its concrete binding depend on D2/D4 | R6, R8 |
| A valid transaction is submitted by an unrelated folder | No privileged actor gate rejects it | R7 |

A concrete protocol must also demonstrate conservation of representative supply and custody across every allowed transaction shape, including attempts to bypass request creation or to mint/burn outside the coupled registry transitions.

## Open decisions

| ID | Required decision | Constraint on its resolution |
| --- | --- | --- |
| D1 | Registry identity/configuration and policy binding, including hash dependencies | Use the configured application policy ID as authorization anchor; target one application-specific parameter without claiming proved sufficiency; no global allowlist or specific hash-cycle solution is selected |
| D2 | Canonical action encoding/hash, token lifecycle and optional Update/Delete token construction | Insert/Withdraw are direct application-policy action assets; bind actions and parameters unambiguously with domain separation; specify reuse/disposal and prevent acceptance beyond certified scope |
| D3 | Withdraw approval conditions, refund economics and disposal | Separate application-policy Withdraw asset binds exact pending Insert and required effects; preserve deposits and registration attempts; Insert approval alone cannot cancel |
| D4 | Representative identity and approval replay protection across Delete/reinsert | Preserve key reuse and any deliberately authorized certificate reuse while rejecting approval outside its certified scope; choose and specify an effective fence |
| D5 | Batch selection, failure presentation and limits | Preserve sequential MPF semantics; do not assume automatic skipping of failing requests or a measured capacity advantage |
| D6 | Concrete transaction shapes and reusable library interfaces | Establish native supply/custody invariants; old MPFS proofs are not proof of Singular's protocol |

Resolving these decisions, implementing the protocol, proving its properties and verifying its ledger behavior are subsequent work. No mandatory general-purpose application callback or KERI lifecycle mapping is introduced here.
