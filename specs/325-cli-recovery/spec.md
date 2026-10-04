# #325 Recover CLI state after uncertain submission and rollback

Parent epic #322. Stacked on #323 at `7ca7fceb409c65c186713743889d29aa229b3aec` (branch `refactor/323-acquired-node-interface`). Application model pin `de34300540223ccedf1ca85216b131fd09a148b4`. The CLI's recovery behaviour is a client obligation of `specs/299-singular-cli/spec.md` (R299-05, INV299-PARTIAL); no Lean statement describes it, and this ticket adds none.

**Story.** As a CLI user, when a submission acknowledgement is lost, local persistence is interrupted, or an included transaction is rolled back, the ordinary `singular registry create`, `insert`, `update`, `terminate` and `inspect` stop or reconcile without resending, double-applying or inventing state, and their receipts tell me which case happened and what I do next.

**Starting point.** The #299 journal already appends `prepared` (signed body saved and synchronised before the send), `submitted`, `rejected`, `submit-unknown`, `confirmed`, `unconfirmed` and `observed`; every write refuses while a transaction is unresolved, and only `inspect` resolves one, from positive inclusion evidence, advancing the mirror only for the inspected registry and observing only the inspected key. Nothing journals a rollback or an exclusion; the mirror and `state.json` are rewritten in place.

**Requirements.**

- acknowledgement-unknown-outcome-inclusion-timeout-rollback-exclusion Acknowledgement, unknown outcome, inclusion, timeout, rollback and exclusion are distinct named outcomes in the journal and in the receipt of the command that meets them. No code path resends or rebuilds a journalled transaction.
- transaction-s-prepared-identity-signed-body-id A transaction's prepared identity (signed body, id, inputs, view chain point, expectation) is durable before it is sent. This holds today and stays held by a control.
- local-commit-after-inclusion-mirror-state-json The local commit after an inclusion (mirror, `state.json`, the `observed` line) survives interruption at any point: each file is replaced whole or not at all, never torn.
- next-ordinary-command-on-registry-any-write The next ordinary command on the registry — any write, or `inspect` — reconciles every interrupted local commit whose inclusion the chain shows: the journalled edge is applied to the mirror exactly once (only from its journalled root before, and only when the result is the ledger's root), `state.json` follows, and `observed` is journalled for the step's own after-state. Nothing is submitted. A write that reconciled proceeds; one that cannot stops, naming the case.
- transaction-whose-inclusion-was-journalled-but-whose A transaction whose inclusion was journalled but whose effect is no longer on the chain is journalled `rolled-back`. The mirror and `state.json` return to its journalled root before; the observation it supported is superseded by an appended line, never erased. It is unresolved again and never resubmitted.
- original-journal-lines-saved-bodies-printed-receipts Original journal lines, saved bodies and printed receipts are preserved: the journal is append-only and no recovery rewrites a prior line or body.
- lean-governed-behaviour-unchanged-authorizations-state-root Lean-governed behaviour is unchanged: authorizations, state/root effects, custody, refunds and refusals. Existing CLI, journey and conformance suites stay green.
- generated-devnet-controls-separate-singular-process-sequence Generated-DevNet controls, each a separate `singular` process sequence with verdicts computed from receipts and journals: lost acknowledgement, interrupted persistence, rolled-back inclusion, and an accepting control. Each refusal control shows no automatic resend, no premature committed local state and no double application.
- describes-outcome-what-user-does-next `docs/` describes each outcome and what the user does next.

**Rejection behaviour.** A write facing an unresolved transaction it cannot reconcile stops before any build or submission with the outcome naming that transaction's case (`unknown`, `timeout`, `rolled-back`) and its id. A journalled edge that does not take the mirror to the ledger's root is `stale-state`, never applied.

**Non-goals.** Chain finality claims; new wallet or signing services; indexer adapter work (#324); `Node/View.hs` semantics (#323); validator or Lean changes.

**Observable success.** Every CI job green on the PR head, including `nix develop --quiet -c just ci`, `nix run --quiet .#demo1-cli-check` and the recovery controls app named in the PR.
