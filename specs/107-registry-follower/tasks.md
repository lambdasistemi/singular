# Tasks

One slice: `S-follower` — rebuild the registry mirror from the chain.

Checked means demonstrated by an executable check on the candidate, not
written. Unchecked items are open work, not pending paperwork.

## Landed in the audited candidate

- [x] T-checkpoint: compatible optional mirror checkpoint plus bounded request/state replay data; legacy `saveMirror` invalidates the checkpoint rather than silently advancing it.
- [x] T-follower: `Singular.Registry.Follower` over the pinned chain-follower and node chain-sync adapter — bootstrap identity, request outputs, state spends, `Modify` actions, per-fold root.
- [x] T-root-equality: replay is self-checking per fold and at the tip; the mirror is written only on root equality, and refuses by name otherwise. Failure control executed (`root-mismatch`, live node).
- [x] T-atomic-save: mirror written via temp file plus rename under `bracketOnError`; the gate asserts the previous mirror survives an interrupted write byte-identically.
- [x] T-resume: resume from a valid checkpoint, and invalidation, both exercised.
- [x] T-surfaces: `deployment follow` exposed without wallet requirements; `attach --rebuild` wired through the existing runner/library seam.
- [x] T-devnet-e2e: `nix develop --quiet -c just follower-e2e` — real deploy, folds, mirror deletion, replay, root equality, subsequent fold — wired into `registry.yml`.
- [x] T-onboarding: onboarding page's "second machine" paragraph replaced by the `follow` command, speech restamped.
- [x] T-speckit-restore: `spec.md` authored and `plan.md` reconciled with a per-requirement verification-state table. Ticket-owner-owned; not an implementation claim and not retroactive validation of earlier work.

## Open repair batch

Adjudicated repair batch, submission 2. Batch: `ticket-107/team-owner/handoffs/REPAIR-BATCH.md` sha256
`02d2aac4a739995b0eea8a5fd472e5d4c68b7ca47c74ef90001030a28ba023fe`.
Each carries its failing and passing criterion there.

- [ ] T-RB-01: bind every replay arm — the gate produces at least one confirmed fold per `RequestAction`/`OnChainOperation` constructor, extent read from the type. Must turn the retained surviving mutant RED.
- [ ] T-RB-02: make the offchain failure classes reachable by CI — `fourmolu`, `hlint` and the offchain unit suite must actually execute; falsified once per class. Scoped to #107's CI paths.
- [ ] T-RB-03: seeded controls for the refusal classes row B03 names — checkpoint decode, chain-moved / node-disconnected-before-root-verification, socket/query exposure — each producing its named refusal and preserving the existing mirror. Remaining refusals recorded as a named residual.
- [ ] T-RB-04: execute the earlier-rollback / intersect-not-found reset arm, and load a mirror fixture in the genuine pre-#107 format with the checkpoint key absent.
- [ ] T-RB-05: one executable invocation each of `deployment follow` and a journey `--rebuild`.
- [ ] T-RB-06: decide the mirror file mode (0644 restored, or 0600 kept deliberately) and assert it in the gate.
- [ ] T-RB-07: leave the manifest schema untouched. F-02 is recorded, not implemented, and remains open — see the acceptance dependencies below.

## Open acceptance dependencies

These are not closed by this ticket and are not waived. Desk A-001: recording a deviation closes the documentation task only. It
does not close the requirement or its blocking finding. Both items below
stay OPEN in the final disposition even if every in-scope repair passes.

- [ ] T-preprod: the frozen "Done when" preprod observation — a fresh checkout rebuilding the mirror from a **preprod** node. BLOCKED by A-002: needs the complete verified M1 manifest/mirror/chainpoint/state handoff, explicit writer release and desk sequencing. No preprod node, socket, credential or configuration has been touched. This is unobserved, not satisfied.
- [ ] T-bootstrap-chainpoint (F-107-OPUS-02 / R-01, BLOCKING, OPEN): a cold rebuild issues `FindIntersect` at genesis because the manifest records bootstrap transaction ids with no slot or block hash. Implementing the fix needs an additive manifest chain point, which is #106's shared contract with #104/#114 and outside this ticket's authority — scoped separately at `handoffs/indexer-bootstrap-chainpoint-followup.md` (local scope draft; no issue filed, no worker launched, no contract changed). Genesis replay does NOT satisfy the frozen starting-point requirement and must not be described as doing so. The cost remains unmeasured and no wrong-root claim is justified. Documented in `plan.md`; the requirement stays open.

## Slice

`S-follower` — OWNER. Implementation owner: separate accountable seat.
Independent audit of the candidate **and** the changed gates is required before
trunk; the implementer does not self-accept. Gate: untracked `./gate.sh`.
Final subject: `feat: rebuild the registry mirror from the chain`.
