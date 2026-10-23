# Records needed to decide the proposal

As a model reviewer, I want to see exactly what an identity or evidence record contains and which assertions are still hypothetical.

| Record | Required fields and relationships | Validation |
|---|---|---|
| Authority binding | repository revision, path, declaration, digest, acceptance status and source of ruling | Source presence does not imply acceptance; changed identities reopen dependent evidence. |
| Candidate identity | application identity, state-policy identity, registry asset name, token kind and canonical key | Keep complete policy/name identity; do not erase policy until the claimed cross-policy uniqueness is proved under accepted premises. |
| Naming premise | exact preimage encoding, hash domain, applicable finite preimage set, explicit proposition and satisfying witness | Unambiguous encoding and collision assumptions are separate; no unconditional finite-hash injectivity. |
| Ledger case | accepted-history prefix, seed reference, policies invoked, input/output assets, redeemers and candidate state effect | Same-transaction multiple-policy use differs from across-history reuse; reuse #679/#680 vocabulary when bound. |
| Custody observation | key, registry, holder role, pending request identity, active asset, available evidence and observation provenance | Count genuine tokens in application custody and pending requests; missing evidence cannot prove terminal/never registered. |
| Changed obligation | readable guarantee, old declaration/digest, candidate declaration/digest, premise, consumer list and disposition | Every changed definition/theorem/observation is preserved, restated, retired by ruling or explicitly unresolved. |
| Decision evidence | candidate, command, actual exit, proof/axiom or counterexample pointers, audit stage and uncovered implementation claims | PROVED, REFUTED and OPEN remain distinct; only the operator rules on a semantic conflict. |

## Configuration and application controls

The bound root `Config` contains the four policy pins plus root, minimum tip, processing/reclaim windows, registry identity, registration cost and booking width. The four-field proposal is not adopted by this plan. The investigation must account for each field and preserve every required economic obligation.

The bound application has a registry-parameterized `App` and protected `Control` fields. Changing that dependency requires a recorded comparison of controller update, genuine-token release and pending-custody behavior. This table specifies no replacement wire datum.

```mermaid
flowchart TD
  Binding[Authority binding] -->|governs| Obligation[Changed obligation]
  Case[Reachable ledger case] -->|exhibits| Obligation
  Obligation -->|evaluated as| Evidence[Proof or counterexample]
  Evidence -->|supports| Ruling[Operator decision]
```

## Frozen candidate records

These records are hypotheses under the identity, role and hash questions, constrained by the complete-identity ruling. They define no ledger laws or wire migration.

| Record | Fields or constructors | Scope |
|---|---|---|
| `Payload` | `edge key owner destination nonce : Nat` | Existing authorization tuple and booking nonce remain explicit. |
| `Role` | `state witness trieReady application` | Four classification cases, discovered from compiled constructors. |
| `Binding` | `full nameOnly` | Ruled complete binding and rejected name-only contrast. |
| `Reading` | `policyOnly authenticated` | Unresolved recognition alternatives. |
| `Preimage` | `application release`; `statePolicy appPolicy`; `seed OutRef`; `role Role TokenId key`; `approval TokenId Payload` | Tagged structural domains with complete identities. Name-only contrast replaces the policy component by zero. |
| `Observation` | `asset : TokenId`, `stateDatum : Bool`, `provenance : TokenId` | Provenance is explicit authenticated-origin evidence with external validity still a premise. Fabricating a datum changes no asset or provenance. |
| `TxOutput` | `assets : List (TokenId × Nat)` | Asset counts only; no fee or script semantics. |
| `TxView` | `spent : List OutRef`, `outputs : List TxOutput`, `mint : List (TokenId × Int)`, `invoked : List Nat` | Observation only; quantities sum per complete asset; history is a list of views. |
| `Query`, `Scenario` | Named public case, finite hash table, explicit application/registry/payload/key/assets, observation, seed, transaction and history; scenario adds a mutation selector | Generic oracle input only, with no theorem-specific projection. `none` selects the candidate; other selectors serve the mutant ledger. |
| `Guard` | Full/name-only approval, policy-state, four authenticated roles, genesis seed count, history uniqueness | Selector is `none` or `flip Guard`; exactly one guard changes. |
| Statement ledger | theorem, compiled statement digest, status, question/ruling, witness declarations, selectors, optional inversion case | Rejected readings have a separate status marker. |
| Mutant ledger | theorem, selector, premise/positive/falsification declarations | Candidate and selector evaluate the same instance; no unrelated mutant function. |

The minimal transaction view must later bind to accepted ledger/history vocabulary, as [impact.md](impact.md) records. It cannot establish ledger validity, lineage, custody, supply or real hash collision freedom. Economic configuration and the termination custody ruling belong to subsequent stages.

## Frozen application-held records

The records below belong only to NoPin.Held. They are explicitly hypothetical. They specify no wire layout, policy implementation or cancellation ruling. The public application address family is distinct from logical custody classification.

| Record | Fields and meaning |
|---|---|
| Control | registry : TokenId; key, controller, deposit : Nat |
| Holding | reference : OutRef; family : Nat; control : Control; token : TokenId; quantity : Nat; provenance : TokenId; rootHolding : Singular.Holding; payload, lovelace : Nat. Complete identity and authenticated origin are explicit, never inferred from payload. |
| Pending | holding : Holding; booking : Singular.TerminationBooking. The fresh holding reference equals the retained request reference; family/control/token/payload are retained from the spent live holding; root exact contents determine tags and the root value allocation; physical lovelace adds the disjoint protected deposit. |
| LockedOutput | live Holding or pending Pending. Tagged, disjoint states; address equality does not erase the tag. |
| ApplicationState | registryIdentity : TokenId; registry : Singular.RegistryState; registrations : Singular.RequestPool; outputs : List LockedOutput; treasury : Nat. The economic projection uses these actual records and preserves the root configuration/trie/treasury. |
| LiveSpend | update or release. Derived from OpenDatumSpend; no controller-change path. Both are refused for pending records. |
| LocalPayment | output index, controller payment-key identity and observed lovelace. Bound to the same transaction outputs by explicit correspondence, not expected amounts. |
| LocalTransaction | assets : NoPin.TxView; spent : List Pending; payments : List LocalPayment. No state or request-validator credential. Retained deposits can be summed locally; registryOwed and carrier eligibility cannot be recovered from these fields. |
| FoldObservation | registryIdentity : TokenId; before, after : Singular.World; unspent : Singular.EconomicUtxo; transaction : Singular.EconomicTransaction. Accepted outcome is an explicit proposition over Singular.foldAccepted; no duplicated fold function. |
| Case, Guard, Mutation | Separate compiled pending-case and guard inventory; none selects the candidate, flip selects one atomic guard. Does not alter the existing identity selectors. |

Authentication, supply and availability statements name the explicit root projection and its reachability premises. Root abstract tags and candidate shared-policy assets require a named correspondence; new identities use the existing parameterized NoPin hash/codec, never the root FNV stand-ins. Calling the unchanged root admission reads its accepted tag definition and does not adopt that stand-in as a new cryptographic construction.

## Authorized slice-4 physical value partition

A-003 amends the approved pending-output value surface. Holding.lovelace is physical value: pending root request.contents.lovelace plus control.deposit. These are disjoint allocations. The root request itself still contains exactly its declared tip plus carrier, with no protected deposit hidden inside that amount.

PhysicalOutput records output index, optional controller address and physical lovelace. PhysicalView records reference/value input pairs, indexed physical outputs and explicit index/deposit allocations. A FoldObservation records the unchanged economic world before and after, observed unspent set and actual economic transaction. LocalTransaction keeps the minimal TxView plus selected pending records and indexed physical payments. Its local settlement sums deposits by application family and controller, and refuses repeated payment indices.

The valuePartition correspondence subtracts the retained deposit from each physical pending input and each allocated controller output to obtain the root observer's amounts. It proves no fact about the provider or ledger. A two-holding instance uses deposits five and seven; its root and physical balances and twelve-lovelace controller payment must be computed. Overlapping the deposit with root contents and omitting its physical payment are required violating twins.

The observed ApplicationState and FoldObservation also carry registryIdentity : TokenId. This labels the accepted abstract world with its independently observed complete registry token. The named correspondence checks policy and name, while authentication of this label and interpretation of the root registryId remain upstream debt. Booking binds the controller registry to that observed identity and binds the request key/custody to the retained token.

## Frozen shared-request records

As a requester, I want my registration to name its complete registry and its own booked parameters, so that sharing a script cannot substitute another registry's identity or reclaim windows. These records belong to the hypothetical NoPin.Shared family. They define no accepted wire format, ledger evaluator or parameter removal. All earlier records and statement rows remain unchanged.

| Record | Frozen fields and ownership |
|---|---|
| PublishedRelease | applicationCredential, requestCredential, stateProgram, statePolicy : Nat. Shared application and request credentials and the once-applied state policy are authenticated release constants. The state program is a publisher input only. |
| ApplyState | Nat → Nat → Nat, an explicit publisher-side program/application interpretation. PublishedReleaseCorrespondence states statePolicy = applyState stateProgram applicationCredential; the client never receives or calls ApplyState. Concrete application/hash correspondence remains external debt. |
| RegistrationData | reference : OutRef; key, refundAddress, destination, submittedAt, registrationCost, declaredTip, carrierAda, nonce : Nat; datum : Option Nat. All fields come from public booked data. No asset name is a field in its own preimage. |
| RequestDatum | registry : Singular.TokenId; configuration : Singular.Config; payload : RegistrationData. The complete configuration snapshot is retained for this abstract candidate, including all economic fields. It is not a claim about the final pin-free wire layout. Root and pins retain their existing abstract meanings. |
| Preimage | witness(registry,key); registrationReady(registry,configuration,payload); registrationApproval(registry,configuration,payload). These are three distinct constructors, each registry a complete TokenId. Seed naming remains NoPin.stateName. Exact constructor numbers and bytes are not frozen here. |
| Codec, Hash | Preimage → List Nat and List Nat → Nat. CanonicalSerialisation means codec separates the explicitly finite occurring preimages. FiniteCollisionFree separately means hash separates their distinct encodings. Neither is unconditional injectivity. |
| RequestOutput | reference : OutRef; credential : Nat; datum : RequestDatum; lovelace : Nat; ready, approvals, otherAssets : List (TokenId × Nat). Actual quantities, exact datum and address are observed together. Absence of tags is distinguished from an authentic pending registration. |
| StateOutput | reference : OutRef; identity : TokenId; quantity : Nat; configuration : Config. A state observation is not authenticated merely by decoding these fields; its origin and correspondence to the actual economic unspent output are explicit premises. |
| ObservationBundle | assets : unchanged NoPin.TxView; references : List OutRef; requests : List RequestOutput; states : List StateOutput; world : Singular.World; unspent : Singular.EconomicUtxo; transaction : Singular.EconomicTransaction. This records observations only, with no new ledger step, validity or policy evaluator. References supplement rather than change the minimal TxView. |
| Exit | fold; rejection; reclaim; untaggedSweep. Rejection carries the existing Singular.Rejection observation. Fold and rejection may be batches. Reclaim is the existing single-registration economic exit. Sweep has a distinct untagged, world-preserving prerequisite and does not remove a pending request. |
| Action | create; register; terminate; fold; reject; reclaim. Derived identity needs are exhaustive over these constructors. Terminate uses application-held custody; only registrations use the shared request address. |
| Derivation | published constant; public chain value; hash of a structured role preimage; publisher state application. Client recipes contain only the first three. A ranked dependency observation records each derivation's actual arguments, including seed and complete registry. |
| Query and Scenario | One named public case and explicit release, public identity/payload, observation bundle, booking/rejection data, finite hash interpretation and mutation selector. No theorem name, expected acceptance bit or private booking file. Mutation.none is the candidate; flip selects one discovered atomic guard. |

ConfigurationCorrespondence binds the datum's snapshot to the authenticated booked registry's immutable parameters and the current root world's corresponding configuration fields. The current trie root may differ: equality of snapshot and current root is not required. CompleteRegistryCorrespondence binds the separately observed policy/name to the root's abstract registryId and stateToken interpretation; it does not compare policy alone. RequestObservationCorrespondence binds same-output datum, reference, credential, physical value and candidate assets to the actual root registration, exact accepted tags and booking. LedgerObservationCorrespondence binds complete spending/reference sets, state observations and mint to the same transaction and unspent view. Completeness and authentic origin are premises, never consequences of an empty list.

The canonical serialization premise and finite collision premise range over the preimages actually used, with an explicit nontrivial satisfying domain and violating twins. CDDL, exact CBOR/Plutus Data bytes, list forms, long byte strings and hash choices remain obligations in the impact inventory. Application-held observations, value partition and BurnCoupling keep their earlier explicit boundaries.

Termination shape is under revision in the following stage. No new termination record or termination-ready preimage is introduced here. The terminate client inventory lists the existing complete-identity application approval hash and the active witness hash, with any revised approval payload held for that stage.

## Application-owned request records

As an application author, I want the same-output identities, deposit and actual bid explicit before a guarantee is stated. This hypothetical NoPin.ApplicationRequests family follows parent NOTE-010's operator money rulings. Prior sections describe historical designs; their old declarations remain unchanged.

| Record | Current frozen fields and ownership |
|---|---|
| PublishedRelease | applicationPolicy, applicationCredential, stateProgram, statePolicy : Nat. Policy and spending credential are separate constants. The publisher applies the state program to the application policy once per release. There is no fixed termination tip. Actual publication, script/hash application and ledger correspondence remain explicit premises. |
| Preimage | state(seed : OutRef); active(registry : TokenId, key : Key); applicationConfiguration(registry : TokenId); registrationApproval(registry : TokenId, key : Key, holdingAddress : Nat, initialDatum : Nat, deposit : Nat); terminationApproval(registry : TokenId, key : Key). Distinct structured constructors separate roles and operations, and every registry contains policy and name. No request tip, bid or cost enters the approval preimage; the approved deposit does. |
| Codec, Hash, TrieCommit | Preimage → List Nat; List Nat → Nat; Singular.Trie → Nat. All are explicit pure parameters; no concrete CBOR constructor bytes, cryptographic implementation or accepted FNV identity function is selected. |
| FiniteEncoding, FiniteCollisionFree | Separate propositions over the finite occurring preimage domain. State/active/configuration/approval role separation and amount/address/datum binding use both premises, with actual domain membership. |
| ObservedOutput | reference : OutRef; credential, lovelace : Nat; datum : OutputDatum; assets : List (TokenId × Nat). OutputDatum is root(commitment : Nat), application(data : Nat), configuration(parameters : ApplicationParameters), or empty. Data, address, quantity and value are observations of this same output, with explicit decode/correspondence premises. |
| PublicRegistry | identity : TokenId; seed : OutRef; state : ObservedOutput; trie : Singular.Trie. Public genesis and proof data supply the seed and authenticated logical trie. Neither is inferred by hash inversion. This is a Singular/client input, not an application root/proof verifier input. |
| ProtectedControl | registry : TokenId; activeAsset : TokenId; key, controller, deposit : Nat. Live updates preserve full control/assets and at least this deposit. The deposit remains protected throughout the live key and funds treasury when termination is booked. |
| ApplicationParameters | registrationCost, minimumTip, processTime, retractTime, bookingWidth : Nat. Values are fixed per seed. registrationCost and minimumTip are retained unused metadata; the new booking/spend law does not read them for admission or allocations. The other three still fix registration time/width. |
| ConfigurationRecord | registry : TokenId; parameters : ApplicationParameters; output : ObservedOutput; asset : TokenId. One configuration-role asset under the application policy and the inline five-field datum are created with genuine registry genesis in one application output, which has no spend/removal path. |
| ParametersForRegistry | Proposition binding the configuration record to complete identity, derived asset, actual quantity, inline parameters, application credential and same-transaction genuine genesis provenance. Old Config values map to this metadata record; only the three still-used clock fields preserve their earlier admission meaning. |
| RegistrationData | registry : TokenId; key, controller, refundAddress, holdingAddress, initialDatum, deposit, bookedAt, processDeadline, reclaimEnd : Nat. The application authenticates immutable booked data and a nonempty interval. No declared tip, charged registration cost or carrier allocation is stored in the new request. |
| RegistrationRequest | output : ObservedOutput; data : RegistrationData; approval : TokenId. The application output holds exactly one matching approval. Its actual ADA covers deposit and is the bid-bearing value. Its datum corresponds to the exact booked data. |
| TerminationRequest | output : ObservedOutput; registry : TokenId; key : Key; approval, activeAsset : TokenId. Registry/key are public asset preimages, not hidden fields in the empty datum. The output contains one approval, one genuine active token and its whole ADA bid; no tip or treasury split is inferred. |
| PendingRequest | registration RegistrationRequest or termination TerminationRequest. Pending and live categories are disjoint even at the same application address. There is no Singular pending pool or request tag. |
| Change | register(requestReference : OutRef, key : Key, holdingIndex : Nat, approvedDeposit : Nat); terminate(requestReference : OutRef, key : Key). Registration approval verification binds the actual holding address, committed datum hash and explicit approvedDeposit; Singular checks received lovelace at least that amount. Open datum separately checks its exact deposit and genuine token. Complete distinct inputs and one approval per action are required. |
| FoldObservation | before, after : PublicRegistry; assets : unchanged NoPin.TxView; spentOutputs, outputs : List ObservedOutput; changes : List Change; signers : List Nat; interval : Singular.Interval; fee, donation : Nat. This is a judgement input, not a ledger evaluator. Application branches inspect transaction assets/outputs/value/time only, never the registry roots/tries. |
| LedgerObservationCorrespondence | Proposition binding the complete indexed outputs, inputs, references, assets, mint and the unchanged TxView to one actual transaction, with conservation, uniqueness and authenticated history/state lineage. Neither typed record equality nor a list supplies those facts by itself. |
| ApplicationSpend | registrationFold; ownerReclaim; expiredCleanup; terminationFold. Processing ends by the booked deadline, owner reclaim is signed inside its booked window, and cleanup starts after it. No fourth path, early mismatch spend, cancellation or pending live update. Termination has no clock. |
| ApplicationPayments | Actual indexed output ADA/addresses, state ADA, ordinary input/output ADA, fee and treasury donation. Required deposits/refunds are summed per address, each actual output is counted once, and coincident addresses are explicit. There is no typed payment-purpose receipt. |
| CandidateReachable, ApplicationReachable | Separate actual-history correspondences for Singular genesis/folds and application configuration/booking/spends/live updates. A booking changes no Singular state. Actual unspent active-token count includes live holdings and pending terminations. |
| AcceptedProjection | Explicit mapping to the accepted logical trie/holding transition and its true Reachable witness, used to reuse Singular.Statements.termination and batch_burns_only_live_holdings by name. Accepted economic money rules are comparison baselines, not the new admission law. |
| ClientAction, Derivation | create, register, terminate, fold, ownerReclaim, expiredCleanup, update; published constants, chain data and hashes of structured preimages with their actual ranked dependencies. Only publisherState applies a blueprint. Clients derive the approval including its deposit and read the immutable clock parameters from chain. |

Current request money is computed from actual ADA. Registration fold leaves exactly deposit and exposes the remainder; termination fold exposes everything. Neither pays treasury. Termination booking pays the protected deposit to treasury. Registration owner reclaim returns everything; cleanup returns deposit only and exposes the rest. The previous fixed-tip, controller-deposit-return and fold-treasury candidates are superseded by the operator, not silently treated as equivalent.
