# Registry commands through a ledger provider

As a registry user, I want each command to obtain ledger facts from a hosted
provider, so that my machine needs neither a node nor a local chain index.
This is the contract for [the provider interface ticket](https://github.com/lambdasistemi/singular/issues/383),
under [the Koios demonstration](https://github.com/lambdasistemi/singular/issues/371).
The intake was accepted, and main already carries the generic provider and
evidence types, the Koios adapter, local evaluation with pinned time, the
pure provider and trie tests, command composition and the private
development-network facade. Their presence is not a passing test. The
remaining delivery, owned by [the plan](plan.md), is the complete removal of
the obsolete node-internal read and index paths with every retained consumer
migrated, and the ticket's checks green on the resulting candidate.

## The user's stories

As a requester or folder, I run create, insert, update, terminate, fold and
reject and reclaim with the same ledger-provider capabilities. Preview and inspect need
no signing key. An unverified fact may help build a transaction; the ledger
still checks its inputs, signatures and application proof when it is submitted.
Inspect displays the verdict of the facts it used.

As an integrator, I receive a receipt identifying the network, session,
session binding and verdict of every consumed fact. Koios declares Unbound:
several calls in one session do not promise an atomic ledger snapshot. A tip
response is an unverified observation and never manufactures a bound chainpoint.

As a provider maintainer, I supply raw outputs, protocol parameters, generic
asset history and submission results in my own effect monad. I do not know
which asset is a registry. Evaluation, pinned time conversion, bounded
confirmation, registry interpretation and application proofs belong to singular.

As a folder using a just-confirmed booking, I wait until the provider exposes
that exact output before opening the build session for its fold. A status
answer alone does not establish output visibility. A bound or timeout expires
with a named result, preserving submission history without resubmitting.

## The terminal and its trust boundary

The executable is a [Lockness terminal](https://github.com/lambdasistemi/lockness/blob/eeb378174b68ba31105a4fed776dc51e28fb9528/docs/concepts.md).
Its application service computes locally. The ledger provider supplies raw
facts and untrusted reconstruction material. Demo 1 has no anchor.

```mermaid
flowchart TD
  Ledger[Cardano ledger] -->|Raw ledger data| Provider[Ledger provider]
  Provider -->|Unverified facts| Terminal[singular terminal]
  Terminal -->|Local computation| Application[Built-in application]
```

The diagram follows ledger facts into local computation. Signed transactions
travel through the provider to the ledger, which accepts or refuses them.

History contains full transaction CBOR and resolved spent outputs, with
reference-output dependencies available where interpretation needs them.
It is reconstruction material, never Evidenced or Verified history. The
existing local application-root check remains mandatory; agreement with a
provider's state output does not authenticate either side against the ledger.

As a command maintainer, I read leaves and build every edge's membership or
non-membership proof through TrieState m. It reports the registry's state
policy and token name from create, the selected state output and root, and
explicit coverage from checked create and an unbroken reproduced trie-changing
chain to the observed root, or a named refusal. Equal-root state moves are
excluded from coverage records under the epic owner's ruling. A missing mirror
or incomplete required chain never stands for an empty registry. The first instance wraps the current
mirror; a pure fixture trie exercises the same proof paths. The complete public
lineage backend is the separate reconstruction ticket's implementation.

TrieState is part of the built-in application service. Its proofs relate local
computation to the selected state root, not ledger authentication. Selection
uses the state output read in the command's session. An Unbound session still
has no atomic ledger point; the interface must preserve that limit rather than
claim a bound point for the mirror.

## What every implementation must preserve

One built transaction consumes one session. Each fact used for input selection,
fees, collateral, script context and command output is recorded once with that
session's binding and its verifier verdict. Confirmation may acquire later
sessions because it observes progress after submission. It never supplies
another session's facts to the already prepared transaction.

Demo 1 uses the uninhabited NoWitness type. Its only verifier returns
Unverified with the reason "no verifier configured". The abstract Verified
result type is available for future parameters; no concrete verifier, witness
decoder, CSMT check, anchor client or key policy is shipped. Replay's root check
must never upgrade a ledger fact's verdict.

The new capabilities are polymorphic in the witness and effect types. A pure
state fixture must exercise every provider operation, including acquisition,
composed queries, history and submission. Transport exceptions, retries and
rate limits belong inside the adapter's effect, outside the capability types.

## Model authority and correspondence

The intake was frozen at recovery commit
`872c0ecf3c7cf1a10293793523c8521d5ef9aae9` from
[PR #382](https://github.com/lambdasistemi/singular/pull/382), since merged;
that history is recorded in [the decisions](decisions.md). The delivery reset
of October 7, 2026 rebinds this ticket to main
`6efe1f119a2332484e690b4c128c4bc5fd4d689b`. The
[constitution](https://github.com/lambdasistemi/singular/blob/6efe1f119a2332484e690b4c128c4bc5fd4d689b/.specify/memory/constitution.md)
is version 1.13.0. Lean Model has blob
`dc88ba5f9411173cfa655deab7e94ae5569dc395` (`lean/Singular/Model.lean`),
Statements has blob `71380017c1b99c43deda9ca3e44c393ed515a182`, and Driver has
blob `3f54cb1f9efd04de5004983cd84acf34dd7fcfd8` at that baseline.

Provider replacement is a representation change. It must preserve
Singular.step, foldBatch, admittedExitStep, admittedTxOfExit, obligations,
spendRefusal and settle, including refusals, token identities, custody,
refund routing, destination datums and required signers. The terminal's
unverified-provider policy is an operator ruling; Lean does not model HTTP,
sessions, witnesses or ledger authentication. Those guarantees are not Lean
theorems. The concrete authenticated trie root remains outside Lean's abstract
FNV root; no byte equality between those two hashes is claimed.

The preservation checks bind existing model-driver scenarios to observed
transactions through the existing conformance translation, including
fold_requires_no_signer, built_transaction_settles,
destination_output_iff_delivers and delivered_datum_is_request_datum.
Imported or dependency code carries the same correspondence obligation.
Reject's provider migration preserves its current gate, refusals and receipts;
the pre-existing admission discrepancy is escalated outside this ticket and
no Lean-correspondence claim for reject is made here.

The requester's reclaim command and recovery of an interrupted fold signed
by another wallet, merged from that recovery work, are on main. Both must
survive this retirement, including owner/window refusals, exactly-once
application and no repeated submission. Reclaim corresponds to the model's
retract admission; client recovery has no Lean counterpart and requires
observed journal evidence.

## Acceptance and visible limits

Acceptance requires every command and its caller to move onto the new
capabilities, while the node read adapter and in-process indexer are removed
in that same runnable replacement. The [plan](plan.md) records the reset
baseline, the required outcomes against the evidence main already carries,
and the completion checks.

Recorded preprod reads and development-network responses exercise Koios-shaped
decoding, history and submission paths. Local evaluation and time conversion
must match independently captured node answers for identical transaction
bytes, inputs, parameters, genesis and era history. Recording reads is allowed;
no transaction is sent to a public network and no key or secret is accessed
during this delivery.

The exact implementation head must pass `nix develop --quiet -c just ci` and
the development-network journey in CI, with the required controlled faults
observed red and preserved. Every product assertion is described in the public
suite's requirement language, its state computed from receipts. Missing rows
remain visible; harness evidence belongs in its marked appendix.

The live Koios client, retries, Blockfrost, a node instance, ledger verification,
the parked persistent local index and registry reconstruction from history are
outside this ticket. Generic history delivery, TrieState's current-mirror and
pure instances, and exercising the current replay boundary are inside it.
Separate actor directories and reconstruction
without the existing mirror remain the history-reconstruction ticket's work.
The [decisions](decisions.md) record the epic owner's answers. The existing
reject admission discrepancy remains unresolved outside this migration;
its affected semantic guarantee is not counted as a pass.
