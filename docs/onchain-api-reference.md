# Validator API reference

A contributor changing a registry validator — a refusal in the fold, the
custody spend, a shared type — wants to click a module and land on its
real interface: every public function, type and constant with the
documentation its source carries, and a link to the lines that define it,
for exactly the validators this repository ships. This page is the entry
point of that reference: the pages the pinned `aiken docs` generates from
the `onchain/` Aiken project, rebuilt with the documentation site from the
same source tree.

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
- <a href="../onchain/validators/registry/genesis.ak" data-api="module">registry/genesis</a> — minting a registry's state token
- <a href="../onchain/validators/registry/modify.ak" data-api="module">registry/modify</a> — the `Modify` decision and the order of its checks
- <a href="../onchain/validators/registry/fold.ak" data-api="module">registry/fold</a> — the per-input step over the transaction's requests
- <a href="../onchain/validators/registry/trie.ak" data-api="module">registry/trie</a> — the refusals read off the trie itself
- <a href="../onchain/validators/registry/duty.ak" data-api="module">registry/duty</a> — what an admitted request still owes the transaction
- <a href="../onchain/validators/registry/discharge.ak" data-api="module">registry/discharge</a> — checking each duty against the transaction
- <a href="../onchain/validators/registry/settlement.ak" data-api="module">registry/settlement</a> — settling the lovelace a fold owes its payees
- <a href="../onchain/validators/registry/custody.ak" data-api="module">registry/custody</a> — the cage's custody of absent tokens
- <a href="../onchain/validators/registry/refusal.ak" data-api="module">registry/refusal</a> — how a refusal is reported, and the shared reasons

The shared vocabulary and the other validators:

- <a href="../onchain/validators/lib.ak" data-api="module">lib</a> — the edge table, the approval name and the named refusal reasons
- <a href="../onchain/validators/types.ak" data-api="module">types</a> — the datum, redeemer and request types
- <a href="../onchain/validators/shared.ak" data-api="module">shared</a> — reading state from inputs and the phase windows
- <a href="../onchain/validators/request.ak" data-api="module">request</a> — the request validator and its retraction refusal
- <a href="../onchain/validators/witness.ak" data-api="module">witness</a> — the witness validator and its pinned state hash
- <a href="../onchain/validators/cage.ak" data-api="module">cage</a> — the phase predicates the property tests use

Test support, documented because it is public to the test modules:

- <a href="../onchain/validators/cage_fixtures.ak" data-api="module">cage_fixtures</a>
- <a href="../onchain/validators/registry_fixtures.ak" data-api="module">registry_fixtures</a>

## What it leaves out

A module gets a page when it declares a public definition. Test and
property modules are not documented, and three modules declare nothing
public — the `open` approval policy, the `staking` validator and the
`cage_vectors` table — so their sources are their reference. The naming
application's validators under `naming-onchain/` are a separate Aiken
project and have no generated reference on this site. Members that belong
to Aiken's standard library link to its own published documentation.

The documentation check fails when this list and the generated extent
disagree in either direction, when a generated page or the source it was
generated from no longer matches the digest recorded at build time, and
when a source link names another repository or revision.
