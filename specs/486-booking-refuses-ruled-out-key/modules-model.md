# Modules: where the key is read

Issue 486. Follows [the plan](plan.md).

| Module | Responsibility after this change |
| --- | --- |
| Open datum registration command (`Registration`) | the booking step reads the selected key's state before it builds the booking, and refuses an active or terminated key |
| Open datum key reader (`Reader`) | unchanged: the answer for a key, through the ledger provider session |
| Open datum request refusals (`Requests.Refusal`) | two named refusals, for an active key and for a terminated key, with their wording |
| Registration journey and refusal scripts under `tools` | assert the refusal at the booking; book before the registration where a script needs a request the fold must refuse |
| Conformance rows and the evidence page | a new row states the early refusal beside the retained row |

## Dependency direction

The command layer already depends on the reader's session type and the refusal type; it gains no new dependency and no new chain
read path. The library, the fold, the validators and the model are not touched.
