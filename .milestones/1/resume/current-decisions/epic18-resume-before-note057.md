# Epic-18 RESUME — consumer conformance and integrated release (rewritten 2026-09-12T07:1xZ)

## This seat

- Role: Opus EPIC OWNER, https://github.com/lambdasistemi/singular/issues/18
- Pane **%914**, window `mpfs-onchain-ms2:5`; runtime root `/tmp/projects/singular/milestone-1/epic-18`
- Parent: milestone owner pane %844
- Launch:
  ```sh
  /run/current-system/sw/bin/claude --dangerously-skip-permissions --model 'claude-opus-5' --effort high
  ```
  in the runtime root, then read `brief.md`, this file, `STATUS.md`, and `handoffs/`.

## Live children — exactly two

| worker | pane | worktree / branch | doing now |
|---|---|---|---|
| `t70-generic-rows` (glm) | **%938** | `/code/singular-e18-cg` / `t70-reintegrate` | consuming merged `56e0fcd` (#79); build blocked once on `unused-local-binds` at `Run.hs:3467`, failing log preserved as `/tmp/t70-full-FAILED-unused-cfg.log`, one rebuild instructed; then **execute CG20** and the CA/CG/CS families |
| `t80c-release-gate` (muse) | **%917** |  `/code/singular-e18-cov2` / `feat/coverage-release-gate` | strict-release gate under A-005: restoring `stash@{0}` (gate.py, ~101 insertions) onto the rebased branch; PR #84 **merged** as `5bd7c79` |

Retired, evidence preserved, **stay retired**: `t63`, `t68`, `t69`, `t80`, `t80b`, `t81`.

## Merged to `main`

`main` at `5bd7c79`. Ours: **#64** conformance harness + CG02–CG05 · **#72** CA01–CA05
· **#75** seven CS rows · **#82** Fork instruments (**merged**) · **#83** coverage gate.

Gate from `main`: `completion` **exit 1, INCOMPLETE**, mapping debt **192**, layer debt **192**,
83 unclassified.

## Open

- **#70** generic rows — in flight. CG14/CG15 `could-not-execute`; CG11/12/13/19 `held — Q-002`;
  CG20 expects **ACCEPT**, verdict moves only by execution.
- **#80** coverage ratchet — foundation merged; **cannot close on reporting-only enforcement**.
- **#68** serialization remainder · **#81** Fork coverage · **#71** resolution+limits (behind #70's
  `Run.hs`) · **#78** onboarding (deprioritized).
- **PR #84 merged** as `5bd7c79` — correspondence page, post-teardown finalizer assertion with two discriminating controls, digest-bound transcripts, RED provenance `3980e00` retained.

## Pending decisions — the user's

1. **Q-002 story 1** — canonical identity: must Singular's validator refuse a non-canonical registry?
2. **Q-002 story 2** — which Lean governs when Singular's and the consumer's models disagree
   (CG11/CG12/CG13 executed with txids and controls).
3. **Q-004** — is the `stake_script` hook meant to work? Registration is impossible as built.
4. **Representative-story review** — the `fold_iff` correspondence page awaits human review; no broad
   DSL rollout before it.

**Resolved, not pending:** Q-001 release line · Q-002 story 3 permissionless folder (implementation
defect, repaired by #79) · Q-003 Fork (refinement defect, epic 17 owns after #79) · Q-005 strict
completion at the integrated boundary.

## Release

Conformance ships **inside the existing `singular-onchain` archive** — no third archive. Epic 18 owns
`tools/assemble_onchain_release.py`, `onchain-release/README.md`, `RELEASE.md` and directly necessary
archive checks, scoped to conformance delivery. **Order: epic 17's bounded recovery/retirement release
first, then the integrated conformance artifact**, version from release-please at the integration
commit, no tag invented. Strict completion activates at that integration commit and must **block
publication**, not merely print `INCOMPLETE`. Verify from a **fresh extraction**.

## Standing rules this epic learned the hard way

1. `executed` is a **receipt**, never a typed field.
2. A refusal row must reach the **node**; receipts record `venue`.
3. Receipts bind the tree that ran; ship receipts come from a clean tip.
4. Wait patterns must admit tags a seat may invent.
5. The slice gate must include what CI checks.
6. Check the fence against the **merge base**, never `origin/main`.
7. After resolving someone else's dispatch, run **their** rows too.
8. Trim receipt volume, never the identities that attribute a refusal.
9. A lexical Lean scan fails **toward flattering the result**; fail closed on unknown grammar.
10. `gh pr ready` re-triggers checks; re-check before merging.
11. **A control must be able to fail for the right reason.** When the implementation changes, re-ask
    whether the control still discriminates — CG13's did not, post-#79.
12. **Verify a command before publishing it.** `coverage-strict` never existed; an absent Nix
    attribute fails as a missing attribute, not as a debt rejection.
13. **Two people agreeing about a misreading is not a finding.** Read the source at the exact commit.

## Standing constraint — #77 gives no credit (2026-09-12, NOTE-027)

The **#77 component devnet run is rejected as a connected registry journey** (root-17 NOTE-027,
acknowledged by owner 17). **No #80 implementation-coverage credit and no onboarding readiness may be
derived from it** until actual registry state/request/root-proof integration is accepted. #79's
accepted validator repair remains usable.

A component run that exercises pieces is not the connected journey, and the difference is exactly
what #80's two-layer rule exists to keep visible.
