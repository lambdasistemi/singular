# Handback — A-001 day-zero release: merge EXECUTED, tag HELD

From: epic-15 owner (claude/claude-opus-5, pane %848) · To: milestone owner (%844) · 2026-09-09

**Outcome in one line:** the release merge landed exactly as authorized; the tag was **not**
created, because NOTE-002's sequencing amendment arrived after the merge and holds any
not-yet-executed merge or tag. Nothing was undone and nothing was retagged.

## A-001 step by step

| Step | Result |
|---|---|
| 1. Re-read PR #2 immediately before merging | **PASS — identity unchanged.** head `b84643ac5a6e887459708fab4c13e14ceb0243f7` = reviewed head. base `main` at `58eaabad9d15d4ac223aca912bc5966b16b534c7` = observed base. `draft: false`, `mergeable_state: clean`, `merged: false`, 0 reviews required. Diff independently re-verified by me at the fetched head: **3 files, release-only** — `.release-please-manifest.json` `{}`→`{".":"0.1.0"}`, `version.txt` `0.0.0`→`0.1.0`, `CHANGELOG.md` added (+58). `git diff --name-only` confirms **no other path touched**. No validator/model/simulator change. |
| 2. Merge through the guard, never an unguarded path | **DONE.** `mcp__merge-guard__check-merge-ready(requireUpToDate=true)` at `16:43:56.916Z` — 4/4 guards, 10/10 checks. Then `mcp__merge-guard__guard-merge(mergeMethod:"squash", requireUpToDate:true)` at `16:44:00.443Z` — **6/6 guards**, including `merge-method-policy` ("squash collapses into a single web-flow-signed commit", `allowSignatureStripping:false`) and `merge-method` (allowed by repo settings). **`localRepoPath` omitted**, so `/code/singular` was never modified. No admin or protection bypass. The guard did not reject. |
| 3. Verify merged state and exact merge commit M | **PASS.** `merged: true`, `merged_at: 2026-09-09T16:44:02Z`, PR state `closed`. **M = `9e8d6b57a6e538719b8f782b521bd456301df71e`**, subject `chore(main): release 0.1.0 (#2)`, author `lambdasistemi-ci[bot]`. `git merge-base --is-ancestor` confirms M is on `main`, and M **is** the current `origin/main` tip. At M: `version.txt` = `0.1.0` **and** `.release-please-manifest.json` = `{".":"0.1.0"}` — both `0.1.0`. Verified in my isolated checkout `/tmp/projects/singular/milestone-1/epic-15/checkout`; the operator checkout was not touched. |
| 4. Create and push tag `v0.1.0` at M | **NOT EXECUTED — HELD.** See below. |
| 5. Observe the pipeline publication | **NOT REACHED**, because step 4 is held. |

## Why the tag is held, and what that costs

NOTE-002 (and NOTE-003, which restates it) is an explicit release-sequencing amendment to
A-001: *hold any NOT-YET-EXECUTED merge/tag pending the urgent docs-link fix; do not knowingly
cut a stale baseline while a user-visible fix is underway; if already executed, preserve exact
identities, no undo/retag, report.*

The merge had already executed when NOTE-002 landed (merge `16:44:02Z`). Its identity is
preserved above and was **not** undone or retagged. The tag had **not** executed, so it is held.

Verified current remote state — there is nothing to undo:

```
git ls-remote --tags origin   →  (no output: zero tags)
gh release list                →  (empty: zero releases)
```

**The honest cost.** Q-001's purpose was to prove the release path while it was cheap. Holding
the tag defers exactly that: `.#publish-docs` and the `refs/tags/v*` trigger in
`release.yml` remain **unexercised**, so the path is still **unproven**. It will now first
execute at the post-fix version instead.

**Consequence for the next release.** `main` now carries `version.txt` `0.1.0` and manifest
`{".":"0.1.0"}` with no `v0.1.0` tag. Once the documentation-links lane lands its fix,
release-please will open a **new** release PR at the next version. A-001 authorized only its
frozen candidate and explicitly not a moving future release PR, so **that PR needs fresh
authorization**. I will refresh the candidate identity and ask before touching it.

Two paths, and I do not need an answer to keep working:

- **preferred** — let the documentation-links fix land, then authorize the new release PR and
  its tag. The first published docs release then contains the corrected README link.
- alternative — authorize `v0.1.0` at M now, accepting that the published 0.1.0 docs carry the
  known-bad README link, in exchange for proving the publication path immediately.

## Scope, stated as A-001 requires

The artifact is **Singular documentation 0.1.0**, containing the current **generic** model and
simulator baseline. It is **not** the M1 naming simulator, **not** completed #15, **not**
milestone completion, **not** deployed ledger code, and **not** cardano-keri acceptance. #25
still owns the independently accepted naming/model/contract/scenario release; #19 stays in #16.

## NOTE-003's direct question

**NOTE-002 was never forwarded to ticket-20.** Nothing to withdraw, no preserved work, no
assignment identity. Evidence: `ticket-20/inbox`, `ticket-20/answers` and `ticket-20/questions`
are all empty, and ticket-20's journal contains only its own `START` (16:40:11Z) and `PLANNING`
(16:41:43Z). I had journaled NOTE-002 and verified the defect, but had not written its inbox
note or sent its pointer when NOTE-003 arrived. **Ticket-20 was never interrupted** and
continues on #20. No docs-links child of #15 was created and #20 was not expanded.

## Evidence the separate documentation-links lane may want

Established first-hand at M, offered as fact, not as a claim on that lane's scope:

- `README.md:5` is `<a href="simulator/">` — relative. On GitHub it resolves to
  `https://github.com/lambdasistemi/singular/tree/main/simulator/` (HTTP 200, but the **source
  directory**). In the built docs it happens to work, because `tools/prepare_docs.py:29` copies
  `README.md` → `docs/index.md` at the site root.
- `https://lambdasistemi.github.io/singular/simulator/` — **HTTP 200, 603 973 bytes**,
  `<title>Singular · A name and its custody</title>`, generic Delete present. Correct in both
  renderings.
- **`README.speech.json` is hash-bound** and is copied to `index.speech.json` by
  `prepare_docs.py:30`; `check_presentation_repo.py` gates `README.md`. A README edit therefore
  needs a `just stamp-speech README.md` re-stamp or `just check-presentation` fails.
- `README.md:5` also says "the admitted-model limits", which is **stale**: line 64 already
  states 41 **proved** statements from the standard axioms.
- **Ownership overlap to coordinate through parent before simultaneous edits:** #20 will touch
  `docs/` pages and the simulator entry point. `README.md`, `README.speech.json`,
  `docs/simulation.md` and `docs/simulation.speech.json` are the likely contested files.

## Reminder for terminal handback

When this epic terminally hands back, the parent must stop its `notifications`/`notify.pid`
process and close only its own topic.
