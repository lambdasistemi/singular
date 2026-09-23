# Replay the registry's live stories

The [registration](../lib/Conformance/Edge/Register.hs) and
[retirement](../lib/Conformance/Edge/Retire.hs) chapters are programs over the
same four instructions: submit a model edge request, submit a named tamper,
observe the resulting registry and transaction, and compare with the
executable Lean driver. The [unnamed sequence](../lib/Conformance/Edge/Sequence.hs)
uses those instructions without a chapter theorem binding.

The interpreter creates a local Cardano devnet, allocates stable model IDs
while constructing each request, submits one fold for exactly that request,
and reads the chain result. Every accepted step compares the driver's nine
declared observations: configuration, custody, held tokens, leaf, mint,
payments, root, state and transaction. A discovered-value perturbation check
must make the comparison fail for each observed leaf and array, except the
declared `outputMinimumAda` leaf. `requiredSigners` remains a named model gap;
the transaction's observed signer value is still compared.

Each chapter writes one receipt with a `steps` array. Every step records its
request, model outcome, chain outcome, comparison and the observation and
perturbation evidence when accepted. The registration chapter records a
same-key refusal and a redirected-delivery attempt beside an accepted
untampered control. The retirement chapter records a connected active-token
burn, an Absent-key refusal and an unknown-key refusal. A refusal names the
state script hash; an empty node trace is recorded as empty, without inventing
a script reason.

From `conformance/`, use the compiled blueprint and retain the receipts:

```sh
export REGISTRY_BLUEPRINT="$(nix build --quiet --no-link --print-out-paths ../onchain#plutus-blueprint)"
nix run --quiet .#conformance -- book --receipts-dir /tmp/registry-book --output /tmp/registry-book/BOOK.md
```

The book command requires both chapter receipts and the unnamed sequence
receipt before rendering success. Its inventory statuses are computed from
receipts; uncovered requirements remain visible. The two-request batch mint
rule is a gap because the driver evaluates one request per transaction.
`deleteActive` burns the active token from the holder's own UTxO, which the
fold consumes, and is compared with the model like the other accepted edges.
The node rejects `witnessTerminal` while booking its request; that step carries
its observed reason as a gap, without claiming a completed fold.

For the appendix alone, run:

```sh
nix run --quiet .#conformance-appendix-tests
```

The appendix checks the receipt loader, comparison machinery and rendering.
It does not replace a devnet run. The appendix has 97 examples; the live
chapters retain five registration steps and seven retirement steps.
The former field-level tests for a removed per-theorem receipt body are not
counted as current evidence.
