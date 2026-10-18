# Cancellation binding: authentication, authorization and compatibility corrections

This refines, without overwriting, refund-binding-proposal.md, SHA256
c2e7df2e9375359eefd4b7c847b25c7209ddc789336cc2f66d1c74cf2fd7676d.
Source/model remains f558d0e8fc916eef494fffcef09cfe2ac5582b8e.
No production representation change has been made. Only the baseline devnet
instrument is being added locally to the register journey.

## Authenticate the genuine parameterized native request

Recommend one explicit new application parameter: the expected **applied native
request script hash** for this registry. At mint compare the committed request
output's payment credential with Script(expected_native_request_hash); at fold
and cancellation check the consumed request against the same parameter in
addition to the exact request ID, registry state NFT and committed datum.
The ledger then executes that exact validator when the request is consumed.
Checking a redeemer constructor alone is insufficient and is not proposed.

The hash is a script parameter fixed in the application bytes, never supplied by
an untrusted transaction redeemer or accepted from a manifest at spend time.
Its derivation is the existing `requestScriptBytesFromCfg` in
TxBuilder/Internal.hs:397: applyRequestParams(state policy bytes, cage token,
requestScriptBytes), followed by the existing hashScript. This must be a
build/bootstrap binding against the pinned request blueprint, verified by the
script artifact construction/identity checks. There is no on-chain authority
that can bless a different native script after deployment.

This **adds a deployment parameter and changes the application instantiation
interface**. The native request's parameters are only state policy and cage token
(request.ak:15); it does not depend on the naming application or representative
policy, so the dependency is request hash -> application -> representative, with
the boot seed/cage identity known before application instantiation. This is the
minimal explicit trust root I recommend instead of on-chain UPLC application or
trusting a caller credential. It is proposed, not authorized. Existing generic
request rules and bytes are unchanged. No deployment is executed by this repair.

## Correct the signer claim

The original proposal's suggestion that both are already semantic creation
signers was wrong. `TxBuilder/Request.hs:requestImpl` creates a plain output and
executes no script. Its payer signs funding inputs, but the named requestOwner
is not checked by request.ak at creation. `validateRetract` requires requestOwner
only at spend. `application.approval_roundtrip:617` requires the supplied
controller in extra_signatories for mint +1; it has no request-owner check.
`Model.step .createInsert:218`, `approved:173`, and `insertNative:161` also add no
request-owner signature predicate.

Executed check: `nix develop --quiet -c aiken check -m preservation` in the owned
runtime probe, exit 0, exactly 2 tests. `preservation_insert_mint_needs_no_request_owner`
accepts an Insert mint with only the controller and no request/output/input.
This is validator-context evidence, not a ledger creation claim.

Therefore requiring the request-owner signature on atomic naming registration
is a **new precondition**, not preservation of wallet funding. The operator must
rule on that choice; otherwise the recommendation must retain only the existing
controller mint requirement. No extra signer was added to production code.

## The claim can currently move; the txid shortcut needs a guard

The second executed context,
`preservation_pending_insert_can_move_via_maintain`, spends a genuine-form Insert
approval claim through Maintain and creates a continuation carrying the same
approval, with changed payment destination. It passes. A continuation gets a
new transaction ID, so deriving the original request from the **current** claim
output is invalid under current validator permissions.

Source branch inventory in application.ak:
- Maintain (:222) requires controller signer, field preservation and value
  continuation, but never proves the asset is an Active representative.
- Recover (:264 onward) also accepts the single-asset shape irrespective of its
  policy, requires the stored next-key reveal/signature and creates a continuation.
  Source analysis therefore exposes another pending-claim movement path; it was
  not executed in this bounded two-test check.
- Fold consumes/burns the approval; the Insert branch creates the representative.
- Cancel consumes/burns it without continuation (currently fails for Insert).
- Retire (:452) checks the name and expected representative policy, so a real
  Insert approval cannot take that branch as a representative.

To retain the proposed atomic/output-index binding, add a pending/Active custody
check to Maintain and Recover: they must spend the real representative under the
registry's expected representative policy, not an approval under this application
policy. Pending claims then only terminate through Fold or Cancel; they cannot
be relocated while retaining their approval. This is a necessary extra validator
restriction and must be explicit in the ruling, not hidden in the token format.

The accepted Lean `maintainDestination:129` and `recoverController:142` start with
`namingRecord` and `recordApplication`, then `validateLifecycleOutput`; pending
claims are in `state.claims`, not `state.records`/registry applications. Those
operations already refuse a pending claim as naming-record-unavailable. The
proposed guard aligns with that distinction. Generic `.moveAction` changes no
NamingState claim or request identity and is not a naming-claim relocation
operation; it remains available for its existing abstract token-movement scope.
The model/representation ruling should explicitly establish the stationary-pending
claim invariant before accepting the txid/output-index refinement. If the operator
intends pending claim relocation, abandon that refinement instead of banning it.

## Existing deployments cannot receive a validator repair in place

Changing application code already changes its spending address and approval
policy; adding a parameter also changes blueprint instantiation. Old pending
claims are locked at the old script. A new builder cannot replace the spending
rules governing those UTxOs, and an old v1 approval never committed the refund.
This PR can deliver corrected artifacts and an isolated-devnet demonstration;
it cannot make the existing deployed pending claims cancellable through new
rules. No migration, new preprod deployment or transaction is authorized here.

Consequently, if #114 acceptance requires this repaired route on the existing
M1 deployment, that acceptance remains blocked after code landing until the desk
obtains explicit compatible-deployment/migration scope. An interface handoff alone
does not close it. This conflicts with promising a repaired existing-deployment
route while this brief excludes a new deployment; please retain that denominator.

## Evidence and next action

Owned evidence: evidence/preservation-probe-v2.log (2/2 component contexts),
evidence/cancel-probe-reproduced.log (original 4 contexts, 2 pass/2 fail), and the
currently building real devnet instrument. An earlier preservation invocation
ran zero tests because the append command used the wrong relative path; its
preservation-probe.log is retained but excluded from the evidence claim.

The concrete approval request is now explicit: atomic pair creation and immutable
full refund; request-owner signer is a new precondition; expected native request
hash is a new application parameter; pending Maintain/Recover must reject approval
custody to preserve the proposed stable origin association; old deployments remain
unrepaired. Hold these production changes until the actual ruling. Continue the
already authorized baseline node reproduction and scoped intake maintenance.
