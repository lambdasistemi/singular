# Singular consumer conformance (issue #63)

Row runner for epic 18: executes the generic registry operations the
naming demonstration can never exercise against a real devnet, with
attributable refusals, executing negative controls and measurements
against the devnet protocol maxima.

```sh
nix run ./conformance#conformance -- list
nix run ./conformance#conformance -- run CG02 CG03 CG04 CG05
```

`list` prints the complete 41-row inventory from `rows.json` with each
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

`rows.json` carries the complete inventory: the 40 owned consumer rows
plus CK06 (cardano-keri's checkpoint policy), recorded as out-of-scope
so the boundary is visible. `rows.json` never carries `executed` —
that state is computed from run receipts, never typed. A `run` writes
one `receipt-<ROW>.json` per executed row under its own output
directory (never the tracked tree); `list` prints a row as executed
only when a receipt for it exists and matches the current base:

```sh
MPFS_BLUEPRINT="$mpfs" nix run --quiet .#conformance -- run CG02 CG03 CG04 CG05 --receipts-dir ./out
nix run --quiet .#conformance -- list --receipts ./out
```

(`CONFORMANCE_RECEIPTS=DIR` when the flag is absent; default none.)
CK06 is out of scope and recorded in `docs/consumer-conformance.md`,
never claimed.
