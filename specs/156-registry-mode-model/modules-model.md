# #156 — modules model

Responsibility and dependency direction only. No bodies, no algorithms.

## Dependency direction

```
Singular.Model          the alphabet, the edges, the fold, the codec
  ├── Singular.Lemmas         supporting lemmas over Model
  ├── Singular.Statements     the registry's promises: P1, L1, S1–S3, O1, T1, W1–W4
  │     └── Singular.Audit          compiled axiom gate over Statements
  ├── Singular.OpenApp        the open application, the smallest instance
  └── Singular.Naming*        naming as the second instance
        └── Singular.Naming*Audit   compiled axiom gates over the naming statements
```

Nothing above depends on anything below it. No naming identifier appears in
`Model`, `Lemmas` or `Statements`: the registry's guarantees are unconditional in
the application, which is what makes the open application a proof of that fact
rather than a restatement of it.

## Changed responsibilities

| module | responsibility after this ticket |
|---|---|
| `Singular.Model` | Owns `Leaf`, `State`, the seven edges, the token kinds, the delta, the eight-field configuration, admission, routing, the leaf codec, and the fold. Loses `Value`, `incarnation`, `assetScope`, `reuseIdentity`, `consumerPin` and the free-form `update`. |
| `Singular.Statements` | Owns the eleven registry promises and the edge inversions. Gains the W-laws, which are new obligations, not renamed ones. |
| `Singular.OpenApp` | **New.** The policy that certifies everything, and the instantiation of every registry promise at it. It is the smallest instance and carries no naming vocabulary. |
| `Singular.Naming*` | Naming becomes an *instance* of the registry rather than a parallel model: its record UTxO holds the active token, its moves that do not touch the trie are stated as not touching it, and its existing statements are re-stated over the new alphabet with preserved meaning and preserved lifecycle identities. |
| `lean/Main.lean`, `NamingMain.lean`, `LifecycleMain.lean` | Corpus generators emit rows from the new model, preserving the row-id prefixes and the exact lifecycle id set that `tools/check_model.py` binds. |

## Promotion

`Singular.OpenApp` is promoted to sit beside the naming layer, not inside it: it
exists to demonstrate that §6 holds for an application that proves nothing, and a
module that imported naming could not demonstrate that.

The leaf codec stays in `Singular.Model` rather than a separate module. It is part
of what a leaf *is*, and #157 and #152 consume it as one contract with the
alphabet.

## Out of this ticket's surface

`simulator/**`, `tools/**`, `onchain/**`, `naming-onchain/**`, `conformance/**`,
`offchain/**`, and every `docs/` page but `theorems.md` and its speech companion.
`tools/check_model.py` is treated as frozen and its assertions are constraints on
this deliverable — see `plan.md` and Q-001.
