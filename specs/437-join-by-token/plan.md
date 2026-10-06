# A registry joined from its state token: plan

Read the [spec](spec.md) for the requirements. The design was ruled in two rounds on 2026-10-06:
- the identity, the page, existing registries and the Lean impact were accepted as proposed;
- references became a convenience found by hash, with no on-chain lock. The provider query takes
  the shape decided by the Lockness epic owner
  ([lockness#39](https://github.com/lambdasistemi/lockness/issues/39)).

## Strategy

The registry's identity moves from a file to a derivation. One library module resolves a state
token into everything a command needs and refuses by name when the chain disagrees with the
release. References are found by script hash, through a new provider query. The saved identity
(`registry.json`) and its checks are deleted in the same slice that stops reading them.

No Lean, validator or blueprint change. The off-chain resolver is an admission check outside the
law, like `checkPins` today.

## Vertical slices

| slice | runnable outcome | starts after |
|---|---|---|
| The token is the registry | the provider query and mint record (Koios, facade, fixtures); the resolver and its refusals; references found by hash from three sources; `--state-token` on every command; `registry.json` neither written nor read; publication funding checked before the boot; demo scripts run each actor from an empty directory | base `9011ca17` |
| Anyone publishes | `publish-references`, `--publish-references`, `retire-references`; coin selection skips reference outputs | the first slice |
| The page | `registry describe`, as Markdown and as `--json` | the first slice |

The second and third slices are independent of each other. Each slice runs one commit owner and
one mute persistent auditor, and is pushed only as an approved candidate. If a slice runs long,
its green checkpoint is integrated and the rest is split into a follow-up.

## Live boundaries and evidence

| claim | evidence |
|---|---|
| Koios answers the existence query as designed | recorded Koios fixtures taken from preprod (read-only), replayed in unit tests |
| commands work from an empty directory on the state token alone | the devnet journey through the facade, with the second actor's directory empty at start |
| each refusal fires for its cause | a devnet or unit negative control per refusal name |
| `create` leaves a registry others can join | the devnet journey: create, then another actor's command, with no file copied |

There are no preprod writes and no new registry.

## Coordination

- **#381 separate actors (draft PR #433)** consumes this path: no identity record and no join
  command. Its two-actor journey uses `--state-token`.
- **#419 changes the request format.** There is no blueprint conflict, because this ticket changes
  no script. `preimages/` stays #419's scope.

## Ceilings

| artifact | ceiling |
|---|---|
| spec | 200 lines |
| plan | 120 lines |
| each model | 150 lines |
| tasks | 80 lines |
| a compiled commit-owner packet | 300 lines |
