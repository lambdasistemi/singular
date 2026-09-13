# Epic 17 owner — resume record

Current as of 2026-09-12T07:20Z. Replaces the 05:50Z snapshot, which still named
#79 active at `7caabca` in pane `%968` and #77 parked on gate v2 — following it
after a crash would have restarted accepted, merged work.

## Seat

```
/run/current-system/sw/bin/claude --dangerously-skip-permissions --model 'claude-opus-5' --effort high
```

Pane `%913`, session `mpfs-onchain-ms2`, window
`singular-e17-t77-representative-fold`. Runtime root
`/tmp/projects/singular/milestone-1/epic-17`. Parent: root milestone owner, pane
`%844`. Epic checkout `/code/singular-e17`, `main` at `56e0fcd`.

## Children

| child | state |
|---|---|
| [#62](https://github.com/lambdasistemi/singular/issues/62) recovery `LR01..LR11` | merged `051d65e`; worker retired |
| [#66](https://github.com/lambdasistemi/singular/issues/66) retirement initiation | merged `ad071d5`; worker retired |
| [#79](https://github.com/lambdasistemi/singular/issues/79) imported-validator repair | **merged** — PR [#85](https://github.com/lambdasistemi/singular/pull/85), head `bf9f42d`, merge `56e0fcdbd09cb3326a63e490f6c7ed2511cdc9ef`, 40 checks green, issue closed. **Worker retired, pane `%968` killed, branch deleted.** Handoff for the consumer lane: `handoffs/79-to-epic18.md` |
| [#77](https://github.com/lambdasistemi/singular/issues/77) real representative + fold into `Active` | **ACTIVE** — worker `ticket-77/commit-owner`, muse, pane **`%979`**, worktree `/code/singular-e17-issue-77`, branch `feat/real-representative-fold`, rebased onto `56e0fcd`. Gate `gates/gate-77-v3.sh` sha256 `7fa81cb7f8ed2e71ba1233b13c5d724911cefd8df19d83133d96c6c8d5d5a501`, proven RED per class at that base |
| [#74](https://github.com/lambdasistemi/singular/issues/74) completion, `Over`, reuse | held. **Its dependency is the connected lifecycle, not an open ruling** — `Q-002` is answered and landed. Worktree `/code/singular-e17-issue-74` is retained provenance at `606a1ed`; **do not remove it** |

All carry milestone 1.

## What #77 owes beyond its gate

`gate-77-v3` is a **floor, not the acceptance**: five of its legs grep words in a
log or in source text, and `representative-minted-by-fold` greps the *unapplied*
manifest hash where the chain carries the *applied* policy ID. The gate stays
immutable; the binding is in `ticket-77/commit-owner/inbox/NOTE-001-assert-ledger-facts.md`:

- the runner **asserts** the connected fold, the absent registry-owner signer in
  the submitted transaction's own witness material, the applied representative
  identity against the mint and resulting UTxO, and `occupied-key` with its
  free-key control as executed outcomes;
- it emits a **machine-readable receipt** so acceptance asserts against data;
- fault controls must preserve the expected wording while making a real
  observation wrong, and fail naming it.

I add a separately recorded supplementary acceptance check (S2) against that
receipt, in the shape of #79's S1 — never by editing the frozen gate.

## Next action — actual handle and command

**Child**: `ticket-77/commit-owner`, muse, pane **%979**, worktree
`/code/singular-e17-issue-77`, branch `feat/real-representative-fold`.
Committed so far on it: `f3a68b1` ownerless antecedent, `55dea40` and
`d1fc24a` prose consistency. Register MainRun **GREEN exit 0 with evidence
retention** (raw bodies, outcomes, listings, meta) as of 10:07:41Z.

**Blocking deliverable**: `offchain#connected-verifier` does not exist yet — no
cabal stanza, no flake attribute. S3 correctly fails closed at
`verifier-available` until it does.

**Wait** (foreground/event, never a detached watcher):

```sh
R2=/tmp/projects/singular/milestone-1/epic-17/ticket-77/commit-owner/STATUS.md
cursor=$(wc -l < "$R2")
/code/llm-settings/shared/skills/worker-protocol/scripts/wait-status "$R2" "$cursor" \
  '  (PROOF-COMPLETE|BLOCKED  Q-|COMPLETE|CONTRACT-CHALLENGE)  '
```

**Then, once, against the frozen candidate**:

```sh
/tmp/projects/singular/milestone-1/epic-17/gates/supplement-77-S3.sh \
  <clean-worktree-at-candidate> <candidate-sha> <evidence-dir>
```

S3 sha256 `9e391fc3af2baa742a9085cd78d7a9d2e838ea1717fa9819fb239454855826bb`.
Then its controls: the fabricated-evidence control, the exit-17/stale control
**with the real verifier**, and faults at the state-input, root,
applied-parameter/asset and refusal-attribution boundaries — each reaching and
failing its intended assertion. Then `gate-77-v3` once on the same candidate.

**Then** the coherent consumer integration under `NOTE-038`: I own the final
serial integration branch (finalized #17 commit + epic 18's consumer-only
companion, imported mechanically, no parallel writers).

Settled, do not repeat unchanged: root's clean `f3a68b1` Aiken check
(1411 checks, 0 errors) and the S3 exit-17 adjudication fix.

## Binding rules

Constitution 1.0.0 and `code-the-design`: Lean is the behavioral authority
including for imported code; Lean owns the vocabulary; two distinct executable
implementation layers per invariant; a mutation census is a discrimination
control, not a layer; humans must match theorem and story clauses both ways.
Semantics, invariants, corpus and protocol requirements are fixed inputs —
ambiguity goes to the user as a concrete story before any semantic edit. The
parent tripwire `handoffs/check-repair-contract.sh` runs against every candidate.
Devnet: private shallow `TMPDIR`; never touch `/tmp/cardano-e2e`. Epic 18 owns
`conformance/`, the release-archive integration and the #80 coverage ratchet.
Release line: the complete epic-17 artifact first, then epic 18's integrated
conformance artifact; packaging never closes acceptance debt.

## Frozen gates (immutable, keep)

`gates/gate-62-v2.sh`, `gate-66-v2.sh`, `gate-74-v1.sh`, `gate-79-v2.sh`,
`gate-77-v3.sh`. Earlier versions retained as the record of each adjudicated
repair.
