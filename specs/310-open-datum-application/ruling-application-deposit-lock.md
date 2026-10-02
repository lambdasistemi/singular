# Demo 1 application: open datum, locked token and deposit

## Alice's story in the operator's words

Authority: direct operator clarification in the first milestone's coordination conversation, 2026-09-28. Alice uses an open policy meaning the datum is open; the token does not go into Alice's wallet. Alice interacts with a smart contract, can change the datum, cannot consume the deposit, and the deposit stays until she terminates the token.

## What it supersedes and keeps

This supersedes the holder-wallet destination and ordinary unrestricted holder-spend assumption in 2026-09-28-demo1-token-data-findability.md. Its public findability, same-registry/key duplicate refusal, confirmed termination and same-identity no-resurrection requirements remain required. This is required behavior, not a claim the current parameterless minting policy already enforces it.

## Required application behavior

- Initial insertion delivers the token, caller-selected valid Plutus datum and request deposit to an application spending-contract output.
- Alice can authorize datum changes. A continuing transition preserves the same token identity at the governing contract and the protected deposit amount. Alice cannot extract the protected deposit through an update, transfer, alternate output or ordinary spend.
- Successful token termination burns the active token and commits Terminal in the same registry/key; only this authorized termination permits release of the protected application deposit to Alice. A termination request's own deposit and processing tip remain distinct from the original locked application deposit; transaction fees/minimum-output funding must be accounted for separately.
- Demonstrate one successful datum change and one intended refused early-deposit-withdrawal attempt with positive/negative controls and fresh ledger observations. Setup/client failure is not validator refusal.
- Preserve arbitrary payload freedom without allowing the payload to rewrite authority, token identity, protected amount or release conditions. Owner must propose a concrete encoding separating protected control data from arbitrary user data, or an equivalent binding, rather than silently imposing a business schema on the payload.

## Minting policy and spending validator

The minting policy and application spending validator have different duties. The existing open minting policy's approval-bound destination does not itself enforce continued deposit custody. Determine reusable existing application primitives versus the precise new validator/model/spec work needed. Do not claim this is achieved solely by placing the token at any script address.

## Reconciliation and limits

Epic owner must reconcile the changed acceptance and implementation scope before affected implementation/audit acceptance: frozen gate/mandate revisions, model-to-implementation correspondence, custody/update/termination controls, #299/#300 allocation and bounded schedule. Preserve old evidence and spent budget. #304 remains owned by Epic #209; do not waive or silently resolve its termination correspondence hold. Existing roster retained; no additional seats, automatic budget replenishment, live writes, publication or merge authorization. Return concrete design/scope questions if necessary; unaffected work may continue.
