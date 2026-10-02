# Name a batch question

As a driver user, I want a batch question to state exactly what is asked and what the answer may contain.

## Questions

| Data | Contract |
|---|---|
| BATCH-FOLD question | setup trace, starting state, an ordered list of requests, each folded on its own edge; theorem binding as for a single scenario. |
| BATCH-REJECT question | setup trace, starting state, an ordered non-empty list of requests, each with its exit; optional observed outputs. |
| BATCH-FOLD answer | `accepted`, `refused` or `unsupported`. Accepted carries `config`, `custody`, `held`, `leaf` keyed by every distinct request key, `mint`, `paid`, `root`, `state`; never `tx`. |
| BATCH-REJECT answer | `accepted` with the unchanged state and an empty mint, plus a settle judgement when outputs are given; `unsupported` for an empty, retract, fold or mixed batch. |

## Invariants

The surface declares each question with its own observation extent; the single-request extent is unchanged. A refusal reason is one the model can already produce. The setup premise is checked before any accepted observation.
