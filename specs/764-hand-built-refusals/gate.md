# Gate for hand-built transactions refused by the deployed validators

Issue 764, first slice. This page is for the commit owner, the auditor and the reviewers: each acceptance item, the hosted
job and the verbatim command that proves it. The requirements are in [the specification](spec.md) and the slice in
[the plan](plan.md#slice). Every command is an existing hosted command, or the one this ticket adds, marked
"CI change in this ticket". Hosted checks on the pull request head are the net; the commands below run scoped to what the
slice can break.

## Rows

| Row | Acceptance it proves | Hosted job | Verbatim command | Expected exit |
| --- | --- | --- | --- | --- |
| G1 | the three refusals and the three controls on a development network, each assertion failing on altered input | new `registry.yml` job, "Hand-built transactions refused by the deployed validators on a development network" (CI change in this ticket) | `nix run --quiet .#no-pin-hand-built-refusals` | 0 |
| G2 | the harness and the open-datum package build and lint | `ci.yml` `open-datum-component-build` | `cd applications/open-datum/offchain && nix build --quiet .#component-build`; `cd applications/open-datum/offchain && nix run --quiet .#lint` | 0 |
| G3 | the off-chain package, which the harness reads, still builds and lints | `ci.yml` `offchain-component-build`, `offchain-lint` | `nix build --quiet .#component-build`; `(cd offchain && nix run --quiet .#lint)` | 0 |
| G4 | the new app is a declared check that a workflow step runs | `ci.yml` `declared-checks-hosted` | `nix run --quiet .#declared-checks-classify-controls`; `nix run --quiet .#declared-checks-hosted` | 0 |
| G5 | the workflow's commands resolve | `ci.yml` `workflow-commands-resolve` | `nix run --quiet .#workflow-commands-resolve-controls` | 0 |
| G6 | shell, YAML and Python lint | `ci.yml` `dev-shell` | `nix develop --quiet -c just lint` | 0 |
| G7 | input-output ownership and node confinement still hold for the new harness code and driver | `ci.yml` `dev-shell-checks` | `nix develop --quiet -c just io-ownership-check`; `nix develop --quiet -c just io-ownership-controls`; `nix develop --quiet -c just node-confinement`; `nix develop --quiet -c just node-confinement-controls` | 0 |
| G8 | the code inventory classifies every new source | `ci.yml` `inventory` | `nix run --quiet .#inventory-check`; `nix run --quiet .#inventory-controls` | 0 |
| G9 | pages, diagrams and speech | `ci.yml` `rendered-docs` | `nix run --quiet .#docs-check`, run with only `nix` and `git` on the path | 0 |
| G10 | the existing refusals jobs still pass beside the new one | `registry.yml` `no-pin-registration-refusals`, `no-pin-termination-refusals` | `nix run --quiet .#no-pin-registration-refusals`; `nix run --quiet .#no-pin-termination-refusals` | 0 |

The hosted run of G10 is the net: the diff edits neither driver. The gate does not rerun them locally unless the shared rig
or the harness's existing subcommands change.

## Controls

- G1's two judging assertions are run on the other role's receipt and must fail there.
- G4 fails when the workflow step that runs the new app is removed.

## Budget

Each build or test runs in a named scope, `systemd-run --user --scope --unit=t764-<row>-<n> -p MemoryMax=24G timeout 3600
<command>`. The development-network run (G1) is executed locally once per candidate at most. `just ci` runs once on the
final candidate, then the push. A hosted failure is one repair commit, not a local rerun of the hosted list.
