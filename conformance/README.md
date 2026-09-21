# The registry's promises and evidence

A registry commits a map of keys to a root. Requests ask it to change a key;
folds apply those requests. A consumer needs to know what this registry
promises, what has been demonstrated, and what remains uncovered.

Read [the product book](BOOK.md), then follow [the test reading path](test/README.md)
from registration to batch behavior. The stories are generated from the same
DSL programs that execute. The appendix checks our evidence machinery.

The book distinguishes receipt validation from chain execution. To gather
new chain evidence, use the runner below. Row identifiers here are command
arguments; the book uses the requirements' own words.

## Run against a devnet

```sh
nix run ./conformance#conformance -- list
nix run ./conformance#conformance -- run CG02 CG03 CG04 CG05
```

`list` prints the complete 44-row inventory from `rows.json` with each
row's state (`executed` / `bound-elsewhere` / `uncovered` /
`out-of-scope`). `run` executes rows against a real devnet; the
blueprint comes from the caller at run time:

```sh
blueprint="$(nix build --quiet --no-link --print-out-paths ../onchain#plutus-blueprint)"
REGISTRY_BLUEPRINT="$blueprint" nix run --quiet .#conformance -- run CG02 CG03 CG04 CG05
```

The runner sets its own unique `TMPDIR` before starting a node and
never touches the default path, so concurrent devnet lanes on one host
keep their databases.

`rows.json` carries the complete inventory: the 43 owned consumer rows
plus CK06 (cardano-keri's checkpoint policy), recorded as out-of-scope
so the boundary is visible. `rows.json` never carries `executed` —
that state is computed from run receipts, never typed. A `run` writes
one `receipt-<ROW>.json` per executed row under its own output
directory (never the tracked tree); `list` prints a row as executed
only when a receipt for it exists and matches the current base:

```sh
REGISTRY_BLUEPRINT="$blueprint" nix run --quiet .#conformance -- run CG02 CG03 CG04 CG05 --receipts-dir ./out
nix run --quiet .#conformance -- list --receipts ./out
```

(`CONFORMANCE_RECEIPTS=DIR` when the flag is absent; default none.)
CK06 is out of scope and recorded in `docs/consumer-conformance.md`,
never claimed.
