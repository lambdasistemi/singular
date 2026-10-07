# Finish registry commands without a node connection

As a registry user, I want every command to use the same hosted-provider
capabilities, without a node, socket or local chain follower. This plan delivers
[#383](https://github.com/lambdasistemi/singular/issues/383); [tasks](tasks.md)
name the remaining work and its completion evidence.

## Status and baseline

The operator reset this ticket to main on October 7, 2026, at
`6efe1f119a2332484e690b4c128c4bc5fd4d689b`. The prior candidate is preserved as
`backup/e371-383-before-reset-20261007`, with uncommitted work preserved in Git
stash `f85a848e0dc7902538795893033154127fb090bf`. It is reference material,
not an accepted implementation or a patch to apply wholesale.

Main already contains the generic provider and evidence types, Koios adapter,
local evaluation and pinned time fixtures, pure provider and trie tests,
command composition, and private devnet facade. Their presence is not a fresh
passing test result. Main still contains the obsolete node-internal component.
The remaining delivery is its complete removal with migrated consumers and a
passing packaged journey on the resulting commit.

The existing orchestrator supervises three implementation workers: Sol owns
Haskell migration; Muse owns the devnet journey and executable checks; GLM owns
required docs and packaging descriptions. The operator requested no independent
audit. The orchestrator owns integration, final tests, PR and completion.

## Required outcomes and current evidence

| Ticket requirement | Present on main | Remaining task |
| --- | --- | --- |
| Every command uses generic interfaces; old node reads/indexer removed | CLI capability composition exists; old component remains | Remove obsolete modules and migrate every retained consumer and component dependency. |
| Koios recorded responses serve reads, history and submission | Adapter, fixtures and private facade exist | Run required fixture paths and the complete devnet journey; repair migration failures. |
| Local evaluation and pinned time match independent node fixtures | Comparison tests exist | Preserve them and rerun on the candidate. |
| Pure composed reads, history and submission | State-based tests exist | Preserve and rerun, without introducing IO into interface types. |
| Only unverified facts, no witness decoder | NoWitness/unverified and receipt assertions exist | Preserve all-fact assertions and verify inspect and command receipt behavior. |
| Every trie consumer uses TrieState, including pure proof paths | Interface, consumers and pure tests exist | Preserve current behavior and tests; do not rebuild #381's backend. |
| Spec, plan and decisions with stamped speech | Existing pages contain stale status | Reconcile these pages and their companions with this delivery. |
| Full checks and devnet journey green on PR head | No evidence for the reset candidate | Run required checks and fix failures before completion. |

## Implementation boundaries

Keep the current `LedgerProvider w m`, `Session w m`, `Verifier w m` and
`TrieState m` contract. Confirmation remains the common bounded polling service
specified by the ticket. Provider-owned waiting, new API publication surfaces,
new verification systems, public-network transactions and changes to other
tickets' acceptance are outside this reset.

Sol owns `offchain/` and `conformance/` source, tests and component declarations.
Move retained generic operations to their current non-node owners; delete
obsolete node reads, in-memory indexing and their exclusive test machinery.
The private devnet facade may connect to a node as test infrastructure; the
shipping terminal may not. Preserve tracing introduced on main, recovery,
request-carried destination datums, exact-output confirmation and signed-only
submission. Do not restore old main behavior from the saved candidate.

Muse owns journey/check scripts in `tools/` and the relevant CI workflow wiring.
Use the actual private ledger facade, never terminal receipts as its source.
Retain tests for all required calls, named failures and every receipt fact's
Unverified verdict. Adapt controls to removed components without removing the
behavior they protect. Coordinate build and journey execution with Sol.

GLM owns existing documentation, speech companions and documentation packaging
references. Remove references to retired production components and make the
existing API reference follow the actual component inventory. Do not broaden
this ticket into a documentation redesign. Preserve historical decisions with
explicit current applicability; superseded status is not current evidence.

```mermaid
flowchart LR
  Main[Current main] -->|Migrate retained consumers| Code[Provider-only candidate]
  Code -->|Run fixtures and packaged commands| Check[Required checks]
  Check -->|Observe real devnet journey| Ship[Ready to merge]
```

## Model and acceptance

Behavioral authority is constitution 1.13.0 and the Lean files at the baseline:
Model blob `dc88ba5f9411173cfa655deab7e94ae5569dc395`, Statements blob
`71380017c1b99c43deda9ca3e44c393ed515a182`, Driver blob
`3f54cb1f9efd04de5004983cd84acf34dd7fcfd8`. This is a representation migration:
no changes to admission, folding, custody, refunds, signers or datum delivery.
Lean does not model HTTP, sessions or verification policy. Preserve existing
conformance mappings and visible limits; escalate a concrete model conflict.

Completion requires `nix develop --quiet -c just ci`, the pure/recorded provider,
trie and local-service tests, and the existing devnet journey jobs green on the
final PR head. Record command, exit and commit; a build failure is not a
behavioral failure or successful proof. The orchestrator updates task boxes
only from execution evidence and closes #383 only after merge.
