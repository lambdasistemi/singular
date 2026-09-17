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

### R3 — the refused combinations, as the complement of R2

**Every `(primitive, value, before-leaf)` triple that is not a row of the R2
table is refused.** R3 is not a list; it is the complement, and the model states
it that way so that a triple nobody thought of is refused by construction rather
than by omission.

The named reasons the refusals carry, which is what a caller and the gate
observe:

| refused | why |
|---|---|
| `insert Terminal` | nothing is born terminal |
| `update Absent` | a booking is not undone into absence; it is deleted and witnessed again |
| `update Terminal` on `Known Absent` | nothing is terminated that was never booked |
| `update Active` on `Known Active` | already booked; there is no free-form update |
| any `insert` on a `Known` leaf | the key exists |
| `delete` on `Unknown` | there is nothing to delete |
| any edge out of `Known Terminal` | terminal admits none; `deleteTerminal` is one case of this fact, not a second fact |
| `Read Active`, `Read Absent` | only a leaf that can no longer move may be attested (R5, and the structural guard S1 rests on) |
| a batch of zero requests | the empty-fold rule refuses zero *requests* |
| a mint differing from the summed delta | the cage's delta is read off the edges it folded |

Distinct reasons are required where the distinction is **observable**. Two
refusals of one underlying fact — `deleteTerminal` and "any edge out of
`Terminal`" — are not required to carry two reasons.

### R4 — admission (interface §3)

Each of the six tree edges is admitted only if the request carries an approval
token minted under `Config.applicationPolicy`. `witnessTerminal` requires none.
Policing is checked at fold time as the presence of the approval; nothing
application-specific runs at fold time. The pins are immutable across folds.

**D-APPROVAL — what one approval certifies** (#157's frozen contract, carried
here so the Lean model and the cage agree). An approval is scoped by the tuple
`(edge, key, owner, destination)`; its asset name is
`blake2b_256(edge ‖ key ‖ owner ‖ destination)`; and it is **not burned at the
fold**. So an approval minted under the pinned policy but naming a different
edge, key, owner or destination does **not** admit this request: right policy is
necessary and not sufficient.

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
names. **R-ADA** below settles where the absent token's value goes when it is
consumed: to the refund address the `insertAbsent` request named, recorded in the
custody datum beside the token.

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
policy follows **R-NM4** for all six edges. The existing naming statements
(`naming_delete_refused`, `WellFormed`, the recovery rows) are re-stated over the
new model with their meaning preserved.

`over_terminal` is **not** one of them: it lives in `Singular.Statements`
(Statements.lean:142), not in the naming layer, and the interface **supersedes**
it with T1 rather than preserving it. Because the generic module also carries
`over_no_representative`, `resolve_over` and the `consumer` theorems, slice A's
handback must include a **retirement map** — see R12.

### R12 — the retirement map for the generic statements

Slice A's handback carries, for **all 44** declarations in the base
`lean/theorem-debt.json`, exactly one disposition each:

- **carried** — same meaning, same or new identity;
- **renamed** — to which exact identity;
- **retired** — with the reason (`consumerPin` removed, subsumed by T1, …).

Without it an auditor cannot distinguish a dropped guarantee from a rename, and
the page-against-manifest check passes happily on a manifest that quietly lost
rows.

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

## Decisions

Interface §9's three open items. Two are now **operator rulings** (A-002); one
was accepted as this ticket proposed it. They are no longer proposals, and
changing any of them needs a new operator ruling, not a ticket-owner decision.

### D-CODEC — the three-state leaf codec (frozen sibling contract, accepted)

The leaf value is **one byte**: `0x00` Absent, `0x01` Active, `0x02` Terminal.
Every other byte string **does not decode, and no root the cage produced contains
it**. The cage never decodes a leaf — it hashes the value it writes — so "the
cage refuses it" would describe a check that does not exist.

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

### R-ADA — the absent token's deposit belongs to the inserter (operator ruling)

**Operator ruling, A-002. It replaces this ticket's proposed D-ADA, which is
rejected.**

The `insertAbsent` request names a refund address. That address is recorded in
the custody datum beside the absent token. When the token is consumed — by
`updateActive` or by `deleteAbsent` — the value it held is paid to **that refund
address**: never to the consuming request's output, never to the folder.

The model must state the consequence: **cage custody holds exactly the
outstanding absent tokens, each with its refund address and its value.**

Why the ticket's proposal was wrong, recorded so it is not re-proposed: under
D-ADA whoever obtains a `deleteAbsent` approval harvests the inserter's min-ADA,
so in the open registry every absent witness is a bounty; and where the inserter
and the booker differ — a successor registry, reserved spellings — the
"value-neutral for whoever funded it" derivation is simply false.

### D-SELF — whether the registry refuses `insertAbsent` on its own account (accepted)

**It does not.** `insertAbsent` is admitted exactly like the other five tree
edges: by an approval under the pinned application policy, and by nothing else.

Derivation: §3 is explicit — "every tree change — the six edges, `insertAbsent`
included — must be certified by the pinned application policy", and "witnessing
absence is a tree change, so the application decides who may do it … with the same
sentence that governs every other edge." A registry-level refusal would contradict
that sentence and would remove the successor-registry and reserved-spellings
instances of §8. The model carries **no** `insertAbsent`-specific refusal.

### R-NM4 — naming's rule for the three absent edges (operator ruling)

**Operator ruling, A-002.** It completes NM4, which this ticket had left
incomplete for the absent edges.

| edge | naming's approval policy certifies on |
|---|---|
| `insertAbsent` | **anyone** — witnessing a fact needs no consent |
| `updateActive` | the signature of the controller who will own the record — exactly as `insertActive`; booking a witnessed-absent name is indistinguishable from booking an unknown one |
| `deleteAbsent` | the signature of **the refund address the `insertAbsent` request named** — the inserter only, never anyone else, never nobody |
| `insertActive` | the controller's signature |
| `updateTerminal` | **the committed recovery key** — the key whose hash the record commits to, revealed and signing exactly as `Recover` proves it — **or** a distinct-member quorum. The current control key alone **never** certifies it (operator ruling, NOTE-008). |
| `deleteActive` | **never** |

The story these rows serve: Carol owns the **witness** — only she can retract it,
and her deposit returns to her whichever way it ends. **Nobody owns the
absence** — anyone the policy admits may end it by booking, and the fold consumes
Carol's token without her signature, which is exactly why it lives in cage
custody.

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
