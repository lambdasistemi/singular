# Two users, one registry, no shared files: the mandate

As Bob, I have an empty home, the state token Carl published, my own wallet and a
Koios URL. I run `singular registry inspect`, `insert`, `fold`, `terminate`, `reject`
and `reclaim` with `--state-token` and no directory option, on the registry Alice and
Carl use, and I never open their files. Alice does the same, and we fold each other's
requests. This is the work order for the remaining acceptance of
[the reconstruction ticket](https://github.com/lambdasistemi/singular/issues/381). It
sits under [the Koios demonstration](https://github.com/lambdasistemi/singular/issues/371)
and reads with the [spec](spec.md), the [plan](plan.md) and the [task list](tasks.md).

## What is being built on

The branch is stacked on PR 525, the managed-state ticket
[#485](https://github.com/lambdasistemi/singular/issues/485). The desk owns that
branch and this ticket never edits it.

| Fact | Value |
| --- | --- |
| Repository, issue, pull request | lambdasistemi/singular, issue 381, draft PR 433 |
| Worktree and branch | `/code/singular-381-registry-replay`, `feat/381-two-terminals` |
| Stacked on PR 525 | `feat/485-managed-state` at `026576268e916c964426d4a4be304d35544d9816`, itself on main `e48e3098` |
| Nine commits of this ticket on top | from `9d690989` (reconstruction plan) to the narration refresh `2d995b8e`; their messages were completed and their trees are unchanged |
| Previous tips, kept | `archive/e371-381-before-485-stack-20261009` at `046706c4` (before the stack); `archive/e371-381-before-message-rewrite-20261009` at `53a6600075f8d42d85ac360b313819555fcde6f9` (before the nine messages were completed); the remote head `2adc3101` as `archive/e371-381-before-refresh-20261008` |
| Main when this was written | `76bb09936f79a97adb2d359a0c5eb8806d2af5aa`; this branch is not rebased onto it before the desk grants the merge slot |
| Lean | tree `16ee2d4a4233130460b7e36daffbe6f2b8b9a8ef`, the same tree on main, on PR 525 and here |
| Constitution | version 1.13.0, sha256 `4e99d8486db1b88c414ad6e57c4ca1472f9afd8915e2a0b63539bd99fbf72131` |
| Scratch and temporary files | `/srv/lanes/singular-e371/381-live` (`TMPDIR` and `RUNNER_TEMP`) |

Until PR 525 is pushed, nothing of this branch is pushed: a push now would publish
commits of the desk's branch that are not on its remote. If the tip of PR 525 is
rewritten under this stack, work stops and the ticket owner re-bases first.

## Rulings in force

These are quoted, not referenced.

- **Command-line split ([#528](https://github.com/lambdasistemi/singular/issues/528)).**
  "Build against the library's request and fold, not the open-datum envelope."
  That ticket leaves `singular registry` with `create | fold | reject | reclaim |
  inspect` only and moves `insert`, `update` and `terminate` into the open-datum
  executable. Here, every assertion is about a request, a fold, an edge, a root and a
  refund. None is about the envelope bytes or the `--payload` file. The commands that
  book a request are assembled in one place in the harness, so the split moves them
  without rewriting the journey.
- **The inline request datum, with no size cap.** "A request carries the datum value it
  names for its delivered output" (constitution 1.13.0, the `tx` and `settle` rows). A
  folder reads that datum from the pending request on the chain. No file the booker
  wrote is an input, and the harness never assumes or truncates a datum size.
- **The request tag ([#529](https://github.com/lambdasistemi/singular/issues/529)), where
  relevant.** The ticket says the processor "discovers requests by that tag". It is not
  built. The journey observes requests only through command receipts and chain reads,
  so the tag changes nothing here and nothing here depends on how requests are found.
- **Staffing (2026-10-09).** "Codex is out for now. Claude seats at the highest levels,
  GLM and Muse at the working levels." Ticket owner: Claude Sonnet 5.5 at extra-high
  effort. Source writer: Muse through the pi harness, `/home/paolino/.local/bin/muse
  --approve`, in the ticket worktree. Mute persistent auditor: GLM through the pi
  harness, `/code/llm-settings/pi/glm --approve`, on a read-only audit worktree. Gate
  authors: the ticket owner and the auditor. "No Codex seat is launched or kept." The
  untrusted flash model is never launched. No helper or substitute is added.
- **Token join, never the directory (epic owner release, 2026-10-09).** Bob starts with
  the state token, his wallet and a Koios URL. An assertion that reads a registry or
  state directory is rewritten, not kept. That covers a foreign actor's directory, the
  creator's directory and any `--state-dir`.
- **Stacking and the merge slot.** The stack is declared in the pull request body with
  the words "stacked on PR 525". This ticket merges immediately after #485, in the slot
  the desk grants. It does not rebase onto main before that slot.

## What must hold

Each item names the check that proves it. A check runs the shipped `singular` binary,
or it is a named control; reading the harness source is never a check. The frozen gate
(last section) maps each item to the command that carries it.

### Docs baseline

- [ ] **The narration and speech records agree with the pages.** On the rebased base the
  narration check reports six stale clips and seven orphan clips, and the presentation
  check reports the stale speech stamp of `docs/singular-node.md`. Main, PR 525 and the
  previous base pass the narration check. The commit that clears it is the first commit of the
  ticket's source work and contains nothing else. It is `02510b95`, made by the ticket
  owner before the source writer started, with the narration key's standing authorization. Proof: `python3 tools/narrate.py
  --check` and `just check-presentation` exit 0, and `nix run --quiet .#docs-check`
  exits 0.

### Joining and isolation

- [ ] **Alice and Bob act on a token alone.** After the creator makes the registry, each
  actor runs on a fresh home that the harness has just created. An actor is given the
  state token printed by the creator's receipt, its own wallet key, the provider URL, the
  network magic, the network-time source and the public blueprint, and nothing the
  creator or the other actor wrote. Every command an actor runs carries `--state-token`
  and none carries `--registry` or `--state-dir`. Proof: the packaged journey, whose
  report row for each actor's first command is built from that command's receipt.
- [ ] **No actor opens a file that belongs to the creator or the other actor.** Every
  actor process and the creator's processes are traced for file access, and the journey
  fails if any traced path lies under another party's home. Proof: the whole journey
  passes with the guard on (the positive run), and the control below fails.
- [ ] **The guard can fail, for that reason only.** After a passing positive run, the
  control `SINGULAR_TWO_ACTOR_CONTROL=foreign-open` runs one real `singular` command
  with `--state-dir` aimed at the other actor's state root. The run must end failed at the
  guard, naming the path. A setup failure, a refusal by the command or a pass is not
  detection. Proof: the control job exits 1 with that single diagnostic, and a stand-in
  run shows the classifier tells the control's failure from a setup failure.
- [ ] **No assertion reads a registry or state directory.** Every journey assertion reads a
  command receipt, a chain read made through `inspect` with the state token, or an
  access trace. "Nothing was submitted" is shown by `inspect` before and after (root and
  pending requests unchanged), not by reading a journal. The harness does not hash,
  list or read any home or state root. Proof: the control above, plus the auditor's
  review of the harness; a text search is a lead, not evidence.

### The two users' lifecycles

Rows are named by the published requirement text in the harness. The fourteen
requirement texts stay byte for byte as they are in the harness today.

- [ ] **Each actor inserts a key and folds the insertion** (rows "Alice inserts a key and
  folds her insertion", "Bob inserts a key and folds his insertion"). Before inserting,
  the actor's `inspect` shows the key absent. The fold receipt's request is the booking
  receipt's request, and the next `inspect` shows the key active.
- [ ] **Each actor terminates and the other folds the termination** (rows "Alice folds
  Bob's termination from her own public replay", "Bob folds Alice's termination from his
  own public replay"). The controller books the termination of its own key. The other
  actor, who holds no copy of the booking, folds it. The fold receipt names the edge
  `updateTerminal`, the booking's request and the folder's own identity.
- [ ] **Another actor folds an insertion** (row "Another actor folds an insertion"). The
  booker's insertion is folded by the other actor from the pending request on the chain,
  in both directions, with no file from the booker.
- [ ] **Only the controller updates or terminates a key** (row "Another controller cannot
  update or terminate a key"). The other actor's `update` and `terminate` on a key are
  refused by name, with the controller refusal class and a non-zero exit, and `inspect`
  shows the root and the pending requests unchanged.
- [ ] **Reject and reclaim across actors** (rows "Bob rejects Alice's expired request",
  "Alice cannot reclaim Bob's request", "Bob reclaims his request during its retract
  window"). A request left past its processing deadline is rejected by the other actor
  once its retract window has closed, and refused by name while it is open. The wrong
  owner's reclaim is refused by name. The owner's reclaim inside the window succeeds and
  its return is bound to the request.
- [ ] **Both actors see the fold's root after every fold** (row "Both users inspect the
  fold's state root after every fold"). After each fold of the journey, both actors'
  `inspect` root equals the root in that fold's receipt. A fold folded wrongly would
  differ.

### History faults seen through the actor's command

- [ ] **A withheld fold refuses `HistoryIncomplete` and returns no trie** (row "Withheld fold
  history refuses HistoryIncomplete without a trie"). A forwarding provider in front of
  the actor's `--koios-url` answers an empty list for the state token's transactions, and
  the actor's real `inspect` refuses with that name and returns no root.
- [ ] **A replay that maps an edge wrongly refuses `RootDoesNotChain` and returns no
  trie** (row "An altered request edge refuses RootDoesNotChain without a trie"). A
  provider that serves an altered request cannot reach this refusal: the replay compares
  every served output with the one the booking created and refuses first as a history
  material mismatch. The refusal is reached only when the replay itself computes a root
  that the chain's state output does not hold. The control therefore runs a real actor
  `inspect` against the real devnet and provider with a binary built only for this
  control, whose replay maps one edge to another, and requires `RootDoesNotChain` naming
  the registry and the fold, and no root. That binary is never the packaged product, is
  built from a committed, reviewable patch, and leaves production sources unchanged on
  disk. The row's wording is not changed. If this mechanism cannot be met within the
  fences, the row stays pending with the reason, and the ticket owner files the question.

### Publication

- [ ] **Row states are computed from the commands' receipts.** Each of the fourteen rows
  is `passed` only when every receipt it needs exists and agrees; otherwise it is
  `pending`, listed with the ticket it waits on. No state is typed. A control removes one
  receipt and the row becomes `pending`; a second control shows the journey exits with a
  failure if a row that waits on nothing is not `passed`. The two rows "Alice reads the
  registry page and joins by state token" and "Bob reads the registry page and joins by
  state token" read a page that [#503](https://github.com/lambdasistemi/singular/issues/503)
  has not built, so they stay `pending` on #503. The join by token they name is executed,
  and its receipts are attached to those rows as partial evidence.
- [ ] **Harness evidence is a marked appendix.** Access traces and the fixture creation are
  listed after the product rows and labelled as the harness's own evidence.
- [ ] **The journey runs in the hosted checks.** `nix run --quiet .#registry-two-actors`
  and the foreign-open control each run as a hosted job on the pull request head. Both
  are added by this ticket.
- [ ] **The repository's checks stay green on the touched paths.** Format, lint, the file
  inventory, the presentation check, the speech and narration records, and the component
  actor spec (eleven examples) pass; the full aggregate passes once on the final head.

## The runs, and how each ends

The ticket would run for hours if sent as one task, so it is sent as four runs, one
writer at a time, under one frozen gate. Each run is a whole task with an end: green, a
question filed because the writer is blocked, or stopped at capacity with a handoff.

| Run | Content |
| --- | --- |
| One | The docs baseline as its own first commit (done: `02510b95`). Then the token-only actors, the isolation guard with its positive and negative control, the first actor rows (each actor inserts and folds; the first `inspect` roots), the receipt-computed report skeleton, and the hosted jobs. |
| Two | Terminate-and-fold-by-the-other, another actor folds an insertion, the controller refusals, and the `inspect` root after every fold. |
| Three | Reject and reclaim across actors. |
| Four | The two history faults, the final report and appendix, the verification record, and the aggregate. |

Runs two to four are briefed from this page and the frozen gate when the run before has
all its checkpoints approved. They need no new decision.

## Out of scope, by number

- [#485](https://github.com/lambdasistemi/singular/issues/485): the desk's join lane, the
  state directory and session layer. This ticket uses it and never edits it.
- [#528](https://github.com/lambdasistemi/singular/issues/528): the command-line split.
- [#529](https://github.com/lambdasistemi/singular/issues/529): the request tag.
- [#503](https://github.com/lambdasistemi/singular/issues/503): the registry page.
- [#492](https://github.com/lambdasistemi/singular/issues/492).
- [#437](https://github.com/lambdasistemi/singular/issues/437) and
  [#471](https://github.com/lambdasistemi/singular/issues/471): restoration.
- [#518](https://github.com/lambdasistemi/singular/issues/518): concurrent booking.
- [#477](https://github.com/lambdasistemi/singular/issues/477): recovery.
- [#505](https://github.com/lambdasistemi/singular/issues/505): the bounded contract.

Also out: any change to `offchain/cli`, the library, the validators, Lean, the registry
partition's blueprint or production configuration; a new registry on any public network;
a transaction or key on a public network; and any helper seat.

## Evidence this ticket will produce

The pull request body is filled from these, in the repository's template.

- The candidate commit and tree, the rebased base, and the Lean tree.
- One receipt per journey command and a report whose fourteen rows are computed from them.
- The raw logs of the packaged journey, the foreign-open control, the withheld-history
  control and the replay-fault control, each with an exit status and a hash.
- The hosted job runs on the exact head.
- The independent review's verdict, bound to that commit.

What stays uncovered, said before the work: the page part of two rows (#503); a real
public Koios provider (the journey uses the development network's Koios-shaped provider);
a replay fault is shown through a control build, not through a provider (above); mixed
applied and rejected folds stay a component-level oracle; the seven-edge lifecycles are
outside the demonstration by the operator's ruling in the [decisions](decisions.md).

## Budget

One team for this epic. One producer at a time, for ticket work. Journey runs go on a
fresh development network each, with receipts under the 50 MiB cap and scratch under
`/srv/lanes/singular-e371/381-live`. No public-network write and no private key. The
aggregate `just ci` runs once, on the final candidate. A local rerun of a hosted job
list is not a gate: a hosted failure is one repair commit.

## The frozen gate

Written independently by the ticket owner and the auditor, then synthesized once into
version 1, then completed by version 2 before any source writer runs. It lives in the ticket owner's
runtime record, and its hash binds it.

| Gate | Value |
| --- | --- |
| Path | `/home/paolino/.orch-runtime/singular/epic-371/to-381-sonnet-1/handoffs/gate-v2.md` |
| sha256 | `a1c4e62ba62488aa5849042d61231343c39f8028787822af9d1574654093ed73` |
| Version 1 | `gate-v1.md` beside it, sha256 `bdf2acb3e24bb3832b303504e52cf8d097ef7b23f654668ce9c710abf4fd6945`; version 2 is version 1 byte for byte plus one section on the journey's four exit statuses and how a run is judged before the last run |
| Inputs | the ticket owner's table, sha256 `5d477dde9ee79f197f9522231becf676f9d87ccc21c51257ed1a4a31abcc7d62`; the auditor's table, sha256 `6a7ae2c278224449f50431f7f7f0ca0ac9dca0a8f2daa3336ac67af179a51ec6` |

Every row is an existing hosted command, or a command this ticket adds to the hosted
checks and the pushed head proves. A row that is added is marked in the gate. A change to the rows is a new gate version with the settled rows byte for byte the same.
