# Bind cancellation to the registration's two co-created outputs

As a registrant, I want one registration transaction to create my pending claim
and Insert request with an immutable refund destination. During the existing
request-owner retraction window I can consume both together and receive the
refund; neither output remains available for later activation or replay.

## Recommendation and source facts

Recommend an atomic registration refinement: create the naming claim and its
native Insert request in the same transaction, and put their missing binding in
a new domain-separated Insert approval commitment. Keep the four-field naming
datum and the six-field generic request datum unchanged. Keep WithdrawApproval
as its existing compatibility route. This is a proposal, not an approved format.

Bound source/model is f558d0e8fc916eef494fffcef09cfe2ac5582b8e. The current
`setupNamingClaim` (journey/register/Main.hs:1167) and `submitRegistryRequest`
(:1045) create separate transactions. `Naming.Register.insertApprovalName`
commits only control and recovery commitment. `OnChainRequest` (Types.hs:110,
codec :403) contains token, owner, key, operation/value, fee and submittedAt;
it has **no refund-address field**. Thus even adding a native request input
cannot recover the Lean proposal's independent refund address from its current
wire datum. Lean `NamingLifecycle.cancelNamingClaim:223` and `Model.step:253`
require the exact request refund and removal of that request. The companion
approval must refine that missing abstract proposal field.

## Exact proposed authenticated content

The approval name is a 32-byte BLAKE2b-256 digest over a new versioned domain
and one canonical Plutus Data record. Proposed record fields, in order:

1. Domain bytes `singular/naming/connected-insert/v1`.
2. Registration seed input's transaction hash and output index, consumed in
   registration; this gives a unique approval without the new transaction ID.
3. Registry asset identity: state policy ID bytes and cage token-name bytes.
4. Native request output index in this same registration transaction.
5. Exact native request address bytes and exact six-field inline request datum.
6. Canonical full refund address bytes, including network and stake part.
7. Exact four-field naming datum.

Use the existing Plutus Data codec for framing rather than concatenate variable
fields. Constructor 0 containing these seven fields is the proposed commitment
preimage; the existing nested datum encodings remain unchanged. The new mint,
fold and cancel redeemers carry the preimage witness needed to recompute it.
The production registration receipt preserves that witness for future builders;
it is not a secret. A lost local receipt can be reconstructed from the
registration transaction's mint redeemer and outputs.

At spend time the exact request UTxO is
`(claim.output_reference.transaction_id, committed_request_output_index)`.
The request transaction ID is therefore never hashed into its own creating
transaction. The seed, output index and mint checks establish the association
at the same moment the claim and native request become live. No approval-convert
transaction, fifth naming field or later controller-selected refund is needed.

## Mint, fold and cancellation

Mint: consume the committed seed; authenticate the registry state reference by
its existing state NFT predicate; check the declared registry identity; require
exactly one new approval and one claim at this application script containing it
and the committed naming datum; check the indexed native request output's full
address/datum against the commitment. The native request must be Insert for the
same registry token/key and expected representative value. Require the existing
claim controller's signer and the request owner's signer; the combined builder
already needs those parties to create the two existing outputs. It derives the
native request address with the existing registry configuration. Whether the
application must independently prove that parameterized request address at mint,
beyond committing it and requiring native consumption at fold/cancel, is the one
implementation-bound authentication item to settle with the model authority:
the current naming application has a state hash but no dynamic native-request
script derivation. Do not silently accept an arbitrary credential as native.

Fold: keep the connected state Modify, native request Contribute and naming Fold
boundaries. Recompute the approval commitment, require the exact co-created
request input and matching address/datum, burn the approval, preserve the naming
datum/value, and retain the accepted representative checks (including #110's
spelling-derived identity once accepted). No new controller signer for fold.

Cancel: recompute the commitment; require the exact request input, address/datum,
Insert operation and the same registry state reference; require the native
request's actual Retract redeemer for that state reference. Burn the approval,
consume both claim and request with no continuation, no representative mint and
no state/root mutation. Pay to the full committed refund address; include the
claim and request value in the balanced refund while preserving existing fee and
min-UTxO behavior (no economic deposit rule is introduced). Preserve the existing
request-owner signer and phase-2 interval; the controller does not gain authority
to redirect funds. Request input absence, wrong operation, window violation and
wrong signer retain their corresponding existing boundaries.

This composes the existing request Retract spend with the naming cancellation
spend in one transaction. Generic retraction alone remains a generic action and
cannot be reported as completed naming cancellation.

## User-visible effect versus representation

User-visible: registration returns one transaction and a connected pending pair;
cancellation disposes of that pair only in the existing retraction window and
refunds the address fixed at registration. It does not imply all-times immediate
withdrawal. Generic request owners and naming controllers retain their separate
roles, with both signatures collected during atomic registration.

Representation: versioned approval hash, preimage witness, two outputs in one
transaction, request output-index binding. These are proposed refinements of
existing request identity/refund fields, not a new economic phase. Existing
v1 Insert claims lack the commitment and cannot be retroactively repaired by a
new builder; deployment compatibility/old pending claims must be stated explicitly
before release, with no migration or preprod write invented by this ticket.

## Smallest model obligation and overlap

Add a source-bound representation statement/example: decoding a validated
co-created pair yields one NamingState claim with the same requestId as the
registry request and proposal.refundAddress equal to the committed full refund;
a successful composed cancel removes both, preserves records/root and mints no
representative. Include a different request from the same registry and a changed
refund as refusal examples. If the current abstract model omits the native
request-owner/phase-2 precondition, record the existing-boundary refinement in
that statement rather than weakening generic timing or asserting immediate
withdrawal. The operator/model ruling must precede implementation.

Shared paths with #110/PR112: application.ak, its tests and script identity,
Naming/Register.hs/RegisterSpec.hs, and journey/register/Main.hs. #110 must be
accepted before final integration. #114 consumes the resulting production
builder and receipt; interface.md names that handoff without competing extraction.
No deposit-model decision, extra worker, audit campaign or deployment is proposed.
