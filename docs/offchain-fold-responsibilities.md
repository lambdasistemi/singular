# Who owns a registry fold

A contributor changing how the registry folds pending requests — which
UTxO it spends, what an edge owes, how the transaction is assembled —
wants to change one module and have the review ask one question. Before
the extraction, all of that lived in one 890-line module; a change to a
custody refund and a change to a slot computation were reviewed in the
same file with no boundary between them. Now the fold path is three
focused owners behind the same public facade, and this page tells a
contributor which owner their change belongs to, what the flow through
them is, and what must never change while it moves.

## The story this serves

As a registry caller, I submit requests and fold them through the
existing `Singular.Registry.TxBuilder.Update` import; I want the same
request order, the same token effects, the same custody refunds and the
same destinations as before, so my callers and my conformance rows see
nothing move. A contributor refactoring the fold's internals owes me
that, and the focused suite now pins it: the order in which duties
accumulate, the quantities minted, and — because the model proves no
fold requires a signer — both the duties' empty signer list and the
empty required-signer set of the transaction the public entry actually
builds.

## One owner per fold concern

```mermaid
flowchart TD
    Callers[Callers — tests, commands, journeys, conformance] -->|import the six public names| U[Singular.Registry.TxBuilder.Update — facade and orchestration]
    U -->|queries, proofs, state, slot, context completion| C[Update.Context]
    U -->|what the requests owe| D[Update.Duties]
    U -->|evaluation adapter and the one DSL program| B[Update.Build]
    D -->|reads the context a caller hands in| C
    B -->|reads the duties the fold decided| D
    C -->|identity, lookup, edges| I[TxBuilder.Internal owners]
    B -->|attached action types| CF[TxBuilder.ConnectedFold]
```

The facade holds no algorithm. It runs the fold's sequence — query,
proofs, state preparation, context completion, duties, upper slot,
program, build — and every decision in that sequence belongs to exactly
one of the three owners below it. The graph is acyclic and one-way:
Context knows nothing of duties or assembly, Duties reads Context but
no assembly, Build reads Duties but no facade.

| Module | Responsible for |
| --- | --- |
| `Singular.Registry.TxBuilder.Update` | The six public exports and the two fold entry points; the sequence of preparation, decision and assembly. Nothing else. |
| `Singular.Registry.TxBuilder.Update.Context` | The `RegistryContext` a caller hands in and its empty value; finding the state, request and fee UTxOs; the ordered speculative proofs through the trie; the new state output and the cage script; the validity upper slot; completing a partly empty context from the provider. |
| `Singular.Registry.TxBuilder.Update.Duties` | `RegistryDuties` and `registryDuties`: the one derivation of what a fold's requests owe — mints under the three token policies, destinations, custody spends, burn sources, deposit and approval returns, and the (empty) signer set. |
| `Singular.Registry.TxBuilder.Update.Build` | `NoCtx`, the evaluation adapter over the provider, and the one transaction DSL program: spends, mints, outputs, signatures, attached or referenced scripts, collateral and validity. |

## The flow a fold runs

```mermaid
sequenceDiagram
    participant Caller
    participant Facade as Update facade
    participant Ctx as Update.Context
    participant Dut as Update.Duties
    participant Bld as Update.Build
    Caller->>Facade: updateTokenWithDuties cfg prov tm tid addr ctx
    Facade->>Ctx: queryContext — state, requests (sorted by input), fee, params
    Facade->>Ctx: computeProofs — speculative trie walk in request order
    Facade->>Ctx: prepareState — new state output, cage script
    Facade->>Ctx: completeContext — cage/holder inventories, cage script default
    Facade->>Dut: registryDuties — what these requests owe
    Facade->>Ctx: computeUpperSlot — earliest request deadline
    Facade->>Bld: mkEvalTx + buildProgram — the one DSL program
    Bld-->>Facade: assembled transaction
    Facade-->>Caller: the built ConwayTx
```

## What must not change

The extraction is a representation change, not a new registry rule.
The Lean model remains the authority: the fold's mint quantities, owner
deposits, custody refunds and approval returns are what
`Singular.obligations` says they are, and no fold requires a signer
(`Singular.Statements.fold_requires_no_signer`). The focused suite pins
the order duties accumulate in (requests are folded in input order, and
their mints, outputs and burn sources list in that order, not sorted),
the exact holder selection for a burn, the per-owner grouping of deposit
returns, and the built body's empty required-signer set through the
public entry. A contributor who needs one of those to change is not
refactoring; that is a behavior change and belongs to the design flow,
not to this structure.

## Independent evidence boundaries

Two neighbors deliberately do NOT share this code. The cage computes
its own duties from the requests it consumes (`dutiesOf`, `dutyOk`); a
builder that agreed with the validator by construction would not catch
a disagreement, so `registryDuties` stays a separate derivation. And
the Conformance suite's state is computed from run receipts — its rows
say what the chain did, not what this builder intended, and this
extraction touches none of it.

## Where common changes land

- A request gains or changes what it carries: `Update.Context` finds
  and decodes it (the datum shape itself lives in
  `Singular.Registry.Types`).
- An edge's obligations change — what it mints, where it delivers, what
  custody it spends or returns: `Update.Duties`, and only there.
- The transaction's shape changes — a new input kind, reference
  scripts, collateral or validity rules: `Update.Build`.
- What an omitted context field defaults to, or which queries the fold
  runs: `Update.Context`.
- The public surface and the fold's sequence: the facade, which must
  stay a coordinator.

## Decisions this extraction recorded

| Decision | Chosen | Considered and not taken |
| --- | --- | --- |
| How to split the fold | Three owners matching preparation, decision and assembly, behind the unchanged facade. | Finer owners per edge or per policy: more indirection, same guarantee. |
| How callers keep working | The facade re-exports its six names byte-for-byte; children are implementation modules of the same library. | Rewriting callers to the children: churn across tests, commands and conformance with no behavioral benefit. |
| Where the context completion lives | `Update.Context`, as `completeContext`, moved verbatim from the facade's inline block — queries are preparation, and the facade only sequences them. | Leaving the queries in the facade: the owner graph would say Context owns queries while the facade ran them. |
| The pre-existing `ConnectedFold` copies | Left untouched: it is the permissionless journey fold with its own documented lineage, not a copy of the registry fold's owners. | Unifying them: a different ticket's design question — the two builders serve different flows with different rules. |

## Source

The facade and owners, linked on this site to the generated API
reference and readable in the repository at the revision you are
viewing:

- Facade: <a href="../offchain/lib/Singular/Registry/TxBuilder/Update.hs" data-api="module">Singular.Registry.TxBuilder.Update</a>
- Owners: <a href="../offchain/lib/Singular/Registry/TxBuilder/Update/Context.hs" data-api="module">Singular.Registry.TxBuilder.Update.Context</a>, <a href="../offchain/lib/Singular/Registry/TxBuilder/Update/Duties.hs" data-api="module">Singular.Registry.TxBuilder.Update.Duties</a>, <a href="../offchain/lib/Singular/Registry/TxBuilder/Update/Build.hs" data-api="module">Singular.Registry.TxBuilder.Update.Build</a>

The wider builder map these owners sit in is
[Builder and blueprint modules](offchain-builder-blueprint.md); the
check commands and their extents are in
[Checking off-chain code](offchain-development.md).
