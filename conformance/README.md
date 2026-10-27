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

`list` prints the complete 55-row inventory from `rows.json` with each
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

`rows.json` carries the complete inventory: the 47 owned consumer rows,
the four owned rows that state the registration journeys of the no-pin design
against the previous design (below), the three owned update and termination journey
statements, plus checkpoint-and-treasury-policy (cardano-keri's checkpoint policy), recorded as out-of-scope
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

## Registration journeys: the previous design against the no-pin design

Four rows (group `registration-journeys`) state, for a booked registration that is
folded, reclaimed and cleaned up, what the previous design did and what the no-pin
design does, and the decided difference: a registration that can never be folded
waits for its reclaim window instead of being rejected early. The outcomes are those
the declarations `OpenDatumApplicationHeld.Money.oldAllocation` and
`OpenDatumApplicationHeld.Money.newAllocation` state; the rows name them and retype
no number. No executable comparison with the application-held model exists yet, so
the rows are published `uncovered` and give that reason. The hosted jobs
`no-pin-registration-journey` and `no-pin-registration-refusals` run the packaged
commands on a development network and read the chain's own record; they are a
separate evidence boundary and establish nothing about agreement with the model.
The previous design's early-rejection rows stay published as they were.

## Update and termination journeys: the previous design against the no-pin design

As an integrator, I can read the controller's payload update, termination booking
and public-data fold as three separate requirements, and see their comparison
with the previous design. The update preserves protected control, all tokens and
the deposit floor in both designs. The no-pin booking pays the protected deposit
to the treasury at booking; the no-pin fold pays the request's whole value to the
folder before the folder's separately funded fee and pays no treasury. The previous
design paid no treasury at booking, then paid the carrier value to the treasury
and only the declared tip to the folder at the fold.

The three rows in `holding-journeys` name the same model's `oldAllocation` and
`newAllocation`, together with the update and termination statements. They remain
published uncovered: no executable comparison with the application-held model
exists yet. The hosted `no-pin-registration-journey` continuation and
`no-pin-termination-refusals` exercise packaged commands and node refusals on a
development network. Those chain observations establish what was run; they are a
separate evidence boundary and do not establish agreement with the model.

## Registration checked against executable Lean

The [registration story](lib/Conformance/Edge/Register.hs) receives its context
from the caller and checks the real delivery against a packaged Lean executable.
See [the example and its failing control](test/README.md). This first comparison
covers delivery to the requested recipient; it does not establish full theorem
coverage or replace the other live checks.
