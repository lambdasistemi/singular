# The registry's promises run against the Lean model

Authority: the operator's 2026-09-22 instructions to set these ticket specs,
drive Opus and Grok workers, and use Muse or GLM for mechanical parts.

**#209 is a parent epic with six child tickets, each with its own pull
request**: #220 the executable book DSL and its resource lifetime (PR 217),
#221 the generic Lean model driver (PR 226), then #222 registration observation
comparison, #223 connected retirement and refusals, #224 batch and shared E2E
contexts, and #225 theorem consumers, receipts and the book.

**PR 226 delivers #221 and nothing else.** It carries this epic plan for
context so a reader can see where the driver sits, and it neither authorizes
nor implements #220 or #222-#225; each of those is its own ticket, its own
fence and its own pull request.

This authorizes the model, constitution and CI integration required by the
accepted work plan, superseding the earlier conformance-only fence for these
named tasks. It does not authorize changes to registry semantics, unrelated
edges, external deployments or merge.

## User stories

- A consumer reads a registration promise and can run its example against a
  real registry, seeing the complete declared observations compared with Lean.
- A holder retires a registration created in the same run; both transitions
  agree with Lean, and refusal examples agree on whether the request succeeds.
- An integrator can substitute the execution context without rewriting the
  story or its expectations. Concrete identities remain in the interpreter.
- A reader can see which theorem conclusions were exercised, which remain
  unobservable, and which have no executable consumer yet.

## Requirements and blocking invariants

All invariants below are BLOCKING for their assigned child ticket. Incomplete
later children remain visible and cannot be claimed by an earlier child's green
gate, and a merged child's pull request closes only its own ticket.

| ID | Required behavior | Failure that must be detected |
|---|---|---|
| R01 | One model-owned driver exposes the executable law and declared boundary observations with bound identities. | A per-theorem projection substitutes for the declared boundary. |
| R02 | Model-owned scenarios carry theorem bindings, parameters and lawful setup traces where required. | Code-side invented expectations, unexercised hypotheses or a seeded final state stand in for a connected run. |
| R03 | Acceptance and domain refusal are distinguished from parse, process and infrastructure errors. | A broken runner earns refusal evidence or an unexecuted law earns acceptance. |
| R04 | The constitution states the concrete realization of each law/observation, identity rules and named unobservable fields. | A support module silently invents the correspondence or excludes a required field. |
| R05 | One Haskell abstraction compares all declared observable fields, with field-level differences. | A wrong signer, refund, output, datum, asset, configuration or state change is ignored. |
| R06 | Identities are allocated during context/actions and looked up during observation. | An unknown observed identity is assigned the expected model ID. |
| R07 | Registration and retirement share actual history and identity maps; context is supplied outside the story. | Retirement burns a substitute token or restarts from a constructed active state. |
| R08 | Product claims use the typed theorem/clause DSL with total execution and rendering. | A discovered instruction or nested program executes but disappears from the book. |
| R09 | Refusal replay fails when model and implementation disagree. | An accepted mutant passes or a client/setup error is represented as ledger rejection. |
| R10 | Each project theorem has executable consumers or a named unmet requirement. | A pointer, proof-only classification, stale receipt or skipped run earns executable coverage. |
| R11 | E2E reuses the scenario/translation/comparison logic with its supplied context. | Duplicated expectations drift between conformance and E2E. |
| R12 | CI runs the suite and produces a readable, receipt-derived book with visible gaps. | Local-only execution or a passing inventory is advertised as product conformance. |

No new Cardano byte model in Lean. The existing abstract root encoding is not
the concrete trie hash; translation must state and check their relationship.
No weakening statements, changing hypotheses or promoting uncovered rows to
hide a gap. A model ambiguity requires a concrete user story and operator ruling.

## Required controls

Demonstrate comparator failure for changed observations, translation failure for
unallocated identities, and refusal-replay failure for an accepted mutant.
Retain real connected success evidence and detect missing/skipped consumers and
stale bindings. Controls must reach their claimed boundary, not merely exit 1.

## Limits

This epic builds the machinery and migrates implemented behavior across its
six children. No child may claim unimplemented edges work. The every-theorem consumer requirement remains
unmet until the complete inventory has evidence; missing cases stay explicit.
BDD library selection and general resource abstractions are deferred. Existing
authentication/publication gaps (#210/#218) require explicit task accounting.
