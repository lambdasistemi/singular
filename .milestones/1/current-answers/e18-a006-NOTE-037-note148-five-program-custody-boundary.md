# NOTE-037 — NOTE-148 five-program rejection/custody acceptance boundary

Read at the next natural boundary and ACK in `STATUS.md`; do not interrupt,
restart or rerun the current A006 proof for this report. Finish the already
commissioned NOTE-035/036 general work first.

Root's sibling ruling
`/tmp/projects/singular/milestone-1/epic-17/inbox/NOTE-092-five-program-rejected-retirement-burn-gap.md`
(SHA256
`6138cda4739dad6605bb1f6c3ceff2c9be30f0a45c31b226da6d452e97a577e3`)
and executed receipt
`/tmp/projects/singular/milestone-1/handoffs/completion-rejected-root-control.json`
(SHA256
`66b9601ba59482f438d85cce8d38a120ea5917ec7f7bbec5b5b76e2fbc02bccf`)
add a bounded cross-epic finding to the A006 acceptance boundary.

Aiken 1.1.21 `aiken check -m rootfive_` executed exactly 5/5 passing
controls over one shared value-balanced synthetic context using the current
actual state, request, pinned consumer, representative and retirement-custody
handlers. The main witness processes an expired retirement `Update` as
`Rejected`, refunds it and keeps the registry root `Active`, while the same
transaction spends custody and burns that representative. All five handlers
return true. Controls show:

- the same rejection without a custody spend is legitimate and passes;
- removing the burn is refused by custody after the earlier handlers pass;
- removing the registry state is refused by custody; and
- removing the pinned consumer withdrawal is refused by state.

This is an executed synthetic source-level composition control only. It is not
a ledger run, authentic admitted history, compiled-hash rebind, universal
correspondence proof, product adoption or accepted model evidence.

## A006 disposition and handback requirement

Keep the current A006 runtime guard that requires unspent custody for its
candidate. Do not weaken it, but do not credit it as agreement with the five
current production handlers: those handlers presently admit the rejected-row
plus custody-burn combination above. Grok/E17 owns the concrete producer-side
repair under NOTE-092; this lane must not edit those programs.

At the actual A006/R2 acceptance boundary and in the final general-
correspondence handoff, keep the following explicitly open until the changed
producer is frozen and rebound:

1. the exact pending retirement request and burned representative are
   associated;
2. the genuine registry transition completes that representative to `Over`;
3. a `Rejected` action, unrelated request/state or mere spent-state presence
   cannot authorize the burn;
4. the corrected producer behavior is admitted by an authentic reachable
   history; and
5. both correspondence directions cover that exact producer/custody behavior,
   separately from retirement-completion accounting.

Preserve legitimate nonempty all-rejected, mixed and zero-net processing and
separate unspent retirement custody. Do not add a rule that every rejection
must complete retirement and do not infer generality from the five finite
tests. No unchanged A006 suite rerun is requested by this note. Record this
dependency and the exact receipt identities in the handoff before `COMPLETE`.

No new seat/reset, ledger work, accepted-model/schema adoption, migration,
commit, push, merge, release or epic acceptance. Rival NOTE-147 and E17
continue independently.
