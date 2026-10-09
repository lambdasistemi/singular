# Contracts between writer tools

The contracts below describe the already commissioned product requirements. NONE means no enforcing check has yet been verified for the new cross-tool behavior. These are addressed by the existing ticket acceptance checks, not a new assurance gate.

## Mirror file format and follower output

Parties: persistent deployment PR #106 produces the initial file and attachment consumer; #107 produces a replayed and incrementally resumable mirror; #104 consumes the trie for fresh batch proofs.
Invariant: replay uses the deployed registry's key/value/operation semantics; the written mirror root equals the confirmed state root. The last replayed chain point belongs to that same mirror. Attach refuses an incompatible root or invokes the requested rebuild.
Enforced: NONE verified for the future follower-to-attachment seam. PR #106 remains unmerged. The #107 devnet deletion/rebuild/subsequent-fold test and named root-mismatch refusal are the commissioned enforcing route.
Owner: ticket #107 for follower extension; milestone desk arbitrates any incompatible format change with #104 and the merged #106 contract.
https://github.com/lambdasistemi/singular/issues/107
https://github.com/lambdasistemi/singular/pull/106

## Request datum and adaptive folder

Parties: request construction and datum codec produce requests; #104 reads and batches them; validators and the existing mirror replay determine confirmed root effects.
Invariant: preserve the Lean-bound key/value/operation, refund and witness semantics. On size or execution-unit refusal halve; on confirmation read back the current root and recompute proofs; report and skip a request failing alone. Never reuse proofs across batches.
Enforced: NONE verified for adaptive multi-batch execution. The #104 CI devnet test already requires varied-size requests that cannot fit one transaction, more than one successful batch, final mirror/chain root equality and one reported/skipped poisoned request. Its node-bound failure control is the enforcing route.
Owner: ticket #104. Existing lower-level codec or single-fold checks do not establish this new loop.
https://github.com/lambdasistemi/singular/issues/104

## Deployment manifest consumed by both tools

Parties: #106 deployment author; #107 chain follower; #104 folder/runner.
Invariant: both tools use the actual merged manifest's network, bootstrap transaction and registry identity. The follower starts at that bootstrap and follows the same registry whose request address the folder drains.
Enforced: NONE verified across both new tools. The existing ticket devnet/preprod requirements and the milestone's fresh-checkout integrated outcome cover this seam. No extra assurance campaign is commissioned.
Owner: milestone desk sequences #106 then #107 and coordinates preprod use; each ticket owns its consumer adaptation.
https://github.com/lambdasistemi/singular/milestone/4

## Naming deployment deposit, model and command

Parties: first deposit-model ticket defines the ruled semantics; later protocol implementation enforces them; singular-naming exposes the actual deployment amount and registration refund address. Invariant: amount is a deployment parameter, deposit is refundable on Over to the address committed at registration. Enforced: NONE yet. The first ticket supplies executable MODEL evidence only; real transaction enforcement belongs to the later implementation ticket. Existing deployed identities and older frozen ticket acceptance are preserved. No adjustable administrator or new existing-deployment authority is inferred.

## Connected pending cancellation to management command

Separate repair owner %1194 restores the production builder/claim/refund connection consumed by #114. Existing compiled-context probe: two passing controls, two failures, final three hashes verified. Enforcement of real connected cancellation: NONE until the commissioned devnet route passes. M1 #110 owns current representative changes; M1 acknowledged overlap notice at 15:24:45Z. Deposit economics remain a separate model decision.
