# #156 — the registry model in registry mode

Authority: the settled interface, gist revision `4a2bd178`, `interface.md`
SHA-256 `deda2321bc2d895e24fd291bb65f9f3901595fa185b121d627791b5ea9607d2a`.
Where this document, the issues, or the current Lean disagree with it, the
interface wins. Constitution: `.specify/memory/constitution.md` v1.0.0.

Base: `1bee7ca1d069737c81d441d1e895beff32392886`.

## The story

As the owner of #157, I receive a frozen Lean model whose **definitions are the
interface** — `Leaf`, `State`, seven edges, three token kinds, approval-token
admission — and whose **statements say exactly what the cage guarantees for
every application** and what naming adds for itself, each bound to a
Given/When/Then I can attach a check to.

As the author of an external consumer (#152, cardano-keri), I receive a leaf
codec and an eight-field state datum that are frozen contracts: I can build MPF
proofs and bind to `activePolicy`/`terminalPolicy` without another change here.

As a proof reviewer, I can run one command from a clean checkout and see every
statement proved from the standard axioms, with no `sorryAx`.

## What the registry is, in one paragraph

The trie answers two questions and nothing else: is this key known, and where in
its life is it. `Leaf ::= Unknown | Known State` and
`State ::= Absent | Active | Terminal`. Applications store nothing in the leaf;
their data lives in their own UTxOs, authenticated by the active token. Seven
edges move a leaf, each an MPFS primitive applied to a `State`, each a delta
over three token kinds. Six of them are tree changes and need an approval minted
under the pinned application policy; the seventh, `witnessTerminal`, is a read
and needs none. The cage sums the deltas of the edges it folded and refuses any
mint that differs.

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

The fold refuses, each with its own reason: `insert Terminal` (nothing is born
terminal); `update Absent` (a booking is not undone into absence); every edge
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
leaf unchanged. A fold of only reads is a fold. The cage admits `Read Terminal`
and refuses `Read Active` and `Read Absent`, so no attestation of a leaf that can
still move is ever produced.

### R6 — token custody and routing

Absent tokens are routed to the cage's own custody, so any later fold can consume
them without a signature. Active and terminal tokens go to the output the request
names. See D-ADA below for the disposition when an absent token is consumed.

### R7 — the state configuration

The configuration carries `root, maxFee, processTime, retractTime,
applicationPolicy, activePolicy, absentPolicy, terminalPolicy` — **eight fields**.
`consumerPin` is gone; `representativePolicy` becomes `activePolicy`.

### R8 — the statements

P1, L1, S1, S2, S3, O1, T1 and W1–W4, exactly as the interface states them, each
proved without `sorryAx`, each with a Given/When/Then and one executable model
observation. Full rows in `plan.md`.

### R9 — the instances

The **open application** — a policy that certifies everything — is the smallest
instantiation and is proved first; every statement in R8 holds for it. **Naming**
is the second: the record UTxO holds the active token; `maintain` and `recover`
never touch the trie; retirement completion is `updateTerminal`; the approval
policy certifies `insertActive` on the controller's signature and
`updateTerminal` on the quorum's; `deleteActive` is never certified. The existing
naming statements (`over_terminal`, `naming_delete_refused`, `WellFormed`, the
recovery rows) are re-stated over the new model with their meaning preserved.

### R10 — the generated surfaces

Theorem manifests, theorem-debt files, the corpora and `docs/theorems.md` with
its `docs/theorems.speech.json` correspond to the accepted model revision and
land in the same diff.

## Decisions this ticket freezes

These are the three items interface §9 leaves open. Each is settled here with its
derivation, and each is reported in the handback so the epic owner and the
operator can overrule before #157 consumes it.

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

Obligations: `encode`/`decode` are total and mutually inverse on valid bytes,
injective, and decidable; no byte decodes to two states; a naming-era leaf byte
string does not decode. #157 and #152 consume this verbatim.

### D-ADA — where the absent token's min-ADA goes when it is consumed

On `updateActive` and `deleteAbsent`, the value held with the consumed absent
token is paid to **the output the consuming request names** — the same
destination rule already governing the active and terminal tokens.

Derivation: §2 makes the absent token biconditional, created on entry and
consumed by every exit in the fold itself; #154 puts it in cage custody so a
later fold needs no signature. Paying it to the folder would pay the folder twice
(tip plus custody) and distort the fold market; retaining it would accumulate
unbounded dust in cage custody. Routing it to the request's named output keeps
one routing sentence for all three kinds, keeps cage custody equal to exactly the
outstanding absent tokens, and makes `insertAbsent` → `updateActive` value-neutral
for the application that funded it.

### D-SELF — whether the registry refuses `insertAbsent` on its own account

**It does not.** `insertAbsent` is admitted exactly like the other five tree
edges: by an approval under the pinned application policy, and by nothing else.

Derivation: §3 is explicit — "every tree change — the six edges, `insertAbsent`
included — must be certified by the pinned application policy", and "witnessing
absence is a tree change, so the application decides who may do it — naming,
anyone; a reserved-spellings registry, its own rule — with the same sentence that
governs every other edge." A registry-level refusal would contradict that
sentence and would remove the successor-registry and reserved-spellings instances
of §8. The model therefore carries **no** `insertAbsent`-specific refusal.

## Rejection behavior

Every refusal above is observable as a distinct refusal reason, not a silent
no-op, and each has a control that can produce it.

## Observable success

From a clean checkout: `nix develop --quiet -c just model` exits 0, the compiled
axiom report carries no `sorryAx` for any statement in R8/R9, and the four #154
mutants each break their named law.

## Non-goals

On-chain code (#157). The runner and release wiring (#158). Upstream MPFS. The
escrow's own model (#152). The registry-interface documentation page (#159,
desk-owned). This ticket does not publish or tag a release and makes no on-chain
or runner conformance claim.

## Open, not settled here

**Q-001** — the model-derived consumers (`simulator/**`, `tools/check_model.py`,
`docs/design.md`, `docs/model-ledger.md`, `docs/simulation.md`) are bound by hash
and exact identity to the `lean/` artifacts this ticket rewrites, and they sit
outside this ticket's surface. Proven: a `lean/`-only change reddens
`just simulator` (control exit 0, perturbed exit 1, `naming theorem identity`).
The epic owner owns who repairs them and in which PR. The slice below does not
start until that is answered, because the answer sets the gate's green criterion.
