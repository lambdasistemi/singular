# #184 — implementation plan

## Status and vertical cut

There is one implementation task and one runnable: the generic conformance
session executes CG21 and emits its complete receipt. Fixture, receipt
validation, workflow return and final documentation are one vertical; none is
a separate layer ticket.

The first docs commit temporarily records the honest pre-run state. The final
implementation checkpoint restores an executed claim only after CG21 runs and
the receipt is asserted.

## Surface map

| layer | owned surface | required observation |
|---|---|---|
| behavioral authority | accepted Lean `854f56f` | read-only; four named statements remain unchanged |
| conformance execution | `conformance/app/**` | accepted fold, two refusals, two accepting controls, committed roots |
| evidence contract | `conformance/lib/Conformance/Receipt.hs` and its tests | complete fail-closed CG21 edge evidence |
| inventory and CI | CG21 in `conformance/rows.json`; generic rows in `conformance.yml` | invoked row, exact receipt set, verdict and structural assertions |
| reader-facing copy | consumer page and speech | pre-run wording replaced by candidate-bound executed claim |

## Owner sequence

The commit owner first commits an executable RED bundle for the acceptance
lines. It then turns A184-FOLD/A184-CONJUNCTS, A184-DUPLICATE,
A184-KEYED-MINT/A184-SEQUENCE, and A184-WIRING/A184-COPIES green as committed
checkpoints. Each checkpoint carries one decision record for the persistent
auditor and the owner continues without waiting.

Five submitted transactions plus two accepting controls are expected from the
#173 handoff. This is a sizing fact, not an implementation algorithm. Each
landed fold must advance the committed trie before the next transaction is
proved.

## Gate and review

Before dispatch, two independent 15-minute gate authors map every acceptance
line to the verbatim conformance generic-row CI step or the root
`nix develop --quiet -c just ci` command and cite a real red run per command.
The ticket owner synthesizes their union and freezes Gate S. A missing CI
command is escalated; no bespoke substitute is invented.

The commit owner and mute persistent auditor launch together in distinct
panes. The auditor trusts Gate S, runs nothing and vets the decisions recorded
at RED, each green acceptance checkpoint and pre-push. Push waits for an
approval at every checkpoint and one final frozen-gate run on the head.

## Copies and release boundary

Copies: `rows.json`; generic workflow invocation, expected set, accounting and
verdict section; receipt schema and tests; consumer page and speech. After the
ticket owner's push, remote CI must be green on the exact head before the draft
can become ready. The epic owner merges and owns any release action.

## Budget and remainder

The commit owner has four hours. One final Gate S consists of the full generic
rows workflow step and the root CI command. At the cap, only a green coherent
vertical may be pushed; incomplete behavior remains unaccepted and is returned
for a new cut with its evidence preserved.
