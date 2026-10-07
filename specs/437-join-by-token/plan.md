# A registry joined from its state token: plan

Read the [spec](spec.md) for the requirements. The design was ruled in two rounds on 2026-10-06:
- the identity, the page, existing registries and the Lean impact were accepted as proposed;
- references became a convenience found by hash, with no on-chain lock. The provider query takes
  the shape decided by the Lockness epic owner
  ([lockness#39](https://github.com/lambdasistemi/lockness/issues/39)).

The operator's 2026-10-07 rulings remove caller-supplied reference hints and retire the public
saved-selector promise. Code, tests, help and these documents change in the same implementation
slice. Historical receipts keep their original scope; revised discovery needs its own controls.

## Strategy

The operator's 2026-10-07 cut makes PR1 the token-only command and connected Bob journey. PR2
follows on the same open issue for the wallet, page, report action identity and new reference
features. The archived earlier plans and working/index snapshot preserve that unfinished work.

The registry's identity moves from a file to a derivation. One library module resolves a state
token into everything a command needs and refuses by name when the chain disagrees with the
release. References are found by script hash, through a new provider query. The saved identity
(`registry.json`) and its checks are deleted in the same slice that stops reading them.

No Lean, validator or blueprint change. The off-chain resolver is an admission check outside the
law, like `checkPins` today.

## Vertical slices

| slice | runnable outcome | starts after |
|---|---|---|
| PR1: the token is the registry | provider query and mint record; resolver and named refusals; provider-first lazy-wallet reference search; token-only existing commands; no registry.json; complete create publication funding before boot; Bob's connected hosted journey without Alice files; explicit saved-selector promise retirement | main `21f1d8560be008a8b2045e583fc384f10809260e` |
| PR2: protected funding and references | closed wallet-output boundary, narrowed fund inputs, reference publication and retirement, automatic publication and their connected evidence | PR1 merged |
| PR2: the page and report | deterministic chain-derived page, tagged release archive, independently derived report action identity and their controls | PR1 merged |

The existing GLM commit owner and persistent mute auditor continue; no extra seat is needed.
The owner may push a coherent draft after final static preflight while the fresh exact-range audit
and exact-head hosted CI run in parallel. Merge requires both plus the actual Bob story and its
deliberate-open discrimination. Historical source approvals are not approvals of the new range.

## Live boundaries and evidence

| claim | evidence |
|---|---|
| Koios answers the existence query as designed | recorded Koios fixtures taken from preprod (read-only), replayed in unit tests |
| commands work from an empty directory on the state token alone | exact-head hosted journey through the facade, with Bob's directory empty at start and no Alice context passed |
| each refusal fires for its cause | a devnet or unit negative control per refusal name |
| `create` leaves a registry others can join | hosted create then Bob's connected commands, with no Alice file copied or opened; deliberate-open control fails the run |

Local final-head static preflight runs root lint, conformance HLint, conformance format checking
and offchain lint, each with its exact hosted command and actual exit recorded. Focused checks
retain the frozen carriers. Full devnet, Demo1, conformance and recovery campaigns run hosted.
Public conformance state is computed from receipts; no planning checkbox or local green closes
an uncovered product requirement.

There are no preprod writes and no new registry.

## Coordination

- **#381 separate actors (draft PR #433)** consumes this path: no identity record and no join
  command. Its two-actor journey uses `--state-token`.
- **#419 is inherited at the exact base.** Lean tree `16ee2d4a4233130460b7e36daffbe6f2b8b9a8ef`
  and constitution 1.13.0 bind carried request datum values, public fold construction and carrier
  settlement. Preserve its public-history controls and removed private preimage dependency.
  PR1 changes no Lean, validator, blueprint or script identity relative to that base.

## Ceilings

| artifact | ceiling |
|---|---|
| spec | 200 lines |
| plan | 120 lines |
| each model | 150 lines |
| tasks | 80 lines |
| a compiled commit-owner packet | 300 lines |
