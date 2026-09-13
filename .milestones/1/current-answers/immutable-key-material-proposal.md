# Proposal: immutable key material for the registry-bound name (NOTE-010, before freezing)

## Proposed material

**Creation-time control payment hash (28 bytes)** — `naming.control_hash` evaluated
on the claim/record datum **at the insert fold**, i.e. the exact value the existing
name equation already embeds. At fold time the record's control IS the creation
control (rotation happens only later via `recoverController`), so the fold path
needs no new input; at retire time it arrives via a new `Retire.key_hash`
redeemer field and is checked by recomputation-equality against the stored token
name (an authentic commitment minted at creation).

## Model basis (accepted Lean, no change)

- `Representative` fields are immutable for the token's life. `NamingLifecycle`:
  `replaceLifecycleOutput` (`NamingLifecycle.lean:111`) rebuilds records as
  `{ record with outputId := successor, fixture := fixture }` — `key` and
  `representative` preserved, filtered by `record.key`;
  `recoverController` (`:142`) throws `recovery-representative` unless the
  candidate representative equals `record.representative`, carries `key :=
  record.key` forward, while installing the revealed control (controller
  rotation with identity preserved);
  `beginRetirement` (`:180`) proceeds on the same looked-up record, key and
  representative via controller or fixed-quorum authorization.
- The existing concrete derivation already embeds the creation control hash
  (fold-time `control_hash(record)`); the defect is only that retire
  recomputes over the possibly-rotated current control. Nothing about the
  creation side changes meaning — only retire learns to take the immutable
  value explicitly.

## Byte consequences (exact)

- Preimage third range stays 28 bytes with identical widths: `policy[28] ‖
  token[var] ‖ creation_key_hash[28]`; name stays 32 bytes
  (`Rep ‖ b224 ‖ 0x00`). No width, length-prefix, or CBOR change from the
  `byte-contract.md` spec — only the semantic source of the third range is
  pinned to creation time.
- Fold: byte-identical behavior to what is already implemented and unit-green
  (record control at fold time *is* creation control). No fold code change.
- Retire: `ApplicationRedeemer.Retire` gains `key_hash : ByteArray` (28).
  Redeemer stays `Constr 3`, fields `[representatives, key_hash]` in that
  order (list first, hash second — mirrors `Recover { revealed_control,
  representatives, registry }` field-after-list habit, and keeps names
  adjacent to their existing position). Haskell `redeemerRetire` gains the
  hash arg; tests add it to every `Retire` construction (currently 8 sites);
  runners thread it (`retireTx` from the setup `KeySetup`, whose
  `keyControllerHash` never rotates — recovery builds separate datum helpers
  and never mutates setups).
- Fresh-claim flows are byte-unaffected (creation == current, same preimage);
  post-recovery retires change from refused (wrong) to accepted iff the
  supplied creation hash is right; copied-policy rival still refused (token
  mismatch dominates regardless of supplied key).

## Alternatives considered and rejected (with reason, not preference)

- Spelling bytes: model-pure (`record.key` derives from spelling at queue),
  but unavailable on chain at retire (record carries no spelling; retire
  carries no MPFS request), so it needs redeemer supply anyway — with the
  extra burden of the already-reported external spelling↔key residue. Worse
  basis, same plumbing.
- Full creation address (57 bytes): breaks fixed widths, the hash-based
  decode shape (`decode_address` → 28-byte payment hash), and every
  preimage/field layout already specified. No model basis for preferring it.
- Current control (status quo ante): breaks the required
  claim→recover→retire journey — the finding itself. Rejected.

## Decision needed before freezing

Confirm creation-control-hash plus `Retire.key_hash`-at-retire (fold path
untouched), or direct otherwise. Until then the carrier is NOT frozen: no
commit contains retire-side consumers beyond the current Aiken unit tests
(which never rotate, so creation == current in every one of them — they pass
identically under both readings and prove nothing about this choice either
way, stated so they are not misread as evidence for it).
