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

One hosted journey, built like the keri-stub journey: a flake app and a hosted job whose check name is added to the repository's required checks in the same change. One development node, started by the existing devnet executable, funds one generated wallet. Every command below is a separate process of the packaged binaries.

1. A test-only harness executable, classified in the component inventory, boots a registry with the real contracts and the real boot whose datum pins an always-true active policy compiled for the test, then mints a token named after a key under that policy. It is a test harness and not a product command: no product command can pin a policy the release does not derive.
2. Against that registry, `singular` inspect, describe, fold, reject and reclaim, a bundle that names it given to submit, and `open-datum` inspect, insert, update, terminate and fold each end in the refusal that names the active policy. Each prints no registry content, and the number of transactions on the chain, read independently of the commands, is the same before and after.
3. The control: a registry made by the product's own create with the same binaries, with honest pins. Inspect and describe print their ordinary receipts and a write proceeds.
4. Evidence for the on-chain hardening ticket: whether the genuine witness policy of the forged registry can be minted in a fold of that registry. The result, accepted or refused and by which check, is kept in the journey's receipts and in the pull request. No fix is attempted.
5. The check the first pull request names as missing: a fold that alters one pinned policy in the new state datum is submitted, and the node refuses it with the state contract's refusal named pins-altered.
6. The ticket for the browser build to expose the gate is searched, placed in its milestone and opened.

Any leg the harness cannot carry is recorded with the reason in the pull request and reported, not dropped.

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
