# D-157-REQUEST-HOME — retirement uses the normal MPFS request validator

Status: operator decision recorded; model and implementation alignment pending.
Date: 2026-09-18.
Tracking: #157 / PR #164, N4 retirement and N8 completion; ticket-owner Q-006,
commit-owner Q-008.

## Authority and user story

The operator proposed parameterizing NYA with the request-validator script hash
and, after the concrete derivation and same-registry checks were explained,
instructed: "track the decision".

As Alice, after retirement is authorized by my committed recovery key or quorum,
I want the transaction spending my NYA record to create a request that any
folder can consume, so my name reaches terminal state and its active NFT is
burned.

## Decision

Retirement completion requests use the ordinary, parameterized MPFS request
validator. NYA's application validator takes that validator's applied script
hash as an immutable script parameter. The hash is derived from the compiled
request validator applied to the state policy ID and cage token name for the
same registry. It is not chosen in the retirement redeemer.

The authorized retirement transaction moves the active NFT into the existing
retirement custody and co-creates the completion request at this request script.
The request carries its bound updateTerminal approval, names the authenticated
registry's cage token, and requests Update(0x01,0x02) for the retiring key.

The later transaction consumes that actual request with Contribute, spends the
registry state with Modify and the retirement custody, burns the active NFT,
and sets the leaf to terminal. This decision introduces no RequestDatum spend
arm at the cage/state address.

Derivation order: state script hash and seed-derived cage token name determine
the applied request hash; that hash determines the applied NYA application
script and its policy ID; genesis pins the resulting application policy. The
deployment must derive and verify these identities together. A script-hash
parameter alone does not prove its supplied value was derived correctly.

The operator explicitly raised the possible cycle through the cage's application
policy. Checked against the current code: `state()` has no script parameters
(`onchain/validators/state.ak:75`); `application_policy` is a field in the state
datum (`onchain/validators/types.ak:229`). Its value is fixed at genesis and
preserved by folds, but does not enter the cage script hash. The cage token name
comes from an already-existing seed input's output reference
(`onchain/validators/lib.ak:145`), not the boot transaction's own hash. Thus this
derivation has no script-hash cycle. This conclusion depends on preserving those
two facts; moving the application policy into a cage script parameter would
introduce the cycle the operator identified.

## Reason and correspondence work

Repair commit 652bce5 required the co-created completion output to be at the
cage/state script, which cannot spend RequestDatum. The regular request script
already supplies the intended Contribute path. The address exception has no
support in the accepted user story.

Lean currently constructs a Request and passes it directly into the semantic
step. Its retirement abstraction does not represent the intermediate request's
locking validator or prove that the output produced by retirement can be
consumed by completion. Record the chosen pending-request and same-registry
relationship in Lean, with corresponding statements and corpus as applicable.
The exact accepted model revision is still pending.

The required connected evidence is a retirement followed by a fold consuming
the request and custody outputs that retirement actually produced. Preserve
refusal coverage for a wrong request address, wrong registry token, and missing
or mismatched approval; do not substitute a manually created completion input
for this lifecycle check.

Parameterizing NYA changes its script address and application policy identity.
Deployment derivation, consumers and identity artifacts must follow that change;
this record claims no compatibility or migration for existing deployments.

## Disposition

The choice of request home is resolved. The epic owner owns routing the Lean
and frozen-mandate amendment; the ticket owner owns the later gate binding and
commit-owner instruction. Gate S v10 remains unchanged and the commit owner
remains parked until the new bindings are ready. This recording task does not
release implementation, an audit, auditor contact, push or merge.

Evidence: ticket runtime
`/tmp/projects/singular/over-witness/epic-154-r2/ticket-157/questions/Q-006-retirement-completion-placement-lean-ambiguity.md`,
SHA-256 `8dcb45d1d49b955e3300928dc35607423c92b245f972a6d50c60101f984d2e05`;
implementation inspected at `f6b2eed8034341962292b54a3ec5e9f22eddc362`.
