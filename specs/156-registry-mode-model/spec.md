# #156 — the registry model in registry mode, and everything bound to it

Authority: the settled interface, gist revision `4a2bd178`, `interface.md`
SHA-256 `deda2321bc2d895e24fd291bb65f9f3901595fa185b121d627791b5ea9607d2a`.
Where this document, the issues, or the current Lean disagree with it, the
interface wins. Constitution: `.specify/memory/constitution.md` v1.0.0.

Base: `1bee7ca1d069737c81d441d1e895beff32392886`.

Scope amended 2026-09-16 by desk ruling **A-001** (inbox `NOTE-001`): #156 is one
atomic-green PR carrying two sequential slices. Bound issue bodies:
#154 `3001eb32…`, #156 `58619675…`, #163 `59ecff0c…` — each verified.

## The story

As the owner of #157, I receive a frozen Lean model whose **definitions are the
interface** — `Leaf`, `State`, seven edges, three token kinds, approval-token
admission — and whose **statements say exactly what the cage guarantees for
every application** and what naming adds for itself, each bound to a
Given/When/Then I can attach a check to.

As the author of an external consumer (#152, cardano-keri), I receive a leaf
codec and an eight-field state datum that are frozen contracts: I can build MPF
proofs and bind to `activePolicy`/`terminalPolicy` without another change here.

As a reviewer who plays the simulation or reads the coverage ledger, I see the
registry-mode model and can replay the corpora that bind those pages to it, with
**no trace of the previous alphabet** (#163).

As anyone who pulls `main`, I never see a commit where the model says one thing
and the simulator, the tooling or the pages say another: the transition is one
atomic change.

## Why it is one PR

A Lean-only change cannot leave `main` green. `simulator/core.mjs` is a
**hand-written transcription** of the Lean model, not a generated artifact, and
`simulator/gate.mjs` asserts the real `lean/` manifests against frozen copies
pinned by digest and denominator in `simulator/identity.json`. Measured on a
clean detached worktree at the base: unmodified, `node simulator/gate.mjs` exits
0; after a `lean/`-only change of the kind this ticket must make, it exits 1 with
`AssertionError: naming theorem identity`. `tools/check_model.py` and three
`docs/` pages are bound the same way. So the model and its consumers land
together.

## What the registry is, in one paragraph

The trie answers two questions and nothing else: is this key known, and where in
its life is it. `Leaf ::= Unknown | Known State` and
`State ::= Absent | Active | Terminal`. Applications store nothing in the leaf;
their data lives in their own UTxOs, authenticated by the active token. Seven
edges move a leaf, each an MPFS primitive applied to a `State`, each a delta over
three token kinds. Six of them are tree changes and need an approval minted under
the pinned application policy; the seventh, `witnessTerminal`, is a read and needs
none. The cage sums the deltas of the edges it folded and refuses any mint that
differs.

## Requirements

### R1 — the alphabet (interface §1)

`Leaf` and `State` are the only leaf vocabulary. `Value`, `incarnation`,
`assetScope` and `reuseIdentity` are **removed, not renamed**. There is no
application value in a leaf and no version counter. `deleteActive` recreates the
key: a deleted key is `Unknown` again and may be inserted again as the same key.

### R2 — the seven edges (interface §2)

| edge | primitive | from → to | delta |
|---|---|---|---|
| `insertAbsent` | `insert Absent` | `Unknown` → `Known Absent` | +1 absent |
| `insertActive` | `insert Active` | `Unknown` → `Known Active` | +1 active |
| `updateActive` | `update Active` | `Known Absent` → `Known Active` | −1 absent, +1 active |
| `updateTerminal` | `update Terminal` | `Known Active` → `Known Terminal` | −1 active |
| `deleteAbsent` | `delete` | `Known Absent` → `Unknown` | −1 absent |
| `deleteActive` | `delete` | `Known Active` → `Unknown` | −1 active |
| `witnessTerminal` | `Read Terminal` | `Known Terminal`, unchanged | +1 terminal |

There is no free-form `update`: the only updates are the two state moves above.

### R3 — the refused combinations

The fold refuses, each with its own distinct reason: `insert Terminal` (nothing is
born terminal); `update Absent` (a booking is not undone into absence); every edge
out of `Terminal`; `deleteTerminal`; a batch of zero requests; and any mint under
the pinned token policies differing from the summed delta.

### R4 — admission (interface §3)

Each of the six tree edges is admitted only if the request carries an approval
token minted under `Config.applicationPolicy`. `witnessTerminal` requires none.
Policing is checked at fold time as the presence of the approval; nothing
application-specific runs at fold time. The pins are immutable across folds.

### R5 — the read (interface §2)

`Read(value)` proves `key → value` against the **fold's root at that action's
position in the batch**, not the batch's initial or final root, and leaves the
leaf unchanged. A fold of only reads is a fold: the empty-fold rule refuses zero
*requests*, not an unchanged *root*. The cage admits `Read Terminal` and refuses
`Read Active` and `Read Absent`, so no attestation of a leaf that can still move
is ever produced.

### R6 — token custody and routing

Absent tokens are routed to the cage's own custody, so any later fold can consume
them without a signature. Active and terminal tokens go to the output the request
names. D-ADA below settles the value when an absent token is consumed.

### R7 — the state configuration

`root, maxFee, processTime, retractTime, applicationPolicy, activePolicy,
absentPolicy, terminalPolicy` — **eight fields**. `consumerPin` is gone;
`representativePolicy` becomes `activePolicy`.

### R8 — the statements

P1, L1, S1, S2, S3, O1, T1 and W1–W4, exactly as the interface states them, each
proved without `sorryAx`, each with a Given/When/Then and one executable model
observation. Rows in `plan.md`.

### R9 — the instances

The **open application** — a policy that certifies everything — is the smallest
instantiation and is proved first; every statement in R8 holds for it. **Naming**
is the second: the record UTxO holds the active token; `maintain` and `recover`
never touch the trie; retirement completion is `updateTerminal`; the approval
policy certifies `insertActive` on the controller's signature and
`updateTerminal` on the quorum's; `deleteActive` is never certified. The existing
naming statements (`over_terminal`, `naming_delete_refused`, `WellFormed`, the
recovery rows) are re-stated over the new model with their meaning preserved.

### R10 — the model-bound tooling and pages (slice A)

`tools/check_model.py` and the corpus generators are **opened to the new
identities**. The discipline stays and is not weakened: every identity matched
exactly, PROVED only from the standard axioms, admitted statements declared
STATED, byte-for-byte corpus regeneration. `docs/theorems.md`,
`docs/model-ledger.md` and `docs/mutants.md` are regenerated or rewritten against
the new model with fresh speech stamps.

### R11 — the simulator and its pages (slice B, #163)

A **separately authored** transcription of the frozen slice-A Lean interface:
the generic profile exposes the seven edges and the read, refuses the illegal
combinations **by name**, and shows the token movement per edge; the naming
profile shows the Over witness minted by a folded read and freely burned.
`docs/simulation.md` describes those journeys and their finite-model limits;
`docs/LEAN-CLARITY.md` records what the new formal artifacts did and did not
communicate to the transcriber. The corpora and browser checks replay against the
new model, and the counts on the front page and in `docs/design.md` are updated
to **what actually replays**. Every changed page's speech is redone and
restamped.

## Decisions this ticket freezes

The three items interface §9 leaves open, each settled with its derivation and
each reported in the handback so the epic owner and the operator can overrule
before #157 consumes it.

### D-CODEC — the three-state leaf codec (frozen sibling contract)

The leaf value is **one byte**: `0x00` Absent, `0x01` Active, `0x02` Terminal.
Every other byte string is not a valid leaf and the cage refuses it.

Derivation: §0 — the value slot is taken away from applications and filled with a
fixed lifecycle vocabulary; a one-byte tag is the smallest total encoding of a
three-element alphabet and admits no application payload by construction. The
ordering follows the lifecycle. Today's leaf bytes are naming's (the
representative name, the `over` marker); those are not valid leaves under this
codec, which is the intended break — §9 requires it fixed before the first
registry whose leaves are promised to survive.

Obligations: `encode`/`decode` total and mutually inverse on valid bytes,
injective, decidable; no byte decodes to two states; a naming-era leaf byte string
does not decode. #157 and #152 consume this verbatim.

### D-ADA — where the absent token's value goes when it is consumed

On `updateActive` and `deleteAbsent`, the value held with the consumed absent
token is paid to **the output the consuming request names** — the same
destination rule already governing the active and terminal tokens.

Derivation: §2 makes the absent token biconditional, created on entry and consumed
by every exit in the fold itself; #154 puts it in cage custody so a later fold
needs no signature. Paying it to the folder would pay the folder twice (tip plus
custody) and distort the fold market; retaining it would accumulate unbounded dust
in cage custody. Routing it to the request's named output keeps one routing
sentence for all three kinds, keeps cage custody equal to exactly the outstanding
absent tokens, and makes `insertAbsent` → `updateActive` value-neutral for the
application that funded it.

### D-SELF — whether the registry refuses `insertAbsent` on its own account

**It does not.** `insertAbsent` is admitted exactly like the other five tree
edges: by an approval under the pinned application policy, and by nothing else.

Derivation: §3 is explicit — "every tree change — the six edges, `insertAbsent`
included — must be certified by the pinned application policy", and "witnessing
absence is a tree change, so the application decides who may do it … with the same
sentence that governs every other edge." A registry-level refusal would contradict
that sentence and would remove the successor-registry and reserved-spellings
instances of §8. The model carries **no** `insertAbsent`-specific refusal.

## Rejection behavior

Every refusal above is observable as a distinct refusal reason, not a silent
no-op, and each has a control that can produce it. In the simulator each is
refused **by name** (R11).

## Observable success

From a clean checkout of the merged result:

```
nix develop --quiet -c just model
nix develop --quiet -c just ci
```

both exit 0; the compiled axiom report carries no `sorryAx`; the four #154
mutants each break their named law; and no page, corpus or simulator profile
mentions `Value = active | over`, an incarnation counter or a consumer pin.

## Non-goals

On-chain code (#157). The runner and release wiring (#158). Upstream MPFS. The
escrow's own model (#152). The registry-interface documentation page (#159,
desk-owned). Any hand edit of a derived page to "match" without re-derivation
(#163). This ticket does not publish or tag a release and makes no on-chain or
runner conformance claim.
