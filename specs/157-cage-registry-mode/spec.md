# #157 — the cage in registry mode replaces `consumer.ak`; naming's policies follow

Authority: the settled interface, gist revision `4a2bd178`
(https://gist.github.com/paolino/2fb03c2e6182fb861bb1361b3977fdc2), and the
#156 Lean model once frozen — the mandate at
`specs/156-registry-mode-model/`, operator-accepted at packet v3, head
`9668eee4b20f9eb87e31ec9c9ed5ea77e82529c7`. Where this document, the on-chain
code or the issue disagree with the interface or the frozen Lean, those win.
Constitution: `.specify/memory/constitution.md` v1.0.0.

Base: `main` at the commit this branch was cut from. Depends on #156 and
follows it: no Aiken is written against a model that is not frozen.

## The story

As **anyone folding a batch**, I see the cage refuse an illegal state move,
refuse a mint that does not match the edges it folded, put an absent token into
its own custody with the inserter's refund address beside it, verify a
`Read Terminal` at its position in the batch and require the terminal token it
entails — and I never run an application script to do any of it. What I see
when it is refused is one trace label that names the reason.

As **Alice**, booking a name, I sign one approval under the naming policy for
one key and one destination, attach it to my request, and after the fold my
record UTxO holds my representative and nobody else's; the folder could not
route it elsewhere.

As **Carol**, witnessing that a name is free, I submit `insertAbsent` with a
refund address; the fold puts the absent token into the cage's custody with my
address beside it. Whoever books the name later, and I alone if I retract it,
my deposit comes back to me.

As **Bob's escrow**, I read tokens and never the root: the representative's
presence is Alice's name being live, a terminal token's presence is a name
being over, forever.

As **cardano-keri**, I decode an eight-field state datum and a three-state leaf,
and I learned about the change from a re-baselined conformance page, not from
a failing proof.

## What changes, in one paragraph

The cage stops being a generic key → bytes map with a pinned consumer script
re-walking every batch beside it. It becomes the registry: the value of every
known leaf is one of three codec bytes; the four MPFS primitives are admitted
only in the seven combinations of the interface; a request that changes the
tree carries an approval under the pinned application policy or is never
folded; the cage sums the token deltas of the edges it folded and refuses any
mint under the three pinned token policies that differs; it routes each token
to the destination the request names — the absent token to its own custody —
and it verifies a read against the root at the read's position. `consumer.ak`,
its pin and the mandatory withdrawal are deleted. Naming becomes an instance:
its representative policy is the active-token policy, its approval policy
certifies six edges, its record is created by the fold at the destination the
approval bound, and nothing of naming's runs at fold time.

## Requirements — the cage (`onchain/validators`)

### C1 — the leaf codec and the operations

The value of every leaf is exactly one byte: `0x00` Absent, `0x01` Active,
`0x02` Terminal (#156 D-CODEC). `Operation` keeps its three constructors at
their indices and gains a fourth, appended: `Insert(value)` 0, `Delete(value)`
1, `Update(old, new)` 2, **`Read(value)` 3**. A request whose value bytes are not
a codec byte is refused before any proof is checked.

### C2 — the seven combinations, and everything else refused

| request | before-leaf | after | delta |
|---|---|---|---|
| `Insert(0x00)` | none | `0x00` | +1 absent |
| `Insert(0x01)` | none | `0x01` | +1 active |
| `Update(0x00, 0x01)` | `0x00` | `0x01` | −1 absent, +1 active |
| `Update(0x01, 0x02)` | `0x01` | `0x02` | −1 active |
| `Delete(0x00)` | `0x00` | none | −1 absent |
| `Delete(0x01)` | `0x01` | none | −1 active |
| `Read(0x02)` | `0x02` | `0x02` | +1 terminal |

Every other `(operation, bytes)` shape is refused by the cage with its own
trace label, before the proof: `Insert(0x02)`, `Update(_, 0x00)`,
`Update(0x00, 0x02)`, `Update(0x01, 0x01)`, `Update(0x02, _)`, `Delete(0x02)`,
`Read(0x00)`, `Read(0x01)`, and any non-codec byte. The MPFS primitive itself
refuses `Insert` on a known key, `Delete` on an unknown key, and any proof
against the wrong root — those keep their existing failure. A `Modify` with
zero consumed requests is refused; a batch of only reads leaves the root
unchanged and is accepted.

### C3 — the read

`Read(v)` is verified with the existing verifier and no new proof code:
`mpf.update(root, key, proof, v, v)` must return `root` itself, at the read's
position in the fold, so the proof is checked against the intermediate root
there. The leaf is unchanged. Only `v = 0x02` is admitted (C2).

### C4 — admission by approval

A request whose operation changes the tree — the six tree edges — is folded
only if its UTxO carries exactly one asset under `state.application_policy`,
quantity 1, whose asset name equals the **approval binding** of that request
(D-APPROVAL below). A `Read` request carries none and needs none. The approval
is not burned by the fold — no application script runs at fold time — and
leaves with the request's residual value; it certifies nothing else because
its name binds this key, this edge, this owner and this destination.

This replaces the mandatory consumer withdrawal, the pin equality and
`consumer.ak`'s R2. It generalises what the application checked at fold for
inserts to all six edges, inside the cage.

### C5 — the delta and the mint

The cage sums, over the requests it consumed, the token column of C2, per key.
The transaction's mint under `active_policy`, `absent_policy` and
`terminal_policy` must equal that sum exactly — asset by asset, quantity by
quantity — and nothing else may move under those three policies. The asset
name under each token policy is the registry key (D-ASSET). A mint that adds,
omits, doubles or renames one asset is refused as one delta mismatch.

### C6 — destinations

For each consumed request the cage requires, per token moved:

- **absent token minted** — exactly one output at the cage's own address
  carrying it, with inline datum `AbsentCustody { key, refund }` where `refund`
  is the address the request named (D-CUSTODY). No other asset in that output.
- **absent token consumed** (`Update(0x00,0x01)`, `Delete(0x00)`) — the custody
  UTxO for that key is a spent input; its lovelace is paid to an output at its
  `refund` address (R-ADA, #156). The cage's own spending path for a custody
  UTxO is: spent in a `Modify` that consumes a request for that key with one of
  these two operations, and nothing else.
- **active or terminal token minted** — exactly one output at the request's
  named destination, with the inline datum whose hash the request names, carrying
  the token (D-DEST) **and at least the request's value minus the tip**: the
  deposit that rode the request returns to the requester as that output's
  value. The folder earns the tip and nothing else (want-ledger R4: no folder
  incentive exists in this version, so the deposit is returned). For `Update(0x01,0x02)` the active token must be an input
  and burned; the cage does not care where it came from — the application's
  custody does (N4).

### C7 — the state datum

`State` becomes eight fields, in this order, replacing the six:

```
root, tip, process_time, retract_time,
application_policy, active_policy, absent_policy, terminal_policy
```

`consumer_pin` is deleted. `representative_policy` is renamed `active_policy`.
Genesis (`validateMint`) sets all four policies; every `Modify` preserves all
eight but `root`. This is the contract change cardano-keri conforms to
(CS01/CS02/CS08), re-baselined in this ticket (X1 below).

### C8 — request value coverage moves into the cage

`consumer.ak`'s R1 — every consumed request carries lovelace at least its
stated tip — is a cage check now, beside the existing `tip == state.tip`.

### C9 — retraction

Reads are retractable by their owner in phase 2, exactly as inserts are.
Update and delete requests keep today's rule: not retractable (the
completion-only custody binds them; the stranding gap is #130, out of scope).

### C10 — deletions

`consumer.ak` and `consumer.tests.ak` are deleted; the `consumerPin` mint-width
check, the withdrawal requirement, and every builder and fixture that
constructed the pin or the withdrawal go with them. The staking hook is
unchanged.

## Requirements — naming (`naming-onchain/validators`)

### N1 — the three token policies

One parametrised minting script, **`witness(kind, registry)`**, instantiated
three times (kind `0` absent, `1` active, `2` terminal) to give the three policy
ids pinned at genesis. Its rule: a mint or burn under this policy is accepted
only in a transaction that spends the registry's state token with `Modify` —
co-presence with the cage, which computes how many and where. The terminal
instance additionally accepts any burn unconditionally (W3: freely burnable).
`representative.ak` and its `Fold`/`Retire` redeemers are retired; the active
policy is `witness(1, registry)`.

### N2 — the approval policy: six edges

The application script's `mint` purpose certifies edges. Its redeemer becomes
one constructor, `Approve { edge, key, owner, destination }`, and the asset
name minted must equal the approval binding (D-APPROVAL). Per R-NM4:

| edge | certified on |
|---|---|
| `insertAbsent` | anyone; `owner` is the refund address of the request |
| `insertActive` | the signature of `owner`, the controller who will own the record; `destination` binds the record datum |
| `updateActive` | the same as `insertActive` |
| `updateTerminal` | the **committed recovery key** — the transaction reveals the preimage of the record's `next_control_commitment` and carries that key's signature, exactly as `Recover` proves it — **or** a distinct-member quorum of the record's stored quorum. The current control key alone does **not** certify termination (want-ledger R1, 2026-09-16) |
| `deleteAbsent` | the signature of the refund address recorded in the custody datum for `key`, read as a reference input |
| `deleteActive` | never — the arm refuses |

`WithdrawApproval` and `InsertApproval` are retired with the claim mechanism
(N3). Approvals are minted at request creation, one per request.

### N3 — the record is created by the fold, not by a claim

There is no pending claim UTxO, no `Fold`, no `Cancel`. A booking is: the
controller mints an `insertActive` (or `updateActive`) approval binding the
record datum, submits the cage request carrying it, and the fold creates the
record output at the application address with that datum and the active token
(C6). `ApplicationRedeemer` becomes `Maintain`, `Retire`, `Recover` — a
contract change for the runners' encodings, re-baselined here.

### N4 — retirement and completion

`Retire` changes its controller path: it is authorized by the **committed
recovery key** (reveal of `next_control_commitment` plus that key's signature,
the proof `Recover` uses) or by the quorum — never by the current control key
alone. A thief holding Alice's current key can change where the name pays until
she recovers; they can no longer end it. The authorized transaction moves the
active token from the record into completion-only custody, mints the
`updateTerminal` approval (N2 — the same proof is present) and creates the
completion request carrying it — today's co-created request. Completion is the fold of `Update(0x01, 0x02)`: the custody UTxO is
spent, its held token is the burn the delta requires, and the record's name is
`0x02` forever. `retirement_custody.ak` keeps its rules; `over_marker_for` and
the naming-specific value vocabulary in `naming.ak` are deleted.

### N5 — `maintain` and `recover` never touch the trie

Unchanged in mechanics; the rows that say the registry root is untouched by
them are kept and re-run.

### N6 — evidence

Rows in the existing `LM`/`LR`/`LT` style for every refusal above, each with
a control; every #156 theorem bound to at least one executable check seen to
fail; `just test` and `just script-identity-regen` green in both partitions;
the four #154 mutants executed at Aiken level (plan).

## Requirements — consumers and docs

### X1 — conformance re-baselined

CS01, CS02, CS08 and the address-derivation rows are re-cut against the
eight-field datum, the `Read` operation, the destination field, the
`AbsentCustody` datum and the new blueprint hashes. `docs/consumer-conformance.md`
states it as a contract change with the old and new field lists side by side.

### X2 — the naming docs

`docs/naming-lifecycle.md`, `docs/naming-demo.md` and `docs/recovery-retirement.md`
gain the state table, the seven edges with their tokens, the four laws of the
witnesses, and the sentence that no script of the application's runs at fold
time. Speech redone and restamped.

## Decisions this ticket freezes

Each is derived from the interface or from a #156 ruling; each is a contract
#158 and #152 consume, so it is reported in the handback for the operator to
overrule before they do.

### D-APPROVAL — what an approval certifies

The approval's asset name is
`blake2b_256(edge ‖ key ‖ owner ‖ destination)` where `edge` is one byte
(the C2 row index), `key` the registry key, `owner` the request owner's
credential bytes, and `destination` the D-DEST bytes (empty for edges that
mint nothing). One approval certifies one (edge, key, owner, destination);
the cage recomputes the name from the request and refuses a mismatch. It is
not burned at fold. Reuse by the same owner for the same edge, key and
destination is the same authority and is harmless; a different owner, edge or
destination cannot use it.

**Contract with #156:** the model's `admits` must scope an approval by the same
tuple. #156's D4 leaves the scope shape to its author; this decision fixes it.

### D-DEST — the request names where its token goes

`Request` gains one field, appended: `destination: (ByteArray, ByteArray)` —
address bytes and the hash of the inline datum the receiving output must
carry (empty hash for a datum-less output). The cage requires exactly one
output matching both and carrying the minted token. For `Read` the destination
is where the terminal token goes; for `Insert(0x00)` it is unused (the token
goes to custody) and its first component is the refund address.

Why: the folder is permissionless. Without a bound destination a folder could
route Alice's representative to itself; without a bound datum it could create
her record with a controller of its choosing.

### D-CUSTODY — the absent token's home

`CageDatum` gains a third constructor, appended: `AbsentCustody { key, refund }`.
The cage's spending path for it is C6. Lovelace in it is the request's residual
after the tip, the min-ADA that R-ADA returns.

### D-ASSET — one asset-name convention

Under each of the three token policies the asset name is the registry key
bytes. The representative name formula (`representative_name(key)`) is
replaced by the key itself. #152 binds to `(active_policy, key)` and
`(terminal_policy, key)`.

### D-RETRACT — reads are retractable

As C9. Reads are the only new retractable class; the completion-only custody
argument does not apply to them.

### D-TERMINATE — who obtains the terminate approval, and when

As N4: in the `Retire` transaction, on the **committed recovery key's** proof or
the quorum's signatures. Operator adjudication of want-ledger row R1
(2026-09-16): a name must not be endable by whoever holds the current control
key, because a key thief and Alice are indistinguishable there; the recovery
key is the one thing the thief does not have. `LT01` (controller retirement
accepts) is therefore **retired as a row**: the current control key alone is
refused; the committed key accepts; `LT02`/`LT03` stand.

### D-BOOT — where the four pinned policy ids come from at genesis

Ruling on ticket-157's Q-002 (2026-09-17). The runner's `CageConfig` carries
the four pins the eight-field datum needs — `cfgApplicationPolicy`,
`cfgActivePolicy`, `cfgAbsentPolicy`, `cfgTerminalPolicy` — and `cfgConsumerPin`
is deleted. None is typed by hand: each is **derived** from the two partitions'
`script-identity.json` given the registry identity the boot transaction is about
to create — the application policy is the naming application script's applied
hash; the three witness policies are `witness(kind, registry)` applied for
`kind` 0, 1, 2 (N1). The conformance rows CS01/CS02/CS08 assert that the
derivation round-trips through the boot datum. A placeholder id, or a retained
removed field, is a contract change and is refused as a finding.

The executable half of X1 stays in #157. The encoding change forces exactly five
runner/library files to follow under `-Werror` — `Config.hs`,
`TxBuilder/{ConnectedFold,Reject,Update,Internal}.hs` — and those are in this
ticket's surface as "what the encodings force to compile"; journey work stays
#158's.

### Known weaknesses, stated so they are read

Adjudicated *wanted, and visible* (want-ledger R2 and R3):

- **The quorum is fixed for the life of the name.** No action rewrites
  `retirement_quorum` after booking; a member who is lost or hostile is
  permanent. The only way to a new quorum is to retire and re-book.
- **The quorum can retire the name while the controller is present.** Nothing
  checks that Alice is gone; a threshold of members ends the name at any time.

The naming docs (X2) state both in the retirement section.

## Rejection behavior

Every refusal in C2, C4, C5, C6, N1, N2 and N4 is a distinct trace label,
observable in a script failure, and has a test row that produces it and a
control that shows the accepting shape.

## Observable success

From a clean checkout of the merged result, `nix develop --quiet -c just ci`
exits 0; in `onchain/` and `naming-onchain/`, `just test` and
`just script-identity` exit 0; `consumer.ak` does not exist; `script-identity.json`
in both partitions carries the new hashes; the conformance page states the
contract change.

## Non-goals

The runner and the release archive (#158). The escrow (#152). The CLI (#139).
The completion stranding defect (#130). Upstream MPFS. The Lean model (#156).
The interface page (#159).
