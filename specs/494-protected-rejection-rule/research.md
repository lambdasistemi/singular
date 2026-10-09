# Research: pull request 508, its eight red checks, and the consumers of the model

This page holds the evidence the [plan](plan.md) summarizes. Everything here was read from hosted
logs, downloaded receipts and the repository at the commits named; nothing was run locally. Job
numbers are GitHub Actions job ids in `lambdasistemi/singular`.

## Story

As the reviewer of this plan, I check that every one of the eight red checks is explained by a
failing assertion I can find in a log, that none is called flaky, and that I know which files a
change to the model reaches, so that no coder is surprised by a consumer nobody listed.

## Pull request 508 and the tree it started from

| Fact | Value |
|---|---|
| Head, base | `a7224021`, base `23964e66` (main of 7 October 2026) |
| Commits | `4ee2082b` the Lean candidate, `a7224021` the non-chain consumer repairs |
| Size | 63 files; the corpus `lean/driver-corpus.json` alone grew by about 17,500 lines |
| State of its base | The base is 74 commits and 514 files behind `e3c9ab01`, after the two-edge ruling retired the success behavior of five of the seven edges |
| Constitution | The pull request moves 1.13.0 to 1.14.0 (proof-backed rejection); main already moved 1.13.1 to 1.14.0 (the two-edge law). Same number, different content. |
| Reviews of the candidate | Two source reviews by an independent model, kept in the epic's record: seven findings: five resolved, one addressed within bounded coverage, one declared an integration limit |
| Its own record of the blocker | `compatibility.md` on that branch: the early-rejection row expects compatible requests to be rejected inside the windows, contrary to the model |

## The eight red checks

All eight are required by the repository ruleset on `main`. All eight are green on the pull
request's own base (hosted runs 37689074674 and 37689074644 at `23964e66`) and on main at
`e3c9ab01` (runs 37916595037 and 37916594763), so none is flaky and none is red on main: the
candidate introduced each failure.

| Check (job at `a7224021`) | The failing assertion in the log | Why it fails |
|---|---|---|
| Batch instructions asked of the model (113246214112) | `conformance run: FAILED: conformance: batch harness: the model refused a lawful batch`; the line before it: `rejectBatch tamper=none model="refused" modelReason="reject-evidence-missing" chain="accepted"` | The harness books two insertions of fresh keys and rejects both inside the processing window, with no evidence. The story is unlawful under the rulings and the question carries no evidence. |
| The running book (113246214299) | `model and chain refuse for different reasons for reject at rejected: chain=deposit-returned lean=reject-evidence-missing` | The reject is placed after both windows (lawful by expiry) but the question carries no evidence; the model refuses at admission before it reaches the refund the chain refused. |
| Retire-active-key (113246214562) | `FAIL: retire-active-key retirement evidence moved`. Running the workflow's assertion clause by clause on the downloaded receipt, exactly one clause is false: `([.steps[8,9,10].request] \| unique \| length) == 1` | The candidate added the booked `reference` and `submittedAt` to the model question of every exit. Three separately booked attempts at one deletion (references 9, 10, 11) therefore differ. A fold never reads those fields. On main (`e3c9ab01`) the same evidence script compares only `request.key` across those steps, so a re-derivation does not hit this clause. |
| Reject and retract refund controls (113246214618) | `model and chain refuse for different reasons for reject at rejected: chain=deposit-returned lean=reject-evidence-missing` | As the running book: lawful placement after the windows, no evidence. |
| Early rejection inside the windows (113246214580) | `model and chain refuse for different reasons for reject at early-processing: chain=deposit-returned lean=reject-evidence-missing` | The first failure is the missing evidence. Even with evidence, the untampered reject of a foldable request inside either window is refused by the model and accepted by today's validators. |
| The generic rows (113246214876) | `model and chain disagree for reject at cg08-key: model="refused" chain="accepted"`, then `FAIL: the session did not complete all 13 rows` | The rejection-after-the-windows row sends no evidence; the failure ends the shared session, so the other twelve rows are lost with it. |
| Development shell checks (113247725310) | `application checks: 2 failed`: `FAIL the regenerated corpus equals the committed corpus` and `FAIL every committed scenario replays from its own JSON (28 differing ...)`; `Recipe application-model failed on line 56` | The open-datum application's committed corpus embeds requests; requests gained fields, so the regenerated corpus differs. |
| Theorem coverage gate (113246214715) | `FAIL-CLOSED population: ... 5 claimed but no longer discovered ... 17 discovered but unclaimed ... re-emit the record population; a shrinking denominator is a finding, never a cleanup` | Statements whose text changed (for example `admission_refuses_first`, `admitted_exit_is_the_exit`) have new digests, and new statements need claims in the record. |

The receipts of the retire-active-key and refund runs were downloaded from the run's artifacts
and the assertion clauses evaluated locally with `jq`; only the clause named above failed.

## What the model change reaches

Reading the earlier candidate's diff against the base and searching the current tree for every
user of the names it changes gives this inventory. The touch list assigns each to a slice.

| Consumer | Why it moves | How it is regenerated |
|---|---|---|
| `lean/Singular/Statements.lean`, `Lemmas.lean`, `M1.lean` | Statements over `inPhase2`, `exitAdmission`, `admittedExitStep`, `exitRefusal` change signature | By hand, with proofs |
| `lean/driver-corpus.json`, `m1-corpus.json`, `corpus.json`, `lifecycle-corpus.json`, `naming-corpus.json` | Requests and configurations gain fields; new accepting and refusing rows | The model runner |
| `lean/theorem-debt.json`, `m1-theorem-debt.json`, `docs/theorems.md` | Restated and new statements have new digests | The model check tool |
| `simulator/formal/*`, `simulator/corpus.json`, `identity.json`, `index.html`, `stories.json` | A byte-for-byte mirror of the Lean sources, plus derived pages | `node simulator/build.mjs` and `identity.mjs` |
| `applications/open-datum/corpus.json`, `ledgers.json` | Embedded requests | The application's own `check` executable |
| `conformance/lean/DriverTransport.lean`, `conformance/app/Conformance/Run/Live.hs`, its tests | Questions carry evidence and booked metadata | By hand |
| `conformance/coverage/record/*.json`, `tests/test_inventory.py`, `test_leanscan.py` | Population counts and digests | The coverage gate tool plus a published restatement table |
| `.github/workflows/conformance.yml` assertions, `conformance/BOOK.md`, `docs/consumer-conformance.md`, `docs/conformance-evidence.md` | Rows and their prose | By hand, with the rows' receipts |
| `specs/287-traced-refusal-reasons/extent.md` | Its row for the rejection-before-deadline requirement states that the model gives a reject no admission | By hand; the extent check reads it |
| `.specify/memory/constitution.md`, `tools/check_model.py` | The translation rows and the surface reconciliation | By hand |

## Facts that shape the plan

The conformance suite already has a recorded state `unmet-by-ruling`, used for the consumer
requirement that a folder must not reject a request during its processing window. That row says
the chain accepts the reject and the consuming project requires it refused. The model after this
ticket sides with the consumer; the chain does not until ticket 495. That is the precedent the
pending question relies on.

The earlier ticket 395 recorded that the model "reads no time for a reject" and that a validator
property admits a reject under every validity range. Those statements describe the base and
become historical; they are not edited, because history is not rewritten.

Hosted checks run the six devnet rows on a real node, each taking several minutes; the model,
simulator, coverage and application checks run without one.

## Open items found

One question is open and blocks only the in-window rows: what the public suite shows until the
validators change. The reading that a request naming an excluded edge is rejectable at once was
ruled by the epic owner as an application of the first ruling. Neither blocks the model design.
