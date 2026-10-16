# Cancelling a connected registration claim has no accepted refund path

As a naming user, I register a name, receive a pending Insert claim/request,
then cancel it before folding and recover the refund bound to that request.
The current InsertApproval cannot pass the application's cancellation path.

## Reproduction and evidence

Accepted source/model revision: `fc2ad9e5987b171ca33a430f5bbe170ab6423fd5`.
A runtime-only copy of its naming validators, fixtures and pinned Aiken flake
adds four tests. Command: `nix develop --quiet -c aiken check -m cli_cancel`
from `/tmp/projects/singular/milestone-4/naming-cli/evidence/cancel-probe`.
Exit 1; 4 tests executed, 2 pass and 2 fail:

- Existing WithdrawApproval cancellation positive control passes.
- InsertApproval mint validates the registration formula and controller signer.
- Cancel that InsertApproval with the real refund address fails at
  `expect presented_refund == stored_refund`.
- Present the approval hash instead; cancellation fails at
  `expect Some(shape) = decode_address(bytes)`.

The approval is `cf1157d163032238514cbdcfd0cb1c3562d4376e49f2ee27854b939cc25d34dc`.
Its preimage uses the existing register formula and fixture control
`610102030405060708090a0b0c0d0e0f101112131415161718191a1b1c` and commitment
`c2db4cf74eaf41d05ff3f0d2ba190c482dbd285e5615ab6885c05286c4c23cbe`.
The intended refund is
`61a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbc`.
Datum: `fixtures.source_record()`. Policy in this Aiken fixture is the literal
`application_policy`; it is not a deployed policy ID.

Full output: `evidence/cancel-probe-mint-control.log`; constructed identities:
`evidence/cancel-identities.json`; instrument:
`evidence/cancel-probe/validators/application.tests.ak`.

Evidence limit: these are compiled Aiken validator executions over constructed
transaction contexts, including a valid InsertApproval mint and the exact token
name formula the register builder uses. They do not execute the Haskell
`setupNamingClaim` builder, create a real UTxO or establish a node/ledger receipt.
A real register-then-cancel devnet sequence remains required for the repair.

## Cause and bounded repair

`setupNamingClaim` in `offchain/journey/register/Main.hs:987` puts a 32-byte
InsertApproval in the claim. `Naming.Register.insertApprovalName` commits only
control and next commitment; the four-field datum has no refund address.
`application.ak:328` instead treats the sole approval name as a refund address;
`naming.ak:60` accepts only 29-byte enterprise or 57-byte base addresses.
LC01 constructs a separate WithdrawApproval, so it does not prove this
connection. Generic request retraction alone does not cancel the naming claim.

A distinct repair owner must restore the connected pending-Insert withdrawal
promised by `NamingLifecycle.cancelNamingClaim`, preserve the request's committed
refund and real token burn, and expose a builder consumed by `singular-naming`.
The owner should first bind how the existing proposal's refund commitment reaches
the actual claim/token. If that requires choosing a new representation or changes
authorization semantics, obtain the exact operator/model ruling before coding.
This report chooses no token format, new refund path, economics or validator
parameter. Coordinate shared source with #110 and the later deposit implementation.

## Expected green observation

Create the real connected registration claim/request on an isolated devnet,
cancel through the production builder, observe consumed claim/approval, the
committed refund and appropriate generic request disposition, with no representative
mint or Active entry. Redirected refund, replay, already-folded claim and retirement
request cancellation must refuse at the corresponding boundary. Preserve the
existing WithdrawApproval positive control and successful connected fold.

This is a repair dependency of #114's existing connected cancellation story;
it does not expand #114, #104, #107 or the separate deposit model ticket. Filing
and commissioning are left to the milestone desk as instructed in A-002.
