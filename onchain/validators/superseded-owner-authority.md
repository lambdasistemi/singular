# Superseded owner-authority tests (operator ruling NOTE-028/A-003)

These tests asserted registry-owner authority and were removed or recut by
the issue #77 ownerless repair. They are kept here verbatim as defect
witnesses: this is what the pre-repair tree accepted. Do not reintroduce
them; their replacements are named below.

RED subject for the repair (NOTE-008 correction): behavioural RED is
constructible and was reproduced on the known base by root — a 70-line
test-only patch (sha256
`b499e18577d97ab77e4b0f20d4501d6bce34a9d97cb9b174c9a42acfb596d2c5`)
adding four refusal tests under fresh names reusing the exact bodies of
`end_happy`, `canMigrate`, `sweep_no_datum` plus a `Burning` case gives
a real exit 1 with `Summary 1417 checks, 4 errors` (failures exactly
`root_ownerless_{end,migration,sweep,burning}_refuses`), retained at
`/tmp/singular-ownerless-red-m02svz71/`. (An earlier claim that only a
compile failure could serve as RED was wrong and is withdrawn: that
patch rewrote shared fixtures to the new representation, which cannot
compile against the old schema — it showed the patch/schema mismatch,
not untestability. The obligation is representation-bound per version.)
The repaired-schema counterparts live in `cage.tests.ak`
(`end_owner_signed_refuses`, `migrating_owner_signed_refuses`,
`burning_token_refuses`, `sweep_owner_signed_refuses`) with fresh GREEN
plus ledger-boundary proof (submitted refusals with success controls).

---

## 1. Deleted: modify_with_stake_script_withdrawal

Asserted a staking-script withdrawal authorized Modify. The stake hook
is gone with the owner role; no replacement (Modify needs no hook).

```aiken
/// A cage configured with a staking script can be modified by any submitter
/// when the transaction withdraws through that script credential.
test modify_with_stake_script_withdrawal() {
  let stake_state = State { ..state, stake_script: Some(testStakeScript) }
  let stake_input =
    Input {
      output_reference: testStateRef,
      output: Output {
        address: testScriptAddress,
        value: testValue,
        datum: InlineDatum(StateDatum(stake_state)),
        reference_script: None,
      },
    }
  let stake_output =
    Output {
      ..output,
      datum: InlineDatum(
        StateDatum(
          State {
            ..stake_state,
            owner: "new-owner",
            stake_script: Some(testStakeScript),
            root: #"484dee386bcb51e285896271048baf6ea4396b2ee95be6fd29a92a0eeb8462ea",
          },
        ),
      ),
    }
  spend(
    Some(StateDatum(stake_state)),
    Modify([UpdateAction([])]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [stake_output],
      extra_signatories: ["owner"],
      withdrawals: [Pair(address.Script(testStakeScript), 1)],
      inputs: [stake_input, request],
    },
  )
}
```

## 2. Deleted: modify_ignores_stake_script_hook

Asserted Modify ignores the stake hook (still true) via a stake-bearing
state (no longer expressible). Covered by modify_without_owner_succeeds.

```aiken
/// Modify ignores the stake-script hook (re-cut under issue #79; was
/// `modify_with_stake_script_no_withdrawal`, which required a refusal
/// when the withdrawal was absent). The repaired `Modify` path never
/// consults `validateOwnership` — neither the owner nor the stake-script
/// withdrawal — so this transaction is accepted. That is the current
/// Aiken-level meaning of the hook on `Modify`, not a ruling on its
/// ledger reachability: epic 18 found the stake credential may be
/// unreachable on a ledger (`staking.ak` serves only `withdraw`), an
/// open question owned by a separate slice sequenced after this one.
/// Do not read this test as approval to add a stake or owner
/// prerequisite back to permissionless `Modify`.
test modify_ignores_stake_script_hook() {
  let stake_state = State { ..state, stake_script: Some(testStakeScript) }
  let stake_input =
    Input {
      output_reference: testStateRef,
      output: Output {
        address: testScriptAddress,
        value: testValue,
        datum: InlineDatum(StateDatum(stake_state)),
        reference_script: None,
      },
    }
  let stake_output =
    Output {
      ..output,
      datum: InlineDatum(
        StateDatum(
          State {
            ..stake_state,
            owner: "new-owner",
            stake_script: Some(testStakeScript),
            root: #"484dee386bcb51e285896271048baf6ea4396b2ee95be6fd29a92a0eeb8462ea",
          },
        ),
      ),
    }
  spend(
    Some(StateDatum(stake_state)),
    Modify([UpdateAction([])]),
    testStateRef,
    Transaction {
      ..transaction.placeholder,
      validity_range: phase1Range,
      outputs: [stake_output],
      extra_signatories: ["owner"],
      inputs: [stake_input, request],
    },
  )
}
```

## 3. Deleted: migrate_changes_owner

Asserted migration refuses an owner-changing output. Migration now
refuses wholesale (migrating_owner_signed_refuses); owner-specific
coverage is subsumed.

```aiken
/// FR4: the migrated output must preserve every field of the predecessor
/// `State`. Changing `owner` is exactly the exploit's forged-ownership move.
test migrate_changes_owner() fail {
  let bad_output =
    Output {
      ..migrate_output,
      datum: InlineDatum(
        StateDatum(State { ..migrate_predecessor_state, owner: "attacker" }),
      ),
    }
  mint(
    Migrating(migrate_redeemer),
    new_policy,
    Transaction {
      ..transaction.placeholder,
      extra_signatories: ["owner"],
      inputs: [migrate_predecessor_input],
      outputs: [bad_output],
      mint: migrate_mint,
    },
  )
}
```

## 4. Recut in place (same shape, verdict inverted to refusal)

- end_happy -> end_owner_signed_refuses
- end_with_stake_script -> end_stake_withdrawal_refuses
- canMigrate -> migrating_owner_signed_refuses
- sweep_no_datum -> sweep_owner_signed_refuses
- sweep_wrong_token_request, sweep_fake_state_no_nft,
  sweep_alongside_modify, end_with_extra_mint_policy,
  sweep_mismatched_tip_request, sweep_underfunded_matching_request:
  kept names, added refusal annotation
- end_with_stake_script_no_withdrawal ->
  end_owner_signed_no_withdrawal_refuses

## 5. Added (no predecessor)

- burning_token_refuses (the mint-purpose burn had no test)
- end_owner_signed_no_withdrawal_refuses, end_stake_withdrawal_refuses,
  migrating_owner_signed_refuses, sweep_owner_signed_refuses (recuts)
