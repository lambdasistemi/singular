# NOTE-068 — the new retirement comparison uses mutable control as immutable identity

Read and acknowledge; route to990 before freezing the registry carrier. Root reviewed the actual Aiken diff together with the accepted lifecycle model. The raw byte encoding allowed under067 does NOT accept this new semantic dependency:

- Creation hashes `policy || cageToken || naming.control_hash(record)` into the representative name.
- `application.ak:recover` then requires successor.control_address == revealed_control and value_preserved(claim.output.value, continuation.value). Recovery changes the controller and keeps the same representative token.
- The new `retire` guard recomputes representative_name using **the recovered record's current control hash**. That is now a different preimage from the one that produced the unchanged token at creation.
- Accepted NamingLifecycle.replaceLifecycleOutput/recoverController preserves record.key and representative while changing the fixture. The explicit recovery_installs_controller_and_fresh_commitment statement preserves the representative; beginRetirement then uses that same record/key/representative with the current controller or fixed quorum.

The concrete risk is the ordinary required journey: **claim under A, recover to B, then retire through B or the fixed quorum**. The proposed fresh-record-only comparison will reject the unchanged token after a valid recovery. This is a source-level mismatch found before a new complete candidate; do not report it as an executed ledger result until the actual journey runs.

The immutable representative key/registry identity must survive control rotation. Return the faithful way the retirement path authenticates that existing immutable binding without substituting the mutable controller for it. The encoding itself can remain unambiguous raw fixed-endpoint bytes, but its semantic inputs must represent the model's immutable fields. Keep four naming datum fields; do not burn/remint/rekey the representative during recovery, weaken recovery, or drop registry association to make this guard pass. A caller value must be checked against an authentic commitment, never merely trusted because present. Exact representation and byte consequences go through root before consumer migration.

Add the actual sequential recovery-then-controller-retirement and recovery-then-quorum-retirement positives to the acceptance evidence, alongside fresh-claim retirement and copied-policy rival refusal. These are the already-required connected lifecycle, not a new feature or new stakeholder decision. Continue995's independent corrected-key Fork controls under067; this finding concerns990's carrier/retirement integration.
