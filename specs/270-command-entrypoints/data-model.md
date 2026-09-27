# Command data boundaries

As a maintainer, I need moved records to keep the same serialized and ledger-facing representation while their owners change.

## Boundaries

| ID | Data boundary | Invariant |
| --- | --- | --- |
| D270-J | Journey script identity, validator pins, compiled script inputs, MPF proofs and chain state | Pinned unapplied identities and derived applied hashes remain distinct; readback and negative controls use their own observed values. |
| D270-I | Insert-active key, destination, boot state, active token and observation | The output JSON and wallet token census are computed from the executed scenario, not copied from builder intent. |
| D270-U | Update-terminal key, holder source, before/active/terminal roots, burn and observation | The retired key and consumed holder token match; observation records the actual three phases and refusal controls. |
| D270-D | Deployment compiled halves, manifest, node references and count inputs | Existing record bytes and public library values remain unchanged; command-local options retain their current precedence. |

No schema or wire migration is authorized. Existing types and instances move together if their owner changes. The accepted Lean tree governs registry state and transaction effects; command-specific serialization and narration require separate execution evidence.
