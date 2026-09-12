# Naming LI correspondence record

The correspondence between the abstract identities the epic-15 contract's
`LI` rows carry and the concrete ledger objects this epic intends to
realise them with.

**This record is an epic 16 design artifact, not something the v0.2.0
contract blessed.** v0.2.0's acceptance note states that the concrete
ledger witness and script partition remain abstract and are
implementation work for the on-chain epics. Every entry below is
**intended-but-unproven** until a validator realises it; issue #47 is
where the partition becomes realised, and any entry may still be recut
there.

Grounding row, read from the contract's own corpus
(`simulator/lifecycle-corpus.json`, `initializations`):

```
LI01-canonical-initialization-accepts
  attempt:  { registry: 1, applicationPolicy: 7, representativePolicy: 8,
              seed: 400, seedConsumed: true, validatorScript: 12,
              sourceRevision: "14a64a…" }
  witness:  { seedSpend: true,  everything else false/empty }
```

Every substitution attempt (LI02 seed, LI03 registry, LI04/LI05/LI07/LI08
policies and script) is refused with `seedSpend: false` — the five
identities below are bound together at initialization or not at all.

## Abstract identity → intended concrete realisation

| abstract identity (LI row) | intended concrete ledger realisation | status |
|---|---|---|
| `registry` (1) | The singleton registry state UTxO held at the naming application validator, carrying the registry state token; the abstract `registry` nat indexes it (the state token's name/incarnation). **Limit (t50, A-001): rival registries CAN exist** — a second seed can mint a second registry-shaped token under the same policy, and the ledger accepts it. Rivals are not prevented, they are distinguished: the canonical registry is the one whose token name is SHA-256 of the canonical seed's outRef, and a rival can never carry that name. | status: realised (#47) — the UTxO `3f444e1300346875d8462a4af81f16ca8fd0e26ef1d232b515b14a79a8b672cf#0` at the applied state script address, carrying exactly 1 registry token named `0xc1f1c9b09607e0f63d1580f3e9d3eb88b7d8a208f5a3d4be01b8fd009eebb632`; the t50 run observed an accepted rival (tx `6bad8f09…`) coexisting with the canonical registry, distinct by name and UTxO |
| `applicationPolicy` (7) | The `PolicyId` (script hash) of the application minting policy compiled from the naming blueprint — mints the insert-request token on `insert` and burns it when the request folds or is cancelled. | status: bound (#52) — authored as the `mint` purpose of the naming application validator in `naming-onchain/` (one script hash serving both purposes, the imported partition's state-script pattern): pinned hash `b180c9341384072edc93d75c573d10f5f590224ff117e9de1d6a06ff` (`naming-onchain/script-identity.json`, 0 parameters, so the pinned hash is the applied address). The policy branch currently mints and binds **withdraw approvals** (asset name = the refund destination it binds, minted on the controller's signature — the `LC03` "separate cancellation approval"); insert-request token minting remains unrealised until the insert flow is executed, and is recorded as the seam in the t52 report |
| `representativePolicy` (8) | The `PolicyId` (script hash) of the representative minting policy — one representative NFT per naming record; `assetScope` is the record's incarnation, so reuse mints a fresh representative under the same policy. | status: bound (#52) — authored in `naming-onchain/` and pinned as `representative.representative.mint` `6f14bdea9ab880c3b6934f43942ace2b971d13a8f4123f090677f1dc` (`naming-onchain/script-identity.json`, 1 parameter: the application policy hash). It never moves an asset on its own authority: a mint or burn must ride a transaction spending a naming claim or record at the application validator, and the application spend's own redeemer (`Fold`/`Retire`) must name exactly the representatives moved, each at exactly ±1 |
| `validatorScript` (12) | The compiled registry/application spending validator's script identity, from the pinned partition in `onchain/script-identity.json` (read at run time via `MPFS_BLUEPRINT`, never baked into the offchain tree). LI08 refuses a substituted validator script, so the identity is part of the initialization binding. | status: realised (#47) — the applied `state.state` script `0xce7615f6ba4de80dfa9b9c6aef680666472ba4ed7e640ff55aad7c6e` (derived from the pinned unapplied `0xd42860fa…` with `previousPolicies=[]`), read back from the registry UTxO's address credential and carried as the tx's only script witness; the same script hash is the bootstrap minting policy |
| `canonicalSeed` (400) | The canonical seed UTxO: a unique outRef consumed by the initialization transaction (`seedConsumed: true`). **Correction (t50, A-001):** uniqueness of THE canonical registry (LI02, LI06) is enforced by *spending* the canonical seed — it can never be consumed again — not by referencing it. That mechanism **does not hold against rivals from other seeds**: a consistent initialization from a second seed is accepted by the frozen bootstrap (t50 executed it; see the t50 section). What bounds a rival is *name derivation*, not a refusal: a rival's token name is SHA-256 of its own seed's outRef, so it can never carry the canonical name. | status: realised (#47) — the lexically first UTxO of the devnet genesis wallet, consumed by tx `3f444e1300346875d8462a4af81f16ca8fd0e26ef1d232b515b14a79a8b672cf`; bound on chain by the registry token name, which is SHA-256 of the seed outRef |

## `executingWitness` flag → intended concrete witness

| flag (LI rows) | intended concrete ledger witness | status |
|---|---|---|
| `seedSpend` | A transaction input spending the canonical seed UTxO, witnessed by the bootstrap/seed validator. The only flag set on the accepted `LI01`. | status: realised (#47) — the canonical seed outRef was a transaction input, and the witness is the applied state policy's *mint branch*: a `Minting(seed)` redeemer whose validator requires `find_input(inputs, seed)` and exactly one token named by the seed. There is no separate seed validator in the frozen partition; the bootstrap enforcement lives in the mint policy |
| `applicationMint` | A `mint` field under the application policy: request token minted on `insert`, burned on withdrawal/fold/cancellation. | intended-but-unproven (#47) |
| `applicationSpend` | An input consumed at the application validator, carrying the naming datum (the four-field codec of this slice) and the application redeemer. | intended-but-unproven (#47) |
| `representativeMint` | A mint/burn under the representative policy, executed when a claim folds into a record (mint) or a record is retired/reused (burn). | intended-but-unproven (#47) |
| `authenticatedRead` | A reference input resolving to the registry state UTxO, authenticated by requiring the resolved output's script to be the pinned application validator — the read is bound by script identity, not by spending. | intended-but-unproven (#47) |
| `nativeSpend` | A phase-1 (native) script spend — the cancellation path the lifecycle rows mark `nativeSpend: true`, so a cancellation needs no Plutus spending witness on the request output. | intended-but-unproven (#47) |
| `requiredSigners` | The transaction's `requiredSigners` (extra key witnesses) that validators demand — minimally the controller's payment key hash on control-changing transitions. | intended-but-unproven (#47) |
| `quorumSigners` | The `retirementQuorum` members' key hashes: the retirement transitions check that at least `threshold` of the stored 28-byte member hashes appear among the transaction signatories. | intended-but-unproven (#47) |

## Where the encoding itself lives

The datum bytes these witnesses will carry are already fixed by the
contract, not by this record: the four-field codec and its vendored
vectors live in `naming/` (`naming/src/Naming/Datum.hs`, provably
byte-exact against v0.2.0's `wire` vectors). The vectors are the
contract's; the realisation table above is this epic's design.

## What run #47 settled (2026-09-10)

The LI01 run (`naming-correspondence` entries above marked realised)
settled one open question and surfaced two findings.

**Settled — the bootstrap mint belongs inside LI01.** The ledger's
at-most-once bootstrap is enforced by the applied state policy's mint
branch, and the only transaction that can consume the canonical seed
with a script witness therefore mints exactly one registry identity
token (name = SHA-256 of the seed outRef) under that same policy. This
mint is under the `validatorScript` identity, not under
`applicationPolicy` or `representativePolicy`, so it contradicts no
flag the row calls absent; it is the ledger shape of "one mint per
chosen seed precedent". The row's `executingWitness` stays exactly
`seedSpend: true` over everything else absent.

**Finding — the checkpoint output has no validator-prescribed shape.**
The initialization also creates a naming checkpoint output at the
application validator address carrying the four-field naming datum
inline (control address, payment destination, next-control commitment,
retirement quorum). The frozen validator constrains only output 0 (the
registry state UTxO); the checkpoint's well-formedness is enforced
off-chain by the `Naming.Datum` codec, on chain by nothing. First
consumer: the claim rows.

**Finding — `representativePolicy` has no realisation in the frozen
partition, and LI01's `representativeMint: false` is realised as an
asserted absence, not as an unimplemented step.** The initialization
mints no representative, and the run *checks* that absence: control C2
raises the expected representative quantity to 1 and the run fails
naming expected 1 vs observed 0. No representative minting policy
exists in the blueprint at all, so the claim rows
(`representativeMint: true`) cannot execute against this partition
without new validator work.

## What t52 bound (2026-09-10)

Issue #52 authored Singular's naming validators in their own tree,
`naming-onchain/` (own `aiken.toml`, own flake, `flake.lock` copied
byte-for-byte from `onchain/` — the two-flake split pattern of D-018,
so the pinned Aiken toolchain and therefore every pinned hash is
comparable with the imported partition's). Both scripts are Aiken-level
only: the `LM`/`LC` rows are still not executed on a ledger — that is
the next slice, which now has something real to execute against.

**`applicationSpend` — the naming application validator is realised and
enforces the `LM` rows.** Its spend purpose takes the four-field naming
datum in the accepted encoding (double `constr(0)` wrap, option-encoded
payment destination, 32-byte commitment, 28-byte quorum members,
threshold 1..distinct members — mirrored function for function from the
`Naming.Datum` codec; a fifth field refuses). Maintenance (`Maintain`)
requires the control address's payment key hash among the transaction
signatories and preserves control address, next-control commitment and
retirement quorum exactly; only the payment destination is maintainable
(`LM01` accepts, `LM02`/`LM03`/`LM04` refuse). Fold freezes the
four-field datum into the record; Retire refuses any continuation
carrying the same datum.

**The `LC` rows needed new script code — the MPFS request/retract
machinery cannot carry cancellation.** Read from `onchain/validators/`
(source, not memory): (1) the MPFS `Request` datum has no refund field
— `requestOwner`, `tip`, `submitted_at` — so `LC02`'s stored-refund
comparison is not expressible; (2) `Retract` authorizes by the request
owner's signature, while the `LC` rows present **no signers** — the
authorization in the contract is a separate withdraw approval, which
MPFS has no concept of (`LC03`'s `withdraw-binding`); (3) what MPFS
*does* give for free is `request-unavailable`: a consumed UTxO cannot
be re-spent, which is the ledger shape of `LC04`/`LC06`. The refund
comparison therefore lives in the new application validator's
`Cancel` path: the withdraw approval rides the claim under the
application policy with the stored refund destination as its asset
name; `Cancel` compares the presented refund against that binding,
requires the approval burned exactly once, refuses any continuation
record, and requires the refund paid to the bound destination.

**`nativeSpend` — one recut this realisation implies, flagged for the
execution slice.** The record's intended `nativeSpend` realisation (a
phase-1 script spend, no Plutus spending witness) cannot enforce the
refund comparison: a native script cannot read an asset name, a datum,
or an output address, so a phase-1-only cancellation either trusts the
spender or refuses nothing — and an always-passing claim address is
theftable. Under the t52 realisation, executing `LC` will present as an
application spend (plus the approval burn), i.e. the `nativeSpend: true`
flag is realised as "no Plutus spend on the *request* output", not "no
Plutus anywhere". Recutting the flag's concrete witness is within this
epic's mandate (the v0.2.0 partition is abstract); the row's accepted
behaviour is unchanged.

**What the four-field datum cannot carry, said precisely.** "At most one
live representative per record identity across time" is not
expressible in a minting policy alone — a name can be reminted after
burn, and the datum has no fifth field to carry a counter. The policy
enforces what a policy can (mints bound to application-spend `Fold`
redeemers, exact quantities, nothing else under the policy); live
uniqueness must come from the registry state (the MPF maps spellings to
commitments) at execution time. Likewise, fold-time issuance of the
withdraw approval into the claim's value, and the insert-request token
itself, belong to the insert/fold execution flow — the mint purpose's
`WithdrawApproval` branch binds the destination and requires the
controller's signature, and the deeper controller-to-record binding
lands with the flow that constructs those transactions.

**NOTE-001 refresh (2026-09-10).** The epic owner's NOTE-001 caught the
`LC04`/`LC06` rows claimed but untested — and the check surfaced a real
gap: `Fold` preserved the claim's value wholesale, so a withdraw
approval would have flowed into the record and a folded claim *could be
cancelled*. `Fold` now consumes the approval (burned exactly once, the
record inheriting the claim's value minus it), making this record's own
realisation sentence — the application policy "burns it when the
request folds **or** is cancelled" — true on chain. `LC04` and `LC06`
are enforced by construction and observed refusing
(`lc04_folded_claim_cancellation_refuses`,
`lc06_cancellation_replay_refuses`); the application hash moved to
`b180c9341384072edc93d75c573d10f5f590224ff117e9de1d6a06ff` and the
manifest diff records it.

## What t50 settled (2026-09-11)

The seven refusal rows (LI02–LI08) met the ledger, and the run recut the
initialization row family into **three enforcement mechanisms** — not one:

1. **Validators refuse** LI02, LI04, LI05, LI07 and LI08. Each attempt is
   well-formed except for the single substituted element, and the phase-2
   `PlutusFailure` names the script that binds that element: the applied state
   script for the seed check (LI02) and the registry identity (LI04); the
   substituted application policy's own address discipline (LI05, with the
   boundary probe showing a well-formed mint under it is accepted — the
   refusal is the policy's rule, not the initialization binding); the
   substituted representative policy's ride-along requirement (LI07); the
   substituted validator script, which cannot perform the bootstrap (LI08).
2. **The ledger refuses** LI06: after a real LI01, replaying the exact signed
   initialization fails in phase 1 (`All inputs are spent`) — a consumed UTxO
   cannot be re-spent, no validator involved (the LC06 precedent).
3. **Name derivation bounds** LI03, which is **not refused at all**: a
   consistent rival registry from a second seed passes every frozen check and
   the node accepted it. The ruling (A-001, option 1) records this as the
   design: a rival is not dangerous because it exists, it would be dangerous
   if it were mistakable for the canonical registry, and it is not — its token
   name is SHA-256 of its own seed's outRef, so it can never carry the
   canonical name, and LI06 proves the canonical seed (hence the canonical
   name's source) is spent exactly once. The model's LI03 refusal
   (`canonical-seed` at the shape check) is therefore **not realisable as a
   ledger refusal** against the frozen partition; the row asserts the
   accepted-and-bounded outcome instead (rival accepted, names differ,
   canonical registry unaffected — read back from the chain).

## What t62 executed (2026-09-11)

Issue #62 put recovery on a real ledger: the eleven rows `LR01..LR11`
executed against Singular's naming application validator (pinned
application hash `c368590a917e7459772a3e0c0fc96ed16faf638c1058e2a95067c56e`,
0 parameters, so the pinned hash is the applied address — the
`t52`-bound identity moved from `b180c93413…` by the appended `Recover`
redeemer, representative unchanged `6f14bdea9a…`).

**`applicationSpend` — the recovery spend is realised.** Its spend
purpose takes the four-field naming datum in the accepted encoding and
a `Recover { revealed_control, representatives, registry }` redeemer
(index 4; `Maintain`/`Cancel`/`Fold`/`Retire` keep their indices or the
`lmlc` encodings break). In model order it demands the claimed registry
equal the spent input's own hash (`LR10`), the claimed representatives
equal the single token the consumed record carries under the
application policy (`LR09`), the reveal be a canonical payment-key
address, its domain-separated `BLAKE2b-256` commitment equal the stored
one (`LR02`, `LR04`, `LR06` — the forged row passes iff the domain
separation is dropped), the reveal's payment key among the required
signers (`LR03`, `LR07`), the successor's control exactly the reveal
with payment destination and quorum unchanged (`LR11`), its commitment
32 bytes and different (`LR08`), and a well-formed successor datum.
The successor carries the record's value, representative included.
Observed 2026-09-11: three setup transactions created main
`92849eee96…#0`, refusals `c342224d68…#0` and forged `fe94f9d8cf…#0` at
the application validator, each with the representative
`0x606f82dec3b28e4c34b783ff746013d6e8541da83e32d98890bdc2cb70`;
`LR01` accepted `5239793d44…` (required signers exactly the reveal, no
old-controller signature), its successor read back field by field with
the merged codec; every refusal came back phase-2 naming the
application hash; `LR04` replayed the consumed reveal against the
genuine successor and `LR05`'s old-controller maintenance was refused
by the existing `Maintain` path; maintenance under the recovered key
accepted `df93250129…`.

**`requiredSigners` — the recovery authorisation is realised.** `LR01`'s
transaction carries no old-controller signature: its required signers
are exactly the revealed address's payment key, witnessed by that key
alongside the funding key. `LR03` (no signer) and `LR07` (old
controller's key) are refused on the required signer, each a
single-defect mutant of the accepted row.

**Limit (t62).** The representative for this slice rides under the
application policy (minted via the existing `WithdrawApproval` branch
with a canonical name) as a stand-in, since removed, preserving the single-token
shape; the full representative-policy NFT flow stays as bound in #52.
The registry binding on ledger is the application validator hash
itself. Retirement has no rows here.

## What t66 executed (2026-09-11)

Issue #66 put retirement initiation on a real ledger: the seven
in-scope rows `LT01..LT03`, `LT05`, `LT06`, `LT08`, `LT09` executed
against Singular's naming application validator (pinned application
hash `58d3d792a9511bdcdfad9359be78e30496a22cfd5618dc4da0035345`,
0 parameters, so the pinned hash is the applied address — the
`t62`-bound identity moved from `c368590a91…` by the authorised
`Retire` and the hardcoded custody hash) and the new completion-only
custody script (pinned `retirement_custody.retirement_custody.spend`
`0a92d14aa73db354d7468f0f09352cfedb6169adf32ea74e82666954`,
0 parameters, so its hash is the address `Retire` must place the
representative at).

**`applicationSpend` — the retirement spend is realised.** Its spend
purpose takes the four-field naming datum in the accepted encoding and
a `Retire { representatives }` redeemer (index 3; `Maintain`/`Cancel`/
`Fold` keep their indices and `Recover` stays at 4, or the `lmlc`
encodings break). In model order it demands the controller's payment
key or at least `threshold` distinct stored quorum members among the
required signers (`LT03` — one distinct signature short — and the
duplicate-member shape refused on `retirement-authorization`;
`eraseDups` is load-bearing), the record's single representative under
the application policy land at the custody script address (`LT08`,
authorised but sent anywhere else, refused on `retirement-request`;
creating that output executes no receiving script, so the refusal
comes from the `Retire` spend), and no continuation of the record.
Observed 2026-09-11: three setup transactions created accept1
`e1fdb82862…#0`, accept2 `a8fc578de…#0` and refusals `5597695800…#0` at
the application validator, each with the representative
`0x6015ace1e578f773adc5e0005a660dc3de6e60cbcd702e0ce0d0abed96`
under the application policy, control distinct from the two-member
quorum at threshold 2; `LT01` accepted `72a6034043…` (required signers
exactly the controller, no quorum member) and `LT02` accepted
`03b2120134…` (required signers exactly the two quorum members, no
controller); every refusal came back phase-2 naming the application
hash; `LT09` replayed `LT01`'s exact transaction against the consumed
record and the ledger itself refused the spent output in phase 1
(`All inputs are spent`, the `LC06` precedent — recorded as exactly
that, not as a validator refusal). A fourth setup record carries a
stored quorum naming one member twice and a second once at threshold
two; the duplicated member alone is refused on
`retirement-authorization`, binding the distinctness.

**`requiredSigners` and `quorumSigners` — the retirement authorisation
is realised.** The controller route needs no quorum signature and the
quorum route needs no controller signature: each is shown sufficient
alone from the chain. `LT05` and `LT06` are not retirements — quorum-
signed maintenance changing the control fields and the payment
destination — and are refused on `controller-signature` by the
existing `Maintain` path with no new check, proving quorum power is
bounded to ending the name.

**`retirement-request` — custody is realised and proved from the
chain.** After `LT01` and `LT02` the representative is observed at the
custody script address in the accepting transaction's own outputs and
the consumed record is observed gone from the application validator.
The custody script itself carries a single spending path — completion,
which burns what it holds exactly once and requires no signature —
and no withdrawal, redirection or `Delete` path; spending it
(`LT04` completion, `LT07` withdrawal refusal) is the next child and
has no rows here.

**Limit (t66).** The representative for this slice was still the
application-policy stand-in from #62 (the shape t77 removed; minted via the existing
`WithdrawApproval` branch with a canonical name), not the real
representative-policy NFT flow: the `Retire` redeemer names it but the
validator binds the chain-carried token, and no mint or burn under
either policy rides the retirement. The real flow — `Fold` minting the
NFT under the representative policy, retirement preserving it into
custody, completion burning it there — stays as bound in #52.

## What t77 executed (2026-09-12)

Issue #77 realises the flow t66 left as a limit: the representative is
now a real NFT minted under the applied representative policy
(`applyBytesParam` of the unapplied `representative.representative`
code with the application-policy hash; the mint branch of the policy
is parameter-free, so approval burns and representative mints ride the
same connected transaction). The insert approval is a single-use mint
under the application policy (`InsertApproval { controller, control,
commitment }`, `insertApprovalName = BLAKE2b-256(domain || 0x00 ||
control || commitment)`); the `Fold` spend branch consumes the claim
only when the fold burns that exact approval and mints
`representativeName = Rep || keyHash || 0x00` for the controller; an
empty `Fold` list takes the withdraw path and refuses any
representative movement.

**The registry key is the spelling.** The connected transaction is
one state `Modify`, one MPFS request `Contribute`, and the naming
`Fold`: the registry maps the spelling bytes (`alice`, `bob`,
`rc-*`, `rt-*`) to the representative name, and the naming validator
binds the in-transaction triangle (request key, claim control,
approval, representative). No registry-owner role exists anywhere in
the slice — `End`, migration, and `Sweep` are explicit refusals — so
the fold needs no owner signature; the controller's witness was
checked at insert time.

**Every record in every runner is a genuine fold.** `register-rows`
folds `alice` connected and refuses the duplicate-key adversarial
fold on chain; `recovery-rows` folds three records (`rc-main`,
`rc-refusals`, `rc-forged`) and `retirement-rows` folds four
(`rt-accept1`, `rt-accept2`, `rt-refusals`, `rt-duplicates`) through
the same connected shape before their `LR`/`LT` rows run. The
seventeen `connected-verifier` verdicts recompute from raw bodies,
listings, and outcomes; the `t62`/`t66` rows keep passing because the
repairs preserved their token shapes, now under the representative
policy instead of the removed stand-in.

**Limit (t77).** The spelling-to-control binding is observed only
through co-consumption inside one transaction; nothing on the ledger
maps a spelling to its controller outside the fold that carries both.
The model treats that table as external, and this slice does not
change that.
