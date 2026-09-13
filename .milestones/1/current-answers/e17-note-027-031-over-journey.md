# NOTE-027 through NOTE-031: connected Over journey with bound completion

Date: 2026-09-13. Seat: commit-owner-2 (same seat throughout).
Base: 954928c. This work is UNCOMMITTED at writing; intended as one
intermediate source commit on top of 954928c.

## What this delivers

A connected permanent-retirement journey on a genuinely claimed name
(`rt-over` via connected insert/fold, never seeded): controller
retire (queueing the pending Over-update request) → replay refusal →
pending readback (LO01) → withdrawal refusal (LT07 shape) → burn-only
refusal (N1) → permissionless completion (OV-complete: Modify folding
the retire's Update request with custody spend, exact burn, consumer
withdrawal) → Over readback (LO02) → reuse refusal with fresh-key
positive (LX01) → mismatched-pair refusal (N2). Plus the independent
reader verifying the completion from public evidence
(VERIFIED-COMPLETE), and unit tests pinning every new script clause.

## NOTE-027 (connected Over journey)

Rows live in `offchain/journey/retirement/Main.hs` (`runRows`, OV
section): `rowOVRetire` (controller route, asserts signers), 
`rowOVReplay` (phase-1 all-spent), `rowLO01` (custody-holds +
record-gone + mirror presence), `rowOVWithdrawRefused` (no burn →
phase-2 custody hash), `rowOVBurnOnlyRefused` N1 (burn without
transition → phase-2 custody hash), `rowOVComplete` (fresh completer,
empty required signers, exact burn field, root change, custody
consumed, no rep-carrying outputs), `rowLO02` (burn + gone +
still-occupied), `rowLX01` (queue lands, refold refused at build with
strict pins, fresh-key control registers), `rowN2Mismatch`
(LT01 custody + RR1 request refuses at build naming custody).

Preserved: six-field `consumer_pin`, empty-Modify refusal,
nonempty zero-net, scoped rejecting consumer (untouched), no
operator/payout-list (completer receives only tx change by
conservation — stated in-row, Q-002 for the signature criterion).

## NOTE-028 (completion must bind the registry transition)

Root finding (superseded design evidence preserved in
`retirement-exhibit-burnonly.log`): a burn-only completion
(custody spend + burn, no state) was accepted by all handlers. Fix:
the burn now rides a genuine registry transition —

- `retireTx` queues the pending Update request (old = rep name, new
  = Over marker) in the same route-authorized transaction that fills
  custody (uniform across all retires, new `spelling` param);
- completion is a connected `Modify` folding that request
  (`rowOVComplete` via `connectedFoldTx`: state spend, request fold,
  custody extra-spend, rep-burn mint, completer fee/payer, consumer
  hook automatic);
- `representative.ak` `BurnRepresentative` gains the custody-carried
  arm (permissionless burn off exactly one custody input; 4 new unit
  tests);
- `retirement_custody.ak` requires the spent state (is_registry_state
  shape).

Generous budgets for the grown retire/withdraw/burn-only builders
(`generousUnits`, NOTE-023 class — the added request output pushed
the app spend past `maxUnits`, observed as budget overspend and
raised with justification, not silently).

## NOTE-029 (Rejected+burn is not Over; co-creation)

Root finding (receipt `completion-rejected-root-control.json`):
burn-only refused, but Rejected-action + burn with preserved root
passed all five handlers. Fix, single-sited in the custody script
(census-clean: deleting any clause is caught by the rows/units
below; the mint authorizer stays NOTE-028-shape):

- burn exact (original, first — LT07 verdicts preserved);
- exactly one spent state input (confused batches refuse);
- exactly one co-created script input (the retire's pending request —
  none, foreign-txid, or several refuse);
- singleton `Modify` (with the root change, exactly one genuine
  `UpdateAction` — batches and non-Modify refuse);
- root genuinely changes outputs[0] vs spent input (Rejected-preserved
  refuses).

`naming.ak`: `mpfs_state_root`, `MirrorRedeemer` (exact 5-variant
wire mirror), `modify_action_count`, `mpfs_state_datum_with_root`.
Ledger rows: N1 (absent-transition, submit refusal naming custody),
N2 (mismatched LT01-custody/RR1-request, build EvalFailure naming
custody at the custody spend). Units pin each clause (rejected-root,
multi-action, non-modify, foreign/missing request).

Kept per the note: legitimate rejected/mixed/zero-net processing
(untouched generic paths), separate unspent custodys (LT01/LT02/RR —
the reader reports COMPLETION-ABSENT custody-intact for all four).

## NOTE-031 (co-creation is not Over-binding)

Source review finding: co-creation checks presence, not content
(any co-created script output; root change anywhere). Fix
(executing layer, naming-only — no generic `onchain/` change, no ABI
change):

- Over marker now commits to the held asset
  (`over_marker_for` = `"over" || rep`, Aiken + Haskell single
  sources `naming.over_marker_for` / `Naming.Register.overMarkerFor`;
  retire writes it, rows/reader corroborate);
- custody decodes the co-created input as a request datum (exact
  `MRequest`/`MOperation`/`MTokenId` mirrors, cross-checked against
  `consumer.ak` mirrors field-for-field) and requires: request token
  == the state's cage token (no cross-cage confusion), operation is
  `Update(old, new)` with `old == held` (this key's current value)
  and `new == over_marker_for(held)` (this asset's Over marker).
- Units pin datum/token/shape/old/new substitutions (6 new tests);
  N2 already substitutes the relationship at ledger level (wrong
  pair, each piece genuine).

Fundamental limit, stated not waived: key-equality against the true
spelling is unknowable on-ledger (the spelling is committed nowhere
except the trie key itself and the consumed insert request). What
binds the key structurally: the pending request is created by the
route-authorized retire in the same transaction as the custody fill,
and the completer must fold exactly that creator's request
(co-creation). A malicious route party could retire a wrong key, but
that griefs only its own name (route parties are trusted for their
own names — retirement itself trusts them). No ABI change is
necessary; none made. If the owner wants spelling-equality on
ledger, that is a NamingDatum ABI change for a Q-file, not this
slice.

## NOTE-030 (claim bounds)

- LT04 wording: rows/reader say exactly what holds (required
  signers empty; fee/collateral witnessed by one fresh key outside
  every route; no controller/quorum approval) — never "zero
  signatures". Q-002 FILED with run evidence, proceeding under the
  narrow reading (fee-ownership witness is conservation mechanics;
  Lean's witness is nativeSpend+representativeMint, unchanged).
- LX01 attribution: shared strict parser `pinEvalRefusal` (named
  `pwcScriptHash`/`The script hash is:` field equality — bare hex
  never counts; anti-budget `overspending the budget` fails the row;
  purpose presence; EvalFailure required). N2 uses the same parser
  (custody field + ConwaySpending). LX01-control threading into
  control modes is NOT done (control runs lack Over state; the eval
  machinery is controlled by strict pins + the fresh-key eval-success
  in-band + wrongReasonMode on every submit path) — named remainder
  bound, not silently waived.

## Reader honesty (NOTE-027 fixes, verified in run)

- `recoverContinuation` is purpose-bound (`recoverBoundTo`: strict
  Constr-4 marker at the `ConwaySpending (AsIx n)` purpose resolving
  to the record; the untagged scan is deleted).
- `reStatePolicy` renamed + documented: the name formula uses the
  STATE policy (preimage rule); the DERIVED mint policy binds custody
  and creation mint; they meet only in the creation-mint clause.
  Spec embodies the distinction (policyS ≠ policyR).
- `verifyCompletionTx`: co-created pair (creator txids equal),
  custody triple == verified pair, mint exactly the burn with burn
  redeemer shape, singleton-`Modify` with changed root, folded
  Update moves burned → its Over marker (value proof the mirror
  cannot give), required signers empty, witnesses == exactly the
  fee-input owner outside every route. Refused probes sharing the
  custody input are excluded via accepted-txids (they spend without
  consuming). `CompleteVerifySpec`: 18 tests.

## Toolchain findings (for the record)

- Aiken v1.1.21 reports some compile errors as SILENT exit 1 when
  piped (no TTY): unimported constructors/types (`InlineDatum`,
  `Pair`, `B`), unused imports. Workaround used throughout:
  `script -qec 'aiken check' /dev/null` renders diagnostics.
  (No upstream report — out of scope.)
- `when <Data> is { Constr{...} }` (user-side Data-constructor
  matching) silently kills the same compiler; framework
  deserialization (`expect Mirror(...) = data`, `if x is Pat: Type`,
  typed `expect` patterns) is safe and used everywhere. The burn
  design avoids Data matching entirely (custody-first `if`, legacy
  retire path verbatim).
- Mirror value assertions are impossible: `Trie.lookup` (Pure
  backend) echoes the KEY hash for present keys and cannot return
  stored values. Rows assert presence (+mirror↔chain root equality);
  the VALUE proof (request datum newVal) lives in the reader. No
  generic-lib change made (out of scope); behavior documented here.
- Shared rep name per run: global rep-absence is unassertable while
  other records/custodys legitimately hold the same bytes. Rows
  assert scoped facts (record gone, custody consumed, completion
  outputs rep-free, mirror presence, replay refused) and state
  exactly what "no live resolution" is checked against.

## Applied identities (final, from this run's logs)

- app `721850316d379fdf54717466494b15346d3dea89d027598900a45a37`
  (const-bumped custody hash)
- rep `f600a642fef5ce9c2df0f1a88c962bf2fb2dd52a9441470d11687fe5`
- custody `4f586dcc5ddcebe58e9aff11ae8a3778891ffcaf3716232829bc0432`
- state `3f62792585903776fc69059588783c7ca67ee9d24886c8722ebf8b2a`,
  consumer `e61455043f0ba3177e9fd8d4b873b7b59fdea15de167ea29a0097b26`
  (unmoved), completion `d970f418ace6ccc6b94909029fc8c9f11f198027daa178c1a706ba891975b0aa
  (derived from the run — see log/reader lines, not retyped here
  beyond this table; NOTE-027's no-copy rule is met by row/reader
  narration emitting full hex from bytes).

## Evidence matrix (final code, blueprint a3hmhwxc0)

- retirement (OV journey): GREEN exit 0 (`retirement-exhibit.log`,
  138 lines: LT/RR/N2/OV/LO/LX/N1 rows + complete).
- reader: 5 VERIFIED + 4 COMPLETION-ABSENT + 1 VERIFIED-COMPLETE
  (`reader-run-over2.log`).
- register / recovery / journey 11/11 / e2e 5/5: GREEN
  (re-exhibited on final code).
- cage-tests 93/0; aiken naming 122 checks, 0 errors.
- Superseded/failed exhibits preserved (burnonly, budget, n2,
  lo01, lo02, ovcomplete logs + dirs).

## Remainder (mechanical)

1. LX01/N2 eval-branch threading into control modes (bound above).
2. Q-002 ruling pending (proceeding under narrow reading).
3. Final tuple publish (owner decision; out of slice scope).
4. `#81` lone_fork unit (other lane; preserved failure).
