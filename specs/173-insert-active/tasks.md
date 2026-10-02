# #173 — tasks

Tasks are vertical slices judged against the parent `SLICING-CRITERION.md`.
Acceptance lines inside the implementation task are review checkpoints, not
layer-shaped tasks.

## Accepted design slice

- [x] **executable-design-prove-export-constructed-insertactive-transaction — executable design.** Prove and export the constructed
  `insertActive` transaction, duplicate `key-exists`, the reachable two-key
  `net-mint-mismatch` witness, parameterless open admission and executable JS
  keyed parity. Runnable: `nix run --quiet .#model-check` and
  `nix run --quiet .#simulator-check`. Accepted revision: `854f56f`.

## Implementation slice — one runnable

- [ ] **insert-active-from-released-archive-in-one — `insert-active` from the released archive.** In one Opus
  owner run, implement boot-pins-open-registry-identities, open-approval-binding-and-burn-controls, active-insertion-delivers-requested-token, duplicate-key-and-keyed-mint-controls,
  released-command-runs-without-checkout and updated-encoding-consumers across the exact surface in `plan.md`. After
  merge, a person with the extracted archive and no checkout runs the
  documented packaged `insert-active` invocation against a devnet, sees the
  open registry boot, one active token at the named wallet output, the same-key
  `key-exists` refusal and the separate wrong-key `net-mint-mismatch` control.

  Required copies: Lean identities/derived consumers; on-chain validators,
  blueprints and identities; boot/request/fold builders; conformance rows and
  workflow assertions; coverage records; end-to-end; journey; command page, consumer
  conformance page, archive manifest and speech companions.

  Size: one four-hour run after excluding retirement of other-edge on-chain-edge-case rows, one
  final acceptance checks execution. Every listed copy is mandatory. At the cap, an
  incomplete task remains unchecked and unpushed; only unrelated newly
  discovered work can become a remainder.

## Gate-held, not a task

Before insert-active-from-released-archive-in-one starts, its task list must receive a blind Grok slicing PASS and
acceptance checks must be authored independently by Grok and Codex, then frozen by the
ticket owner. During insert-active-from-released-archive-in-one, every acceptance line needs an approved senior
decision review at an ancestor SHA. Before push, the ticket owner runs the
latest acceptance checks once; after push, the exact-head registry, conformance and root CI
jobs must be green. The epic owner, not this ticket, merges and tags.
