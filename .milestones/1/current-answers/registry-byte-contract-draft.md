# Byte contract — registry-bound representative name (NOTE-008 deliverable, in progress)

Status: Aiken side landed (uncommitted, `aiken check` 98/98 green); offchain
mirror + cross-language vectors + measured identities pending SDK work next.
This section is written as I go per NOTE-008 (critical path for epic 18).

## Shape (notation only — the contract is § Preimage)

```
name = 0x526570 ‖ blake2b_224(registry_asset_id ‖ control_hash) ‖ incarnation
```

32 bytes (3 + 28 + 1). Prefix and incarnation byte unchanged; the middle 28
bytes bind key AND registry (previously key alone — E-001 omission shape).

## Exact production type and encoding path (file:function)

`registry_asset_id` is the FULL native asset identity with components in
ledger order — state policy id bytes (28, fixed) followed by cage token name
bytes (variable) — concatenated with no framing and no textual hex step:

- on-chain: `naming-onchain/validators/application.ak:registry_asset_id`
  (takes the two byte ranges, returns their concat);
- offchain: `offchain/naming/src/Naming/Register.hs:registryAssetId`
  (TO BE WRITTEN next — same concat; the Haskell `representativeName`
  mirror takes `(keyHash, policyBytes, tokenName)` in that order).

Precedent this reuses (same file, same shape): `application.ak:
insert_approval_name` (`domain ‖ 0x00 ‖ control ‖ commitment`) and its
Haskell mirror `Naming.Register:insertApprovalName` — domain-separated raw
field concat, proven byte-identical by passing folds on both sides. The
policy/token component bytes are exactly the bytes the ledger pairs in every
`Value` (policy Dict-key bytes + asset-name bytes); no hex-text step exists
anywhere on either path. If the desk requires CBOR-`Data` framing instead,
the fallback is bounded (both helpers take one encoder each); say so only
then — the current form is spec-exact to NOTE-007 and unambiguous for
hashing (fixed 28-byte policy prefix; variable token name trailing).

## Exact hash preimage (hand-assemblable)

```
preimage = policy_bytes[28] ‖ token_name_bytes[var] ‖ control_hash[28]
digest   = blake2b_224(preimage)          # 28 bytes
name     = 0x52 0x65 0x70 ‖ digest[28] ‖ incarnation[1]
```

- `policy_bytes`: the MPFS state script hash as bytes — on-chain the
  `mpfs_state_hash` constant in `naming.ak`; offchain `scriptHashBytes`
  of the built state script. Global across cages; present so the value is
  the full asset identity, not just the name.
- `token_name_bytes`: the cage token asset name as bytes — on-chain the
  NFT name read from the supplied state's value (same authenticated input
  as the policy read, never a second lookup); offchain the `TokenId` name.
- `control_hash`: 28-byte payment-key hash from the record's control
  address (`naming.control_hash`), both sides.
- `incarnation`: one byte (`0x00` fresh; reuse flows keep the parameter).

No length prefixes, no CBOR framing, no domain string inside the hash —
exactly the three ranges above in exactly this order.

## Deterministic cross-language vectors (PENDING — needs the offchain mirror)

At least three registry/control pairs (distinct token names, distinct
controls, incl. one foreign-registry pair), each with preimage bytes and
resulting asset name, produced by the ACTUAL on-chain path (Aiken
`representative_name` via `aiken check` vectors or `PublishingAlchemist`
equivalent) and by the ACTUAL offchain path (`Naming.Register`
mirror), shown byte-equal. One-sided vectors prove nothing — both columns
land together with the SDK work, before any consumer migrates.

## Checks as implemented (quoted)

Creation (insert fold, `application.ak` `fold`): redeemer names must equal
`[representative_name(control_hash(record), mpfs_state_hash,
expected_rep_token(tx))]` over the SPENT state's token, plus the standing
mint/value `quantity_of` checks under the datum-pinned policy.
Retirement (`retire`): `stored_rep` must equal the same recomputation over
the SUPPLIED state's token, plus input/custody `quantity_of` under the
pinned policy. Invariant: `expected_rep_token` reads the NFT name from the
same `find_registry_state` input as the policy — never a second lookup that
could disagree.

## Identities (unapplied vs applied, separately — NOTE-008 §1)

To be measured from builds at commit time, never asserted from edit scope:

- `representative` unapplied program: `representative.ak` UNEDITED this
  slice → expect byte-identical unapplied code old-vs-new blueprint
  (prove by comparing `extractCompiledCode "representative.representative"`
  bytes across the two blueprint store paths, recorded here).
- `representative` applied identity: MOVES (application hash moves — the
  name derivation lives in `application.ak` — so `applyBytesParam(appHash)`
  yields a new applied hash even with identical unapplied bytes). Report
  with application inputs `(appHash, repUnapplied)` measured.
- `application` unapplied+applied: moves (name derivation + guards).
- `state`: moves iff phase-3 `validModify` edits land in the same candidate
  (shared rebind rationale); `request` applied moves with state policy;
  unapplied request program unchanged (source unchanged).
- `retirement_custody`, `staking`: must NOT move — any movement stops the
  line and escalates.
