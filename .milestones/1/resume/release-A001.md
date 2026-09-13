# A-001 — Authorize the prepared documentation baseline release

Decision: AUTHORIZED. This is the milestone owner's release decision within the operator's commission to start epic15 and give each epic a runnable release. No further operator confirmation is needed for the exact prepared action below. Q-001 remains non-blocking for20; keep its ticket owner supervised.

## Frozen candidate and observed readiness

- Repository lambdasistemi/singular, release PR2, base main.
- Reviewed head b84643ac5a6e887459708fab4c13e14ceb0243f7.
- Observed base/main 58eaabad9d15d4ac223aca912bc5966b16b534c7.
- Complete PR diff reviewed: .release-please-manifest.json sets root version0.1.0; version.txt sets0.1.0; CHANGELOG.md adds release notes. No validator/model/simulator implementation changes in this PR diff.
- Fresh check_merge_ready(requireUpToDate=true) at2026-09-09T16:42:02.754Z: all guards pass, up-to-date, clean, no required review; eight successful CI checks and two off-trigger skips. This authorizes the release metadata, not new proof/model acceptance.
- Current release workflow and tools/publish_docs.sh inspected: pushed v* tag triggers build gate then .#publish-docs; publisher verifies tag/version/manifest, exact merged release-PR commit on main, creates release and uploads archive+SHA256SUMS, downloads and verifies archive, updates release label.

## Authorized execution by your owning lane

1. Re-read PR2 immediately before merging. Require the same head, base main, current green guards and the reviewed three-file release-only diff. If head/base changes materially, stop only this release operation and return the changed identity; do not silently authorize new code. Continue20 independently.
2. Merge with the existing merge-guard MCP, not gh pr merge or an unguarded API call:
   mcp__merge_guard__guard_merge({owner:"lambdasistemi",repo:"singular",prNumber:2,mergeMethod:"squash",requireUpToDate:true})
   The Claude harness may display the name mcp__merge-guard__guard-merge; use the configured equivalent atomic guard. Omit localRepoPath to avoid modifying /code/singular. No admin/protection bypass. If the guard rejects, preserve its reason and report; do not switch to an unguarded merge.
3. Verify actual merged PR state and exact merge commit M. In your isolated operational checkout, fetch M and main; verify M belongs to main and version.txt plus root release manifest both equal0.1.0. No source changes in the operator checkout. This authorizes the merge even though your original execution brief reserved main merges to this answer.
4. Verify remote v0.1.0 is absent. Create/push v0.1.0 at M only, normal non-force tag push. Never overwrite an existing remote tag; if it already exists at M, observe the existing workflow instead of recreating it; if it points elsewhere, stop and report. This answer explicitly authorizes this tag and the existing pipeline's documentation release publication.
5. Let the repository pipeline build/publish its own archive. Do not hand-build/upload a replacement or bypass the build gate. Observe the tag workflow and record release URL, run URL, exact tag/merge commit, artifact filenames/digests and successful downloaded SHA256SUMS verification. If publication fails, record whether merge/tag already landed, preserve their identities and return the failure; no retagging or scope expansion.

## Scope and completion

The artifact is Singular documentation0.1.0 containing the current generic model/simulator baseline. Do not label it the new M1 naming simulator, completed15, completed milestone, deployed ledger code or cardano-keri acceptance. #25 still owns the independently accepted naming/model/contract/scenario release. #19 stays in16.

No extra standing team, extra audit family, issue comments, consumer contacts or unrelated release work is authorized. Your scoped release operation may be performed by the epic owner using the guarded mechanism above while Grok supervises20; do not hand control of20's GLM/Sol workers upward.

Acknowledge RESUMED Q-001 through your STATUS after reading this answer in full. Execute through the publication receipt without repeated continue prompts, and return handoffs/day-zero-release.md with actual remote evidence or the exact non-blocking failure. Notify parent by its durable pointer protocol on terminal publication result; parent relays Telegram. Parent acknowledgement is not itself proof the release shipped.
