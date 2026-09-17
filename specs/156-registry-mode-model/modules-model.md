# #156 — modules model

Responsibility and dependency direction only. No bodies, no algorithms.

## Dependency direction

```
Singular.Model                  the alphabet, the edges, the fold, the codec
  ├── Singular.Lemmas                 supporting lemmas over Model
  ├── Singular.Statements             P1, L1, S1–S3, O1, T1, W1–W4
  │     └── Singular.Audit                 compiled axiom gate over Statements
  ├── Singular.OpenApp                the open application, the smallest instance
  └── Singular.Naming*                naming as the second instance
        └── Singular.Naming*Audit          compiled axiom gates over naming statements

lean/*.json corpora  ←  lean/{Main,NamingMain,LifecycleMain}.lean   (generated)
tools/check_model.py ←  reads the sources and the generated corpora   (slice A)
docs/{theorems,model-ledger,mutants}.md                              (slice A)

simulator/**                     a transcription of the FROZEN slice-A interface
docs/{simulation,LEAN-CLARITY}.md, design counts, front-page counts   (slice B)
```

Nothing above depends on anything below it. **No naming identifier appears in
`Model`, `Lemmas` or `Statements`**: the registry's guarantees are unconditional
in the application, which is what makes the open application a proof of that fact
rather than a restatement of it.

The slice-B arrow points **into** the frozen slice-A interface and never back out.
The simulator reads the Lean; the Lean never accommodates the simulator.

## Changed responsibilities

| module | responsibility after this ticket | slice |
|---|---|---|
| `Singular.Model` | Owns `Leaf`, `State`, the seven edges, the token kinds, the delta, the eight-field configuration, admission, routing, the leaf codec, and the fold. Loses `Value`, `incarnation`, `assetScope`, `reuseIdentity`, `consumerPin` and the free-form `update`. | A |
| `Singular.Statements` | Owns the eleven registry promises and the edge inversions. The W-laws are new obligations, not renamed ones. | A |
| `Singular.OpenApp` | **New.** The policy that certifies everything, and the instantiation of every registry promise at it. Carries no naming vocabulary. | A |
| `Singular.Naming*` | Naming becomes an *instance* of the registry rather than a parallel model: its record UTxO holds the active token, the moves that do not touch the trie are stated as not touching it, and its existing statements are re-stated over the new alphabet with preserved meaning. | A |
| `lean/{Main,NamingMain,LifecycleMain}.lean` | Corpus generators emit rows from the new model. | A |
| `tools/check_model.py` | **Opened to the new identities, discipline retained.** It still owns: exact identity matching against the manifests, PROVED only from the standard axioms, STATED for admitted declarations, byte-for-byte corpus regeneration, and the keyword/proof-hole audit over `lean/`. It does not own the old identity lists. | A |
| `docs/theorems.md` | The declaration inventory and correspondence for the new statements. | A |
| `docs/model-ledger.md` | The requirement-to-behaviour map for the new model, with the previous ledger's rows retired or carried explicitly. | A |
| `docs/mutants.md` | The mutation ledger for the new model, including the four the interface names, each with the law it must break. | A |
| `simulator/**` | A separately authored transcription of the frozen slice-A interface: both profiles, the seven edges, the read, named refusals, corpus replay. | B |
| `docs/simulation.md`, `docs/LEAN-CLARITY.md` | The journeys and their finite-model limits; what the formal artifacts did and did not communicate to the transcriber. | B |
| front page, `docs/design.md` | Counts equal to what actually replays. | B |

## Promotion

`Singular.OpenApp` sits beside the naming layer, not inside it: it exists to
demonstrate that §6 holds for an application that proves nothing, and a module
that imported naming could not demonstrate that.

The leaf codec stays in `Singular.Model` rather than a separate module. It is part
of what a leaf *is*, and #157 and #152 consume it as one contract with the
alphabet.

## Out of this ticket's surface

`onchain/**`, `naming-onchain/**`, `conformance/**`, `offchain/**`, the #158
runner and release wiring, upstream MPFS, `consumer.ak`, cardano-keri, #152, and
#159's registry-interface page. Every `docs/` page not named above. Touching any
of them is a Q to the epic owner, not a repair.
