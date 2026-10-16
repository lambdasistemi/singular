# Plan for the ledger boundary

As the ticket owner, I hand one writer the whole model task with a terminal condition, and one auditor the checkpoints, and I accept on hosted jobs at the head.

## Binding

- Repository lambdasistemi/singular, worktree `/code/singular-issue-679`, branch `feat/679-ledger-boundary`, base origin/main `45cd8a75`.
- Runtime root `/home/paolino/.orch-runtime/singular/m1/epic-676/ticket-679`; temporary files under `/code/.lanes-tmp/epic-676/ticket-679`.
- Lean 4.27.0 as `lean-toolchain` names; model revision is the base, constitution 1.18.0. No constitution amendment: the driver translation, its declared names and its protocol are unchanged.
- Class: changes the Lean model and its published claims, so the full process applies.

## Strategy

1. The registry-free library first, with its premises and the staking-free view.
2. The registry instance over it and the existing model, with the terminal discard.
3. All statement signatures frozen and read by the auditor before any proof effort.
4. Proofs, then the satisfying example that meets every premise at once.
5. The import check in the model checker, with its control.
6. Regenerate the consumers the model checker, mirror and coverage tools bind.
7. The paper slice: the register at the new model pin, the Named and staking wording, narration.

## Checkpoints and commits

| Checkpoint | What the auditor reads | Commit |
|---|---|---|
| statements-frozen | library and instance definitions, every statement signature, the case equivalence | local only, never pushed |
| model-green | the model slice candidate with every proof and its narrowed gate receipts | the model commit |
| consumers-green | the same commit with every generated consumer | the model commit, amended in the stack |
| paper | the paper commit, whose pin is the model commit | the paper commit |
| pre-push | final history, attribution grep, aggregate run receipt | both commits |

Final history on the branch: this mandate's planning commit, one model commit, one paper commit, each signed, no attribution of any kind. A rebase moves the paper's printed model pin in all five places (`paper/economics/main.tex`, `docs/economics-paper.md`, its speech companion, and `docs/audio/index.json` and `manifest.json`).

## Touch list

| Path | Edit or create | Why | Collision |
|---|---|---|---|
| `lakefile.toml` | edit | the registry-free library becomes its own Lake library and default target | none open |
| `lean/CardanoLedger.lean`, `lean/CardanoLedger/*.lean` | create | the registry-free library | none |
| `lean/Singular/Model/LedgerBoundary.lean` and its submodules | create | the registry instance and the terminal discard | none |
| `lean/Singular/Lemmas/LedgerBoundary.lean` and its submodules | create | supporting lemmas | none |
| `lean/Singular/Statements/LedgerBoundary.lean` | create | the public statements and examples | none |
| `lean/Singular/Statements.lean` | edit | imports the new statements, so the compiled gate audits them | none |
| `lean/theorem-debt.json` | regenerate | the statement manifest and digests | every model slice |
| `lean/corpus.json`, `driver-corpus.json`, `m1-corpus.json`, `naming-corpus.json`, `lifecycle-corpus.json` | regenerate | source digests over the changed extent; rows unchanged | every model slice |
| `tools/check_model.py` | edit | the import check with its control, reachability over the new library | none open |
| `docs/theorems.md`, `docs/theorems.speech.json` | edit | the new rows and the derived total | every model slice |
| `README.md`, `README.speech.json` | edit | the checked declaration counts | every model slice |
| `conformance/coverage/record/record.json` | regenerate | new statement identities start uncovered | every model slice |
| `conformance/coverage/record/base-record.json` | unchanged | the protected base moves only by a reviewed rebase | — |
| `conformance/coverage/tests/test_inventory.py`, `test_leanscan.py` | edit | population counts | every model slice |
| `conformance/coverage/protected-rejection-restatement.md` | edit only if the coverage tool requires new identities there | restatement record | protected rejection lane |
| `simulator/formal/**`, `simulator/formal/theorem-debt.json` | regenerate | byte mirror of every Lean file, the new library included | every model slice |
| `simulator/corpus.json`, `simulator/identity.json`, `simulator/index.html` | regenerate | embedded corpus, identity, built page | every model slice |
| `docs/economics-paper.md`, its speech companion, `paper/economics/main.tex`, `paper/economics/citations.tex` | edit | register rows, model pin, axiom report digest, Named and staking wording | none open |
| `docs/audio/**` | regenerate | narration of every changed passage | every docs slice |
| `applications/open-datum/**` | unchanged, rebuilt by its job | the application model against the changed root; a changed file is a finding | — |
| `specs/679-ledger-boundary/*` | create | this mandate and its speech | none |
| `onchain/`, `offchain/`, blueprint, `onchain/script-identity.json`, `.github/workflows/` | untouched | model only; the import check rides in the existing model job | — |

No open pull request touches `lean/` (epic owner's check at 15:00 UTC); the writer rechecks before the first push.

## Team

- Writer: Codex gpt-6-astra, reasoning high, in this worktree, one at a time. It gets the whole task and stops green, blocked, or at capacity with a handoff.
- Auditor: Codex gpt-6.1-sol, reasoning high, mute and persistent, in a read-only worktree that tracks the branch; it reads commits and receipts and answers each checkpoint within 15 minutes. A block names a concrete failure scenario; everything else is advisory.
- No draft seat and no other seat.
- Every build, test and gate command runs memory-capped and time-bounded with stdin closed; no process is stopped by pattern.

## Budget and cut line

Aim merge-ready on 17 October, merged before the 20 October freeze. If the writing heads past about eight hours, the ticket owner tells the epic owner at once. The cut, in order: the unknown-key mint statement moves to issue 680 with its state-script premise; then the staking statement moves to its own slice.

## Evidence the pull request will carry

- The hosted runs of every gate row at the exact head, read with the run list and run view commands.
- The auditor's verdict per checkpoint, at commits that are ancestors of the head.
- The statements, each with its premises, as the model check reports them.
- Uncovered: every new statement identity starts uncovered in the coverage record; the correspondence with the compiled policies is issue 681's; the state and request rules' staking statement is issues 680 and 681's.

## Gate

The frozen gate is [its own page](gate.md): the union of the ticket owner's and the gate author's independent tables, one verbatim workflow command per row, with the acceptance line each row carries. No settled row changes during the slice; an adopted addition is a new version with the old rows byte for byte.

Two lines have no hosted reconciliation. That every premise has an example rests on the example statement pinned in the manifest plus the auditor's statements-frozen verdict. That the paper's register lists the new statements rests on the auditor's paper verdict, because no hosted job reconciles the register with the axiom report; the plan review asks whether that gap is filed or closed here.
