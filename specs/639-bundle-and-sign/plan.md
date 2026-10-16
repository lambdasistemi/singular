# Plan for signing a bundle

Issue 639. One pull request, two slices of at most 90 minutes each.

## Decisions

- The bundle is JSON, version 1, signers by address (public), effects as untrusted plain lines. Approved by the desk.
- The offline checks are: version, envelopes decode, identity equals the body hash, deadline equals the body's validity upper bound, required signers covered by the signers' key hashes, this vault's address among the signers.
- Output: one witness envelope per transaction named by its identity, created exclusively in the output directory (default: the bundle's directory); witness paths on standard output, a summary on standard error.
- Offline evidence: the packaged control runs the real binary with its network namespace unshared where the runner allows it, and otherwise rests on the verb taking no provider option plus a connection canary. The hosted run decides and the journal records which carried it.
- Fixture: a synthetic unsigned body with no keys and no required signers, committed as data and rebuilt by a spec that fails on any difference. The control inserts the vault's own address into the signers at run time.
- Lean is silent: the bundle, the witness and the vault sit outside the model.

## Slices

- Codec and witness: the bundle module, the detached witness helper, the fixture and the unit specs.
- Verb: `wallet sign`, documentation with narration, the packaged controls and their step.

## Gate

Existing hosted commands, each as its step runs it. In `offchain/`: `nix run .#cage-tests -- --match Bundle`, the same with `Sign`, `nix run .#lint`, `nix build .#component-build`. At the root: `nix run .#cli-flags-check`, `nix run .#cli-flags-controls`, `nix run .#wallet-vault-controls`, and inside `nix develop` `just lint` and `just io-ownership-check`; `python3 tools/narrate.py --check` when documentation changes; `nix run ./offchain#registry-cli-build-graph-check`. Every run goes through a memory-capped, time-bounded scope with stdin closed.
