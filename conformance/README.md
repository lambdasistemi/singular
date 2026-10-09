# The registry's promises and evidence

A registry commits a map of keys to a root. Requests ask it to change a key;
folds apply those requests. A consumer needs to know what this registry
promises, what has been demonstrated, and what remains uncovered.

Read [the product book](BOOK.md), then follow [the test reading path](test/README.md)
from registration to batch behavior. The stories are generated from the same
story language programs that execute. The appendix checks our evidence machinery.

The book distinguishes receipt validation from chain execution. To gather
new chain evidence, use the runner below. Row identifiers here are command
arguments; the book uses the requirements' own words.

## Run against a devnet

```sh
nix run ./conformance#conformance -- list
nix run ./conformance#conformance -- run insert-key insert-occupied-key permanent-retire-active-key
```

`list` prints the complete 48-row inventory from `rows.json` with each
row's state (`executed` / `bound-elsewhere` / `uncovered` /
`out-of-scope`). `run` executes rows against a real devnet; the
blueprint comes from the caller at run time:

```sh
blueprint="$(nix build --quiet --no-link --print-out-paths ../onchain#plutus-blueprint)"
REGISTRY_BLUEPRINT="$blueprint" nix run --quiet .#conformance -- run insert-key insert-occupied-key permanent-retire-active-key
```

The runner sets its own unique `TMPDIR` before starting a node and
never touches the default path, so concurrent devnet lanes on one host
keep their databases.

`rows.json` carries the complete inventory: the 47 owned consumer rows
plus checkpoint-and-treasury-policy (cardano-keri's checkpoint policy), recorded as out-of-scope
so the boundary is visible. `rows.json` never carries `executed` —
that state is computed from run receipts, never typed. A `run` writes
one `receipt-<ROW>.json` per executed row under its own output
directory (never the tracked tree); `list` prints a row as executed
only when a receipt for it exists and matches the current base:

```sh
REGISTRY_BLUEPRINT="$blueprint" nix run --quiet .#conformance -- run insert-key insert-occupied-key permanent-retire-active-key --receipts-dir ./out
nix run --quiet .#conformance -- list --receipts ./out
```

(`CONFORMANCE_RECEIPTS=DIR` when the flag is absent; default none.)
checkpoint-and-treasury-policy is out of scope and recorded in `docs/consumer-conformance.md`,
never claimed.

The current registry supports registration and permanent termination. The
original broader update, deletion, reincarnation and Absent-retirement
requirements remain published with their original text and uncovered status.
Current retirement has a separate requirement and receipt; it cannot satisfy
those broader promises. Excluded wire encodings are tested as refusals, and
their refusal creates no Absent state or deletion refund. Application deposit
release is checked separately against the Open Datum application law.

## Registration checked against executable Lean

The [registration story](lib/Conformance/Edge/Register.hs) receives its context
from the caller and checks the real delivery against a packaged Lean executable.
See [the example and its failing control](test/README.md). This first comparison
covers delivery to the requested recipient; it does not establish full theorem
coverage or replace the other live checks.
