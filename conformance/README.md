# Singular consumer conformance (issue #63)

Row runner for epic 18: executes the generic registry operations the
naming demonstration can never exercise against a real devnet, with
attributable refusals, executing negative controls and measurements
against the devnet protocol maxima.

```sh
nix run ./conformance#conformance -- list
nix run ./conformance#conformance -- run CG02 CG03 CG04 CG05
```

`list` prints the complete 40-row inventory from `rows.json` with each
row's state (`executed` / `bound-elsewhere` / `uncovered` /
`out-of-scope`). `run` executes rows against a real devnet; the
blueprint comes from the caller at run time:

```sh
mpfs="$(nix build --quiet --no-link --print-out-paths ../onchain#plutus-blueprint)"
MPFS_BLUEPRINT="$mpfs" nix run --quiet .#conformance -- run CG02 CG03 CG04 CG05
```

The runner sets its own unique `TMPDIR` before starting a node and
never touches the default path, so concurrent devnet lanes on one host
keep their databases.

`rows.json` carries the complete 40-row inventory, not only the rows
this slice executes. CK06 (cardano-keri's checkpoint policy) is out of
scope and recorded in `docs/consumer-conformance.md`, never claimed.
