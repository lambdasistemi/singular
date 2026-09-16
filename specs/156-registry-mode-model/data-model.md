# #156 — data model

Fields, relationships, validation and state invariants. No bodies.

## The leaf

```
Leaf  ::= Unknown | Known State
State ::= Absent | Active | Terminal
```

`Unknown` is a non-membership proof; `Known s` is a membership proof whose value
is `s`. Nothing else may occupy the value slot: no application payload, no
version counter, no incarnation. A key has exactly one leaf.

**Removed, not renamed:** `Value`, `Entry.incarnation`, `Representative.assetScope`,
`Config.reuseIdentity`, `Config.consumerPin`. A rename would preserve a
distinction the registry does not make.

## The leaf codec (frozen contract — D-CODEC)

| state | byte |
|---|---|
| `Absent` | `0x00` |
| `Active` | `0x01` |
| `Terminal` | `0x02` |

Validation: encoding is total and injective; decoding is defined on exactly these
three one-byte strings and undefined everywhere else, including the empty string,
any longer string, and `0x03`. Naming-era leaf bytes are not valid leaves.

## The state configuration — eight fields (R7)

| field | role | changed |
|---|---|---|
| `root` | the authenticated map's root | — |
| `maxFee` | fold economics | — |
| `processTime` | request window | — |
| `retractTime` | retraction window | — |
| `applicationPolicy` | certifies requests; admission for the six tree edges | — |
| `activePolicy` | mints the active token | renamed from `representativePolicy` |
| `absentPolicy` | mints the absent token | new |
| `terminalPolicy` | mints the terminal token | new |

`consumerPin` is removed. All eight are pinned when the registry's seed is spent
and are equal before and after every fold (I-P1).

## Token kinds

| kind | witnesses | shape | supply rule |
|---|---|---|---|
| active | `Active` | biconditional | exactly one iff `Known Active`, else none (I-W1, I-S3) |
| absent | `Absent` | biconditional | exactly one iff `Known Absent`, else none (I-W2, I-S3) |
| terminal | `Terminal` | implicational | any number; any exists only if `Known Terminal`; freely burnable (I-W3) |

Identity is `(policy, key)`. After a `deleteActive` a recreated key carries the
same identity, by design.

**Kind exclusion (I-W4):** for any key, at most one kind is ever outstanding. One
terminal token excludes the active and the absent token; an active token excludes
an absent token and every terminal token; an absent token excludes an active token
and every terminal token.

## Custody and value

| token | custody | value on consumption |
|---|---|---|
| absent | the cage's own, so a later fold consumes it without a signature | paid to the output the consuming request names (D-ADA) |
| active | the output the request names | — |
| terminal | the output the request names | — |

Invariant: cage custody holds exactly the outstanding absent tokens and their
value — no more, no less.

## Edges and deltas

The R2 table in `spec.md` is the definition. Each edge's delta is read off the
edge and nothing else; the cage sums the column for the edges it folded and
refuses any mint under the pinned token policies that differs from that sum.

## State invariants

| invariant | statement |
|---|---|
| occupancy | "taken" is `Active` or `Terminal`; a booking edge succeeds iff the key is not taken (I-O1) |
| termination | a `Terminal` leaf admits no edge, ever (I-T1, I-S2) |
| sync | biconditional supply is 1 iff the key is in that state (I-S3) |
| atomicity | a batch is all-or-nothing; a request is spent once (I-L1) |
| pins | the four policies are immutable across folds (I-P1) |
| reads | a read changes no leaf and no root, and only `Read Terminal` is admitted (R5, I-S1) |

## Application data

Nothing an application stores is in the trie. Application data — naming's
controller, destination, next-control commitment and quorum; a KERI key state —
lives in the application's own UTxO, authenticated by the active token it carries.
