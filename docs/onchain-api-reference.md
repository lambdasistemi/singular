# Validator API reference

A contributor changing a registry validator — a refusal in the fold, the
request exit, a shared type — wants to click a module and land on its
real interface: every public function, type and constant with the
documentation its source carries, and a link to the lines that define it,
for exactly the validators this repository ships. This page is the entry
point of that reference: the pages the pinned `aiken docs` generates from
the `onchain/` Aiken project, rebuilt with the documentation site from the
same source tree.

## Encoded requests and supported operations

The permanent first-milestone contract accepts `insertActive` (registration)
and `updateTerminal` (permanent termination). The shared request datum and
redeemer types still encode all seven edges. Encoding an action does not make
it supported: `witnessTerminal`, `insertAbsent`, `updateActive`, `deleteAbsent`
and `deleteActive` are rejected by the permanent state validator, including
independently constructed requests and an excluded member of a mixed batch.

The canonical `state`, `witness`, `registry/admission`, `registry/modify`
and `registry/fold` modules implement this one active contract. The earlier
broader implementations and success evidence are archived on
`preserve/m2/pre-m1-source-removal`; they are not current permanent contract support.
The witness policy checks state-validator co-presence, so transaction admission
also requires the state validator. The witness policy admits the active kind
only.
The [candidate evidence](../specs/505-permanent-m1/RESULTS.md) records compiled
refusal controls and their setup, reachability and live-comparison limits.

## What this reference contains

Every module listed below has a generated page; the reference's own
<a href="../onchain/" data-api="index">index</a> links them all and
carries a search over their members. On this site each link opens the
generated page; read from the repository, it opens the source file at the
revision you are viewing. Inside a generated page, each member's "view
source" link opens the lines it documents at the commit the site was built
from.

The state validator and its owners — how each rule is divided and which
way the dependencies run is on the
[state validator owners page](onchain-validator-owners.md):

- <a href="../onchain/validators/state.ak" data-api="module">state</a> — the validator's dispatch and the one refusal reason the suite asks for
- <a href="../onchain/lib/registry/genesis.ak" data-api="module">registry/genesis</a> — minting a registry's state token
- <a href="../onchain/lib/registry/modify.ak" data-api="module">registry/modify</a> — the `Modify` decision and the order of its checks
- <a href="../onchain/lib/registry/fold.ak" data-api="module">registry/fold</a> — the per-input step over the transaction's requests
- <a href="../onchain/lib/registry/trie.ak" data-api="module">registry/trie</a> — the refusals read off the trie itself
- <a href="../onchain/lib/registry/duty.ak" data-api="module">registry/duty</a> — what an admitted request still owes the transaction
- <a href="../onchain/lib/registry/discharge.ak" data-api="module">registry/discharge</a> — checking each duty against the transaction
- <a href="../onchain/lib/registry/settlement.ak" data-api="module">registry/settlement</a> — settling the lovelace a fold owes its payees
- <a href="../onchain/lib/registry/refusal.ak" data-api="module">registry/refusal</a> — how a refusal is reported, and the shared reasons

The fixed admission boundary:

- <a href="../onchain/lib/registry/admission.ak" data-api="module">registry/admission</a> — refusing excluded and malformed request actions before approval

The shared vocabulary and the other validators:

- <a href="../onchain/lib/lib.ak" data-api="module">lib</a> — the edge table, the approval name and the named refusal reasons
- <a href="../onchain/lib/types.ak" data-api="module">types</a> — the datum, redeemer and request types
- <a href="../onchain/lib/shared.ak" data-api="module">shared</a> — reading state from inputs and the phase windows
- <a href="../onchain/validators/request.ak" data-api="module">request</a> — the request validator and its retraction refusal
- <a href="../onchain/lib/registry_pin.ak" data-api="module">registry_pin</a> — the pinned state hash shared by the witness and the open-datum application
- <a href="../onchain/validators/cage.ak" data-api="module">cage</a> — the phase predicates the property tests use

The Singular state validator of the new line, beside the current one:

- <a href="../onchain/lib/singular_state/fold.ak" data-api="module">singular_state/fold</a> — folding registrations into a registry state: one function per guard of the fold, and their conjunction
- <a href="../onchain/lib/singular_state/genesis.ak" data-api="module">singular_state/genesis</a> — creating a registry state: one function per genesis guard, and their conjunction
- <a href="../onchain/lib/singular_state/preimage.ak" data-api="module">singular_state/preimage</a> — the structured values hashed into token names, and the name of the state token, of a registered key's token, of a configuration record's token and of a registration approval
- <a href="../onchain/lib/singular_state/state.ak" data-api="module">singular_state/state</a> — the root-only state datum, recognising a state from its seed, and comparing the whole mint of a policy

Test support, documented because it is public to the test modules:

- <a href="../onchain/validators/cage_fixtures.ak" data-api="module">cage_fixtures</a>
- <a href="../onchain/lib/registry_fixtures.ak" data-api="module">registry_fixtures</a>
- <a href="../onchain/validators/singular_state_fixtures.ak" data-api="module">singular_state_fixtures</a>
- <a href="../onchain/validators/singular_state_fold_fixtures.ak" data-api="module">singular_state_fold_fixtures</a>
- <a href="../onchain/validators/singular_state_termination_fixtures.ak" data-api="module">singular_state_termination_fixtures</a>
- <a href="../onchain/validators/singular_state_proof_builder.ak" data-api="module">singular_state_proof_builder</a>
- <a href="../onchain/validators/singular_state_history.ak" data-api="module">singular_state_history</a>

## What it leaves out

A module gets a page when it declares a public definition. Test and
property modules are not documented, and four modules declare nothing
public — the `open` approval policy, the `witness` and `staking`
validators and the `cage_vectors` table — so their sources are their reference.
The open-datum application's validators under `applications/open-datum/onchain/`
are a separate Aiken project and have no generated reference on this site.
The naming application's validators under `naming-onchain/` are a separate Aiken
project and have no generated reference on this site. Members that belong
to Aiken's standard library link to its own published documentation.

The documentation check fails when this list and the generated extent
disagree in either direction, when a generated page or the source it was
generated from no longer matches the digest recorded at build time, and
when a source link names another repository or revision.
