use aiken/primitive/bytearray
use cardano/address
use cardano/assets.{add, from_lovelace, zero}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Spend, Transaction,
}
use cardano/transaction as tx_mod
use registry_pin.{registryStateHash}
use types.{Contribute, End, Modify, Rejected, State, StateDatum, UpdateRedeemer}
use witness as witness

// ============================================================================
// #173 A173-BOOT — the three witness policies at their new home
// ============================================================================
//
// `witness.ak` moved from `naming-onchain/validators/` to this partition
// (I2). Its decision table is unchanged and these rows are the proof of
// that: every kind needs the fold to MINT, only the terminal kind may
// burn without one, and a fold of somebody ELSE'S registry is not this
// instance's fold.
//
// The one thing that DID change is what the policy decodes: the
// registry's own `types.UpdateRedeemer`, not naming's structural mirror
// of it. These tests therefore build the REAL `Modify` redeemer, which
// is the whole point of the move — no naming module participates in a
// registry fold any more.

const registryToken: ByteArray = #"6d6f636b2d746f6b656e"

const foreignToken: ByteArray = #"666f726569676e2d746f6b656e"

const registryKey: ByteArray = #"616c696365"

/// The policy ids the instances of kinds 0 and 2 would have: no registry pins
/// them and the script admits nothing under them.
const unusedKindZeroPolicy: ByteArray =
  #"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"

const activePolicy: ByteArray =
  #"a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"

const unusedKindTwoPolicy: ByteArray =
  #"c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0"

const stateRef: OutputReference =
  OutputReference {
    transaction_id: #"73746174650000000000000000000000",
    output_index: 0,
  }

/// The full native asset identity of this registry's cage token — the
/// parameter every witness instance of THIS registry is bound to.
fn registryId() -> ByteArray {
  bytearray.concat(registryStateHash, registryToken)
}

/// The same shape bound to a DIFFERENT cage token: a real registry,
/// just not ours.
fn foreignRegistryId() -> ByteArray {
  bytearray.concat(registryStateHash, foreignToken)
}

fn pins() -> State {
  State {
    root: #"",
    tip: 1_000_000,
    process_time: 10_000,
    retract_time: 10_000,
    application_policy: #"a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9",
    active_policy: activePolicy,
  }
}

/// The registry's state input, at the pinned state script address,
/// carrying exactly one cage token under the state policy.
fn stateInput(token: ByteArray) -> Input {
  Input {
    output_reference: stateRef,
    output: Output {
      address: address.from_script(registryStateHash),
      value: add(from_lovelace(2_000_000), registryStateHash, token, 1),
      datum: InlineDatum(StateDatum(pins())),
      reference_script: None,
    },
  }
}

/// The REAL fold redeemer — `types.UpdateRedeemer`, not a mirror.
fn foldRedeemers() {
  let modify: Data = Modify([Rejected])
  [Pair(Spend(stateRef), modify)]
}

/// A spend of the registry state with a redeemer that is NOT a fold.
fn contributeRedeemers() {
  let other: Data = Contribute(stateRef)
  [Pair(Spend(stateRef), other)]
}

fn policyOf(kind: Int) -> ByteArray {
  if kind == 0 {
    unusedKindZeroPolicy
  } else if kind == 1 {
    activePolicy
  } else {
    unusedKindTwoPolicy
  }
}

/// The unit redeemer: this policy never reads it.
fn emptyRedeemer() -> Data {
  let r: Data = #""
  r
}

/// A movement under one witness policy, with or without the fold around
/// it.
fn moveWitness(kind: Int, quantity: Int, inFold: Bool) -> Bool {
  let policy = policyOf(kind)
  let redeemer: Data = #""
  witness.witness.mint(
    kind,
    registryId(),
    redeemer,
    policy,
    Transaction {
      ..tx_mod.placeholder,
      mint: add(zero, policy, registryKey, quantity),
      inputs: if inFold {
        [stateInput(registryToken)]
      } else {
        []
      },
      redeemers: if inFold {
        foldRedeemers()
      } else {
        []
      },
    },
  )
}

/// The active kind needs the fold to MINT; the accepting half is what keeps
/// the refusing half from passing vacuously.
test witness_active_mint_outside_a_fold_refuses() fail {
  moveWitness(1, 1, False)
}

test witness_active_mint_inside_a_fold_accepts() {
  moveWitness(1, 1, True)
}

test witness_active_pure_burn_still_needs_the_fold() fail {
  moveWitness(1, -1, False)
}

/// No other kind is admitted: not even inside a fold, for a mint or a burn.
test witness_kind_zero_mint_inside_a_fold_refuses() fail {
  moveWitness(0, 1, True)
}

test witness_kind_two_mint_inside_a_fold_refuses() fail {
  moveWitness(2, 1, True)
}

test witness_kind_zero_burn_inside_a_fold_refuses() fail {
  moveWitness(0, -1, True)
}

test witness_kind_two_burn_inside_a_fold_refuses() fail {
  moveWitness(2, -1, True)
}

/// A burn of kind two needs the fold too: nothing is exempt.
test witness_kind_two_pure_burn_without_a_fold_refuses() fail {
  moveWitness(2, -1, False)
}

/// The fold has to be OUR registry's fold. A real, well-formed fold of a
/// DIFFERENT registry leaves this instance refusing — this is the
/// control that `foldPresent` compares the parameter and does not merely
/// look for any `Modify` in the transaction.
test witness_another_registrys_fold_is_not_ours() fail {
  witness.witness.mint(
    1,
    foreignRegistryId(),
    emptyRedeemer(),
    activePolicy,
    Transaction {
      ..tx_mod.placeholder,
      mint: add(zero, activePolicy, registryKey, 1),
      inputs: [stateInput(registryToken)],
      redeemers: foldRedeemers(),
    },
  )
}

/// The registry state is spent, but NOT with a fold. `modifyActionCount`
/// returns -1 for every other redeemer, so co-presence fails.
test witness_state_spent_without_a_fold_refuses() fail {
  witness.witness.mint(
    1,
    registryId(),
    emptyRedeemer(),
    activePolicy,
    Transaction {
      ..tx_mod.placeholder,
      mint: add(zero, activePolicy, registryKey, 1),
      inputs: [stateInput(registryToken)],
      redeemers: contributeRedeemers(),
    },
  )
}

/// `End` is refused by the cage for every party, but this policy must
/// not accept it as a fold either: a second script deciding the same
/// thing differently is the disagreement the split exists to prevent.
test witness_end_redeemer_is_not_a_fold() fail {
  let ending: Data = End
  witness.witness.mint(
    1,
    registryId(),
    emptyRedeemer(),
    activePolicy,
    Transaction {
      ..tx_mod.placeholder,
      mint: add(zero, activePolicy, registryKey, 1),
      inputs: [stateInput(registryToken)],
      redeemers: [Pair(Spend(stateRef), ending)],
    },
  )
}
