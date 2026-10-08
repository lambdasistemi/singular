# Recover the broader registry

As a future registry maintainer, fetch the permanent refs to recover the seven-edge
model, validators and unfinished candidates before M1 is narrowed. This preservation
record addresses [#504](https://github.com/lambdasistemi/singular/issues/504), under
[#507](https://github.com/lambdasistemi/singular/issues/507). It changes documentation
only. It neither delivers M2 nor accepts an implementation, model candidate or release.

## Exact source and lineages

[manifest.json](manifest.json) is the machine-readable inventory. Integrated source
is `23964e667fa278b2027d0c05169c0f5e0e9233cb`, tree
`4afbdd69413bc5c8152fa2a3bc42fb6fcac71b7c`. The permanent
`preserve/m2-registry-extensions` branch adds this record to that source. Its
creation commit is recorded by the separate fresh-fetch receipt, avoiding a
self-referential commit identity inside its own manifest.

Lean authority at that revision is `lean/Singular/Model.lean` and
`lean/Singular/Statements.lean`, with driver/corpora/debt manifests and the formal
simulator mirror retained. `step`, `admitsFor`, `admittedExitStep`,
`admittedTxOfExit` and `buildFold` retain their original definitions. On-chain,
naming, off-chain consumers/builders, open-datum model, conformance, workflows,
Nix expressions and complete dependency lock blobs are inventoried. Integration
is a source fact; it does not certify the connected behavior of every edge.

Each candidate has its original full SHA/tree, source ref, owner route and a
separate permanent `preserve/m2-candidates/` ref in the manifest. They are fetched
as separate histories, never combined. This includes #158 salvage, the current
unmerged #498/PR508 head, #396, local and remote #437, #381 replay, #310 and paused
E209 local/remote #233, plus broader #157 and retained #177 histories. Squash or
historical ancestry alone does not mean undelivered behavior.

## The five deferred edges

| What a maintainer resumes | Integrated source at the bound baseline | Candidate/history | Unmet outcome and accountable route |
|---|---|---|---|
| Read a terminal key (`witnessTerminal`) | Lean `step`, `witness_terminal_inversion`; cage read and keyed terminal mint; registry update builder | #158 salvage `062783a2`, closed unmerged PR165; #381 public replay | Salvage/re-cut #158's released command, two reads and attributed refusals; #154 via M1. A replay component pass is not archive or hosted acceptance. |
| Book an absent key (`insertAbsent`) | Lean `insert_absent_inversion`; cage absent custody and refund-only wire; registry types and update builder | #178 PR212 head and integrated merge preserved | #178's historical S1 merge does not close its open obligations; #211's extracted command/archive/refusal remains unmet; #154 / original ticket-178 owner. |
| Activate an absent key (`updateActive`) | Lean `update_active_inversion`; cage custody consumption/refund; registry update builder | Shared #157 substrate and integrated broader source; no dedicated frozen #179 candidate identified in reused census | #179 command, custody/refund refusals and connected absent-to-active journey remain unmet; #154 via M1. |
| Delete an absent key (`deleteAbsent`) | Lean `step`/statements; cage deletion/refund; naming custody consumer and registry update builder | Broader #157 histories, integrated source | Named #154 non-goal; no accepted end-to-end delivery or dedicated candidate established. Consumer wire/coverage obligations need owner assignment through M1. |
| Delete an active key (`deleteActive`) | Lean `step`/statements; cage deletion/token delta and registry update builder | Broader #157 histories, integrated source | Named #154 non-goal; no accepted end-to-end delivery or dedicated candidate established. M1 routes later ownership. |

The 2026-10-08 scope ruling keeps M1 at registration and permanent termination.
KERI close/reopen is application behavior; the reported consumer premise is not
independent KERI verification. Here all seven model edges remain unchanged.
In particular `admitsFor` admits `witnessTerminal` without application approval:
source preservation supplies no compiled exclusion claim. Existing deployments
cannot be relabeled as restricted M1. Request exits/refunds, public folding,
token/datum identities and uncovered conformance obligations remain retained.

## Evidence and open ownership

Safe original records retained under [the evidence provenance record](evidence/provenance.json): #396's owner handoff
(source/lint extent, hosted failures and live gaps), #437's original source-only
BLOCKED verdict at its remote candidate (four findings; zero auditor executions),
and the fresh PR508 disposition/check snapshot. PR508 is open, unmerged at
`a7224021`; its candidate includes `specs/494-protected-rejection/verification.md`,
`compatibility.md`, decisions and review follow-up. Model-only review/local
compatibility checks do not clear its barred ledger repair or merge hold.
Copied handoffs retain their original stop rules and limits; they are records,
not instructions to wake their owners. Evidence provenance/hashes are in
[evidence/provenance.json](evidence/provenance.json).

Original raw reviews, frozen instruments, CI logs and release artifacts remain
with their owners. They are not all portable here. #498 owns raw model-review/CI
publication disposition; E301/to-396 owns raw campaign/hosted receipts;
E371/to-437 and to-381r own current dirty work, replay/consumer receipts and
historical reviews; E209 owns its paused campaign. #154/M1 routes unresolved
#157/#177 and absent-path evidence. No owner was contacted or redirected.

[evidence/census.tsv](evidence/census.tsv) reuses the intake inventory with refreshed
branch/worktree tips. Every row is classified as reachable integrated source,
retained candidate, or unclassified and excluded from cleanup. Unclassified
historical/rebased/detached snapshots are not declared expendable. This bounded
selection is not a repository-wide semantic history audit. No live dirty/index/
untracked payload is included. The newly reachable candidate history was scanned
for high-confidence private-key/token markers; its scope and result are retained.

## Recovery and verification

Requires Git, Bash, jq and sha256sum; Nix is required only for the optional model
check. Start outside any existing repository, with no local object alternates:

```sh
mkdir singular-m2-recovery
cd singular-m2-recovery
git init
git remote add origin https://github.com/lambdasistemi/singular.git
git fetch --no-tags origin '+refs/heads/preserve/*:refs/remotes/origin/preserve/*'
git checkout --detach origin/preserve/m2-registry-extensions
bash specs/504-m2-preservation/verify.sh HEAD
```

The leading `+` updates only this fresh repository's local remote-tracking refs;
it grants no remote overwrite. The verifier compares every named candidate's
exact SHA/tree, proves ancestry, and checks baseline/inventoried Git blob hashes.
To inspect one candidate, use its manifest `permanentRef`, replacing `refs/heads/`
with `refs/remotes/origin/`, and checkout detached. Never reset a permanent remote
ref to resume development; create a new issue branch from the chosen candidate.

The recovery model command is `nix run --quiet .#model-check` from the repository
root, capped at 15 minutes. This runs the executable model/corpora/axiom/debt
checker, not validators, a ledger journey, KERI integration or all implementation
layers. Its one fresh result is retained separately with exact source revision,
stdout/stderr and exit; timeout is UNKNOWN and setup failure is not behavioral RED.
Historical root `nix develop --quiet -c just ci` and on-chain `nix develop --command
aiken build` / `aiken check` references are retained as commands, not rerun results.
Use each on-chain project's own directory. #381 replay requires the `offchain`
working directory; its historical receipts do not transfer to this snapshot.
Recorded script identities/parameter counts in `onchain/script-identity.json` and
`naming-onchain/script-identity.json` are preserved blobs, not freshly compiled,
applied identity checks or deployment recognition. Dependency pins come from the
exact lock files and `cabal.project`, never floating replacements.

## Retention ledger and limits

M1/project owner via epic #507 owns retention and propagates these exact refs to
the project ledger before authorizing narrowing. No reset, force push, deletion,
reuse or cleanup of permanent refs without an explicit later operator ruling.
Read-only hosting inspection listed only an active `main` ruleset; preservation
protection has not been established. The retention guarantee is procedural.

Exclude all existing branches/tags, worktrees (including detached candidates),
raw receipts, journals, reviews, original release artifacts and dirty/untracked
work from cleanup pending owner disposition. Specifically retain root
`/code/singular/notes/`, over-witness and ticket-178 records, E18/E209/E301/E371
runtime trees and `.lanes-tmp`. #437's local commit differs from remote and its
active dirty work is not frozen. #509 is an independent lane and excluded from
this delivery. Old E209 pauses, original budgets, release tags and artifacts are
unchanged. No source, dependency, fixture, conformance state, generated product
output, runtime behavior, release or live transaction changes are authorized here.

Harness preservation checks and original limited receipts above are an appendix
to recovery evidence. They do not change the product's public conformance rows.
Epic acceptance, project-ledger disposition and narrowing remain parent decisions.
