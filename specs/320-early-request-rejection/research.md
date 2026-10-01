# Research: where the old reject timing lives

## Model against code at the base

Base `3f04e50d293b80360a3234ebf3114abc8172d851`, Lean blob `9c75b37380d5e6f56691345bcc50b60d3faf184b`, constitution 1.11.0 (blob `d852b09c9dbf77c967e0461cef8fed36c0ef70c2`).

| Concern | Lean | Code at the base | Verdict |
|---|---|---|---|
| reject admission | `exitAdmission` (:1201) returns `none` for `.reject`; `exitStep` (:1068) runs `emptyResult` | `registry/fold.ak` `Rejected` arm halts `not-rejectable` unless `shared.is_rejectable`; `request.ak` `validateContribute` expects `in_phase1 ∨ is_rejectable` | code contradicts clear Lean: repair |
| reject payment | `obligations .reject` (:989) owes the owner `request.deposit` | fold pushes `ReturnDeposit { owner, floor: held − tip }` and a positional refund | matches; keep |
| reject state effect | `emptyResult`: state unchanged, no mint | state continuation checked by the modify judgement | matches; keep |
| fold timing | none: `refusal` (:532) and `step` read no time | update refused `not-phase1` outside phase 1 | validator stricter than Lean, pre-existing, kept (spec Limits) |
| retract admission | `retractAdmission` (:1193): insert-only, owner signature, `inPhase2` | `retractRefusal` in `request.ak` | matches; untouched |

Historical live evidence that the defect is reachable: during ticket 287 an adequately budgeted phase-1 rejection, transaction `2d39d6389075c808849e3ae19078be34aa4c966150ad758298d370c8a5b70a94`, was refused by the node. A traced replay of its captured context reached `not-rejectable`. The phase-3 control was accepted. That evidence is retained with ticket 287 and is not rerun here.

## Every caller of the old rule

| Path | What it encodes | Disposition |
|---|---|---|
| `onchain/validators/shared.ak` `is_rejectable` | the predicate | delete |
| `onchain/validators/cage.ak` `is_rejectable` | test-facing wrapper | delete |
| `onchain/validators/registry/fold.ak` `Rejected` arm | the state refusal | drop the timing guard; refund duties unchanged |
| `onchain/validators/request.ak` `validateContribute` | the request admission | admit when the matching action is `Rejected`; processing window as today |
| `onchain/validators/cage.props.ak` | three properties built on the predicate | restate against the new rule; no property asserts early non-rejectability |
| `onchain/validators/cage_reject.tests.ak` | `reject_in_phase1`/`reject_in_phase2` expect failure | become accepting tests; future-dated test reworded |
| `onchain/validators/cage_contribute.tests.ak` | `contribute_in_phase2` expects failure, `contribute_in_phase3` accepts | split by the matching action |
| `onchain/validators/deposit_exits.tests.ak` | comment citing the predicate | reword |
| `onchain/validators/types.ak`, `cage_fixtures.ak` | doc comments | reword |
| `docs/onchain-validator-owners.md` | lists `not-rejectable` among the fold's reasons | drop it |
| `offchain/lib/Singular/Registry/TxBuilder/Reject.hs` | selects only expired or future-dated requests; validity starts after the latest retraction deadline | remove both timing rules |
| `offchain/lib/Singular/Registry/Wire/Request.hs` `requestPhase` | docs say it mirrors the validator's rejectability | restate as a resuming client's choice of exit; behaviour unchanged |
| `offchain/e2e-test/.../CageSpec.hs` | only "rejects a phase-3 request" | add processing- and retraction-window cases |
| `conformance/app/Conformance/Run/Live.hs` reject arm | waits until after the retraction deadline | place the reject in the window the story names |
| `conformance/lib/Conformance/Story/Live.hs`, `Edge/Exit.hs`, `Book.hs` | prose "once it may no longer be folded" | restate; CG23 places its rejects after the windows explicitly |
| `conformance/app/Conformance/Run/CgRows.hs` CG09 | expects refusal, verdict `agrees-with-model` | expect acceptance, verdict held |
| `.github/workflows/conformance.yml` generic rows | CG09 expected `agrees-with-model`, held set CG11 CG12 CG19 | CG09 held, held set CG09 CG11 CG12 CG19 |
| `docs/consumer-conformance.md` CG09 row | "refuse" | current observation: accepted and held; historical refusal kept |
| `conformance/rows.json` CG23 | requirement text "once the request may no longer be folded" | restate the two timing sentences only; append CG24 (gate, The rows change) |
| `conformance/lib/Conformance/Rows.hs` | `expectedRowCount = 45` and its description | 46, CG24 named |
| `conformance/app/Main.hs` `runBook` | the book runs five live chapters | six, CG24 added |
| `conformance/lib/Conformance/Book.hs`, `conformance/lib/Conformance/Receipt.hs` | per-row chapter text and per-row step completeness | add CG24's case; no receipt field, constructor or encoding changes |
| `conformance/app/Conformance/Run.hs`, `conformance/app/Conformance/Run/Control.hs` | the row dispatcher and per-issue row lists | add CG24 |
| `conformance/README.md`, `docs/consumer-conformance.md` | row counts and ranges ("45 rows, 44 owned", "CG01–CG23") | 46 rows, 45 owned, CG01–CG24 |
| `.github/workflows/registry.yml` e2e comment | "rejects a phase-3 request" | reword |

Callers of the builder whose behaviour must survive: the register journey's resume path, which rejects pending requests only once `requestPhase` says reject; the CS05 conformance row; the e2e phase-3 case. None of them selects a subset. In each caller's scenario every pending request is already past its windows when the builder runs, so removing the timing filter does not change what those callers reject. A caller with fresher pending requests would now reject those too. The builder's contract states this, and choosing a subset is out of scope.

## How far a changed state hash reaches

Changing `registry/fold.ak` changes the state script hash `1f06886c…` (`state.state.*`). Changing `request.ak` changes `7ce2f0ec…` (`request.request.*`). The literal pins:

| Pin | Path | Moves |
|---|---|---|
| `registryStateHash` | `onchain/validators/witness.ak:29` | the witness script hash `c817182b…`, and `open_datum` (`01524a2c…`), which imports it |
| `mpfs_state_hash` | `naming-onchain/validators/naming.ak:204` | `retirement_custody` (`302d802f…`) and `application` (`b9badeaa…`) hashes |
| retirement custody hash | `naming-onchain/validators/application.ak`, `fixtures.ak` | the `application` hash again |
| envelope bytes | `onchain/validators/open_datum.tests.ak:147`, `offchain/test/Singular/Application/OpenDatum/EnvelopeSpec.hs:52,71` | test fixtures only |
| manifests | `onchain/script-identity.json`, `naming-onchain/script-identity.json` | regenerated by `just script-identity-regen` in each flake |

No check compares the naming pins with the built hashes today. `naming-onchain`'s identity check compares only its manifest with its own blueprint, and the deployment loader cross-checks neither blueprint. An unchanged `mpfs_state_hash` would compile, regenerate and pass. The plan adds that comparison to the deployed identity check.

A pre-existing observation, not widened here: a request at the request address whose datum is a hash, not inline, is admitted by `Contribute` in the processing window and is not folded by the state, so its value is unconstrained in that fold. After the repair it still has no matching action outside the processing window, so it is refused there.

Historical evidence also names these hashes (`conformance/review/**`, `conformance/test/fixtures/live-steps/overflowed-retirement.txt`, `conformance/BOOK.md`). Those files record past runs and are not rewritten.

## The CI that already checks each class

| Class | Workflow line | Command |
|---|---|---|
| Aiken suite, properties, format, script identity | `registry.yml:168-170` | `nix flake check` in `onchain` |
| naming suite and identity | `registry.yml:77-79` | `nix flake check` in `naming-onchain` |
| naming value refusals | `registry.yml:80-84` | naming blueprint, then `nix run --quiet .#record-value-tests` in `offchain` |
| deployed identity both ways | `ci.yml:33`, `ci.yml:45` | `nix build --quiet .#build-gate`; `nix shell --quiet nixpkgs#jq nixpkgs#diffutils -c bash offchain/deployment-identity-check.sh` |
| off-chain lint, build, unit, vectors | `ci.yml:64`, `ci.yml:96`, `registry.yml:413-414`, `registry.yml:193-194` | `nix run --quiet .#lint`; `nix build --quiet .#component-build`; `nix run --quiet .#cage-tests`; `nix develop --quiet --command just vectors-check` |
| devnet e2e through the product builder | `registry.yml:305-309` | registry blueprint, then `nix run --quiet .#cage-tests-e2e` |
| conformance book and unit suite | `conformance.yml:144-146` | `nix run --quiet .#conformance-tests` |
| exit row CG23 | `conformance.yml:236-290` | blueprint, `run CG23`, receipt assertions |
| generic rows incl. CG09 | `conformance.yml:337-526` | blueprint, `run CG02 … CG21`, expected-debt assertions |
| root CI | `ci.yml:255` | `nix develop --quiet -c just ci` |
| release assembly | `ci.yml:308` | `nix run --quiet .#release-artifacts -- "$dir"` |

## Baseline at the base

Root CI, `nix develop --quiet -c just ci`, at the clean base (tree `914a80b8`), 2026-10-01 10:45–11:11 UTC, 1561 s, exit 1. Every recipe up to and including `format-controls` passed. In `lint`, `actionlint` 1.7.8 hung: zero CPU for 23 minutes, all threads parked on futexes, no children. It was stopped after its state was captured, so the run is an interrupted environment failure. The snapshot shows a hang. It does not prove the cause. The same binary, configuration and files run directly exit 0 in under a second, which shows the tool can finish this input. It does not complete the omitted lint families. Two `actionlint` processes from other lanes have been parked the same way on the host for ten days. `actionlint`, `yamlfmt` and `lint-controls` are therefore unverified at the base. The planning head's root CI runs with stdin closed (`</dev/null`) and is the complete check.
