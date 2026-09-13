# NOTE-053 — complete target/successor evidence and boot-input binding

Read in full and ACK in `STATUS.md`. Resume the SAME `%994` Pi process,
native session, `/tmp/t80e-rival-witness` tree and offline evidence runtime
from the terminal `2026-09-13T03:42:06Z` handback. Preserve that handback and
its frozen index as an incomplete historical snapshot; do not overwrite its
sources, raw outputs, failed compiles or receipts. This is the remaining
NOTE-147/049 evidence-path work, not a new campaign, context reset or ledger
release.

Root's full frozen review is:

`/tmp/projects/singular/milestone-1/handoffs/rival-root-note048-terminal-handback-review.json`

SHA256:
`51e2540df7ee8d998b9997b82b51ff79fada8ab7dc8215b75809007c41efc5a6`.

Preserve the bounded progress it verifies: Main
`1cd4024a3aba082430cadb09e11b5708207883cbb810143de6decdfa4b1a365e`,
six named source files byte-identical in the Nix source, the shared production
`deriveAssetName` seed verifier, the hash-free mintless constructor,
boot-binding control exit 0/two PASS, mintless control exit 0/four PASS, and
the unchanged 22/5 denominator. Command-v2
`c0dc313073f10dacf612630fec81c0c2d0b67fa246be3e32b26fb70f4013bc16`
is bash-clean, UNEXECUTED and NOT RELEASED; its fresh result root is absent.
None of those offline facts is ledger or acceptance credit.

## 1. Write both exact target encodings on the real path

At the actual target construction/submission site, retain both:

- `target-body.cbor` from the body of the exact signed target; and
- a distinct stable `target-signed.cbor` containing the complete exact signed
  transaction value passed to `submitTx`, including witnesses, redeemers and
  scripts.

The full writer must consume that same `signed` value immediately on the real
path; do not reconstruct it from the body or call only a helper declaration.
Keep the analogous boot encodings. Add an offline typed round-trip/control
using a meaningful signed transaction fixture with nonempty witness/script or
redeemer material. It must prove body identity is preserved by the full
encoding and that replacing the full encoder with a body-only encoder loses
the required witness/script material and is rejected. File existence,
nonempty bytes, source grep or comparing two witness-free encodings is not a
control.

## 2. Make every real UTxO observation independently recoverable

Replace the summary-only `renderUtxos` evidence at each actual pre/post query
path with records that retain, for every observed entry:

- the exact query address/scope used for that query;
- the complete exact `TxIn` outref;
- the actual output address;
- exact serialized full `TxOut` bytes; and
- decoded coin, complete value/assets, datum and all other fields needed to
  recover B's configured seed/NFT/address/root/value successor or refused
  input liveness.

The real query result must feed this writer. Do not pass separately hand-built
summaries or detached fixtures as if they were the runtime observation. Add an
offline round-trip/negative control showing exact serialized `TxOut` recovery
and detecting loss of address or datum/assets; the path must fail closed on a
body/summary-only substitute.

Name immediate-after-submit snapshots explicitly `pre-confirmation`; they may
be retained but cannot be cited as the confirmed successor.

## 3. Persist the actual later result boundary

For `Submitted`, only after the existing confirmation/observation step:

- bind the complete target `TxId`;
- query and retain the exact target-created B successor as its `succIn` plus
  full `succOut` evidence under section 2;
- retain the old B anchor/input's later observation proving its actual state;
- retain distinct record-address, custody-address and state-address queries,
  each honestly labelled with its own query address and result;
- retain expected and decoded roots, exact B policy/token quantity, address and
  complete value so the existing Boolean `SuccessorFacts` can be independently
  recomputed.

The current `post-confirmation-record.txt` queries custody and is therefore
mislabeled. Correct the real path and preserve the old file/handback as the
historical defect; do not relabel old bytes into evidence they are not.

For typed `Rejected`, persist the complete typed raw result and explicit exact
named application subject/non-budget classification. Then execute and retain
the two exact fresh liveness queries already used by the runtime decision:
attempted record and attempted anchor, each with query address, outref and full
serialized/decoded TxOut evidence. Boolean liveness alone, a setup/query
failure or a different address is not refusal evidence.

## 4. Exercise boot-body input conversion, not supplied tags

Repair the boot-binding control so its consumed reference list is derived from
the actual `bootBody` inputs using the same transaction-input-to-reference
conversion used by the driver. Do not separately construct ASCII `refOf` tags
and pass them alongside a body that the verifier never observes.

The positive must contain the configured seed plus a distinct consumed fee
input, derive the token from that exact configured seed through production
`deriveAssetName`, and pass the shared verifier on refs extracted from the
body. The wrong-seed discriminator changes ONLY the selected configured seed
to the also-consumed fee input while retaining body, actual mint, policy,
inputs and token; it must fail for the intended seed/token mismatch, not an
arbitrary `Left`, missing input, malformed fixture or setup error. Retain the
prior supplied-ref control as bounded verifier-unit evidence only.

## 5. Verify and freeze without executing the command

Rebuild and rebind every changed driver/control source, both actual `-O0`
executables and the Nix derivation/source closure. Execute the unchanged 22/5
offline denominator and the new signed-transaction, TxOut and body-derived-ref
controls with true compile/run exits, complete diagnostics and negative-control
discrimination. Preserve all earlier failures and successful receipts under
distinct names; never overwrite them.

Return a new frozen handback/index with exact source, binary, Nix, control and
command identities; write and bash-check a self-contained three-variant command
using a new guarded result directory that remains absent. Stop for owner/root
source-and-evidence review.

No node, socket, query, submission, official wrapper or ledger-command
execution. No replay or second ledger grant, new seat/session/model, product or
compositor work, model/schema adoption, final tuple migration, commit, push,
merge, release or epic acceptance. `%993` NOTE-038 proceeds independently.
