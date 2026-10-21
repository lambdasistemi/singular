# Plan for the pin gate

Two pull requests. Both change off-chain code and documentation only: no on-chain code, no Lean model, no script hash.

## Why two

The gate on every command, the documentation and the offline refusal rows are the safety fix. The hosted forged-pins row needs a new test harness that builds a registry on a development network with a policy compiled for the test; it would hold the safety fix behind it. The first pull request refers to issue 730; the second closes it.

## First pull request: the gate everywhere

1. Red proof first: for each row of the command table, a command run over a session whose registry is real in form and pins a forged active policy, plus the honest control. Every forged run must fail on main and pass with the change. The application pin cases (script, hash, compiled) have their own forged runs.
2. The library compares the application pin for every pin form that knows its own script, exposes the comparison, and records whether the application pin was compared.
3. The gate can take the candidate applications of one program and returns the one the datum selects; open-datum passes its two.
4. Every command of the table routes through the gate as the table says. The old early reads of the state datum (open-datum's mode read, the interrupted-create report) are removed or moved behind it in the same change.
5. Receipts and the describe page carry the application pin standing; describe stops presenting the datum's pin as derived from the release.
6. Submit takes the release for a bundle that names a registry; a create bundle needs none.
7. Create compares the pins of the datum it reads back.
8. Documentation: the protocol page, the library reference with the worked example, the command reference for describe and submit, the recovery page if it shows a submit command line; speech companions and narration clips regenerated for every changed page.

## Second pull request: the forged-pins row

A test harness builds a registry with the real contracts and the real boot whose datum pins an always-true active policy compiled for the test, mints a token named after a key under it, and runs inspect, describe and every write against it on a development network; the control with honest pins proceeds. The row also records whether the genuine witness policy of that registry can be minted in a fold, as evidence for the on-chain hardening ticket, and does not try to change it. The browser build ticket is opened here. The row is a hosted job and a required check.

## Consumers that move with the first pull request

- Provider and resolution consumers: open-datum's suite, the conformance application's backend, the node confinement controls and the keri-stub value (its hash pin is now compared).
- Command line flag consumers: the declared options, the help snapshots, the parser corpora, the application settings specification, the documented flags check, and every page or script that shows a submit command line (a bundle that names a registry now needs the release).
- Refusal text consumers: grep the old wording of the closed-update refusal, the pending-create report and the describe release block in tests, journeys and pages.

## The gate

The existing hosted commands, scoped to what the slice touches, each seen red then green:

| Command | Hosted job |
| --- | --- |
| `cd offchain && nix run --quiet .#cage-tests -- --match "<the new rows>"`, then once whole | The bounded registry journey, narrated end to end |
| `cd offchain && nix run --quiet .#lint` | Off-chain lint |
| `cd applications/open-datum/offchain && nix run --quiet .#open-datum-tests` | Open-datum tests |
| `cd applications/open-datum/offchain && nix run --quiet .#lint` | Open-datum component build |
| `nix run --quiet .#cli-flags-check` and `nix run --quiet .#cli-flags-controls` | Documented CLI flags and refusal controls |
| `nix run --quiet .#docs-check` and `python3 tools/check_presentation_repo.py` | Rendered documentation |
| the keri-stub and conformance rows the coder maps at the start of the first slice | their hosted jobs |

`just ci` runs once, on the final candidate. Hosted checks at the exact head, read by exact name, are the net.
