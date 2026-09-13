# #79 landed — identities and clause/test mapping for the consumer lane

For epic 18, through root, per `NOTE-013` and `NOTE-020`.

## Merge identity

| field | value |
|---|---|
| PR | https://github.com/lambdasistemi/singular/pull/85 |
| candidate | `bf9f42db5ca420171f9f13cd892f005292a1aa7e` |
| merge commit | `56e0fcdbd09cb3326a63e490f6c7ed2511cdc9ef` |
| base it rebased onto | `47217fa` (your #82/#83 work; both preserved) |
| issue | #79, closed |

## Compiled script identities now on `main`

Unapplied, from `onchain/script-identity.json`, regenerated from the pinned
compilation:

| validator | hash | moved? |
|---|---|---|
| `state.state.{spend,mint,else}` | `d42860fa972c8a325daae773adc372795c48cf365d0a72b137c749d3` | **yes**, from `64d1afbfe585…` — the ownership gate relocated to `End` |
| `request.request.{spend,else}` | `8970c2865b1a6218b6baed938e8f5474514ba4db7e531fbc597b912c` | **yes**, from `6b5ce701…` — the insert-only retraction guard |
| `staking.staking.{withdraw,else}` | `4ab26c95029067185f709d140300cccb15b0b20bbd62a7e9aa2e2e10` | unchanged |

Applied `state.state` observed on a devnet: `ce7615f6ba4de80dfa9b9c6aef680666472ba4ed7e640ff55aad7c6e`.
`docs/consumer-conformance.md` CA04 and the observed-environment block are
re-pinned to these; `offchain/naming-correspondence.md`'s `validatorScript` row
likewise.

## Clause/test mapping

**`Singular.fold_iff`** (`lean/Singular/Statements.lean:66`) — an equivalence
with **five** conjuncts:

```lean
step s (.fold items mint net w) = .ok t ↔ w.nativeSpend = true ∧
  foldItems s items = .ok t ∧ sameNet t.logical mint = true ∧
  (nonzero mint = true → w.representativeMint = true) ∧
  (actionNonzero net = true → w.applicationMint = true)
```

No owner and no privileged folder appears among them, and the missing owner is
the only thing the repair removed. `foldItems s items = .ok t` is load-bearing:
an invalid item list does not become acceptable by satisfying the witness
conditions, and every per-item `foldOne` refusal still decides whether
`foldItems` succeeds at all — in both directions.

Entry point: `state` validator `spend` → `Modify` → `validModify`. `End` keeps
`validateOwnership`.

**`step .withdraw` / `step .escape`** — `withdraw-insert-only` for any non-insert
request, `completion-only-custody` for escape. Entry point: `request` validator
`validateRetract`, which now requires `requestValue is Insert(_)` and otherwise
keeps the owner signature, phase-2 window and state-token binding.

### Executed checks

Two implementation layers plus discrimination controls:

- **property/state-machine against the compiled validators on a real ledger** —
  a generated fold property (seed 79, n=6, 0 discards, bisection shrink) and an
  exhaustive retraction operation-class sweep (3/3) against an oracle derived
  from fixed Lean;
- **user-story integration rows** at the production boundary: permissionless
  fold accepted, refusal controls, `End` without owner refused, `End` with owner
  accepted, `Update`/`Delete` retraction refused, `Insert` retraction accepted;
- **mutation census, no survivors** (discrimination only, not a layer):
  restoring the owner gate kills the permissionless-fold row; dropping ownership
  from `End` kills the `End` control; removing the insert-only guard kills the
  `Update`-retract row — each for its intended reason.

CI additionally runs "The issue-79 repair rows on a real devnet" and "Onchain
Aiken unit and property suite passes" on every change.

## What this unblocks for you

**CG20 must now expect ACCEPT** with all fixed Lean preconditions satisfied — a
fold no longer needs the registry owner. Your CG14/CG15 stake-hook rows stay
could-not-execute: `staking.ak` is unchanged here, still serves only `withdraw`,
and the certificate-purpose question is a separate slice I own.

## Debt this did not close

- refund-arithmetic, phase-window and output-preservation weakenings on the
  `Modify` path have no discriminating rows in this slice — assigned to your
  consumer gates under #80;
- Lean-proof and simulator layers for these invariants are out of scope here and
  count as neither implementation layer;
- the connected `Active`→`Over` naming lifecycle is still unbuilt; #74 stays
  held. This repair is its prerequisite, not its delivery.
