//// Registry rows that stand beside the tagged fold: the pure edge deltas and
//// approval names, the retraction of legacy requests, and the carried-datum
//// hash. The fold rows of this file are retired with the legacy edge-only
//// request (CP2); their tagged counterparts are in `tagged_fold.tests.ak`.
////
//// Old to new map of the retired rows:
////
//// - `insert_active_accepts`, `update_active_to_terminal_accepts`,
////   `insert_active_with_approval_accepts`,
////   `update_terminal_with_approval_accepts`, `bound_approval_accepts`,
////   `exactly_one_active_token_accepts`, `key_named_token_accepts`,
////   `named_output_accepts`, `funded_request_accepts`: the valid tagged folds
////   (`tagged_fold_state_folds_*`);
//// - `all_seven_preserved_accepts` and the ten `altered_*_refuses` rows: the
////   same valid fold with one pin changed (`tagged_fold_pins_*`);
//// - `*_delta_off_refuses`, `two_active_tokens_for_one_key_refuses`,
////   `active_token_for_another_key_refuses`, `absent_mint_on_active_leaf_refuses`,
////   `stray_terminal_mint_refuses`, `token_named_other_than_the_key_refuses`:
////   the singular mint and burn rows of the tagged fold (`fold-singular-mismatch`,
////   `fold-foreign-asset`);
//// - `active_token_at_another_address_refuses`,
////   `active_token_with_another_datum_refuses`,
////   `active_token_in_two_outputs_refuses`,
////   `destination_carrying_the_residual_accepts`,
////   `folder_keeping_the_residual_refuses`, `underfunded_destination_refuses`,
////   `carrier_at_another_address_refuses`, `funded_carrier_has_no_refusal`: the
////   carrier rows (`fold-destination-mismatch`, `destination-carrier-mismatch`)
////   and the gross allocation rows (`fold-unbalanced`, the funded fee);
//// - the four carried-datum rows (`active_token_with_the_carried_datum_accepts`,
////   `active_token_with_another_than_the_carried_datum_refuses`,
////   `active_token_with_a_datum_where_none_is_carried_refuses`,
////   `active_token_without_the_carried_datum_refuses`): the registration that
////   carries a datum in `tagged_fold.tests.ak`
////   (`tagged_fold_state_folds_a_registration_carrying_a_datum`,
////   `tagged_fold_request_spend_contributes_a_registration_carrying_a_datum`,
////   `tagged_fold_registration_refuses_a_carried_datum_delivered_as_another_datum`,
////   `tagged_fold_registration_refuses_a_carried_datum_delivered_with_none`) and,
////   for a request that carries none,
////   `tagged_fold_registration_refuses_a_carrier_with_another_datum`;
//// - the approval rows (`*_without_approval_refuses`, `wrong_*_approval_refuses`,
////   `foreign_policy_approval_refuses`) and `request_below_its_tip_refuses`,
////   `an_unadmitted_tag_never_walks_the_trie`: retired with the approval
////   admission of the old fold; a member is authenticated by the tags its
////   booking minted (`request-observation-mismatch`, `fold-unrecognized-input`,
////   `registration_booking.tests.ak`, `termination_booking.tests.ak`);
//// - `zero_consumed_requests_refuses`: `tagged_fold_preserved_refuses_a_fold_with_no_member`.

use aiken/collection/list
use aiken/fuzz
use cardano/assets.{from_lovelace, zero}
use cardano/transaction.{InlineDatum, Output, Spend, Transaction}
use lib
use registry_fixtures as fx
use request
use types

test prop_delta_reads_off_the_edge(edge via fuzz.int_between(-2, 9)) {
  let delta = lib.deltaOf(edge)
  let admitted = edge == 1 || edge == 3
  and {
    list.length(delta) <= 2,
    list.all(
      delta,
      fn(entry) {
        let (kind, quantity) = entry
        ( quantity == 1 || quantity == -1 ) && kind >= 0 && kind <= 2
      },
    ),
    if admitted {
      delta != []
    } else {
      delta == []
    },
  }
}

test prop_approval_name_binds_the_key(
  pair via fuzz.tuple(
    fuzz.bytearray_between(1, 8),
    fuzz.bytearray_between(1, 8),
  ),
) {
  let (left, right) = pair
  let nameOf =
    fn(key) {
      lib.approvalName(
        1,
        key,
        fx.bookerKey,
        lib.approvalDestination(fx.bookingDestination()),
      )
    }
  if left == right {
    nameOf(left) == nameOf(right)
  } else {
    nameOf(left) != nameOf(right)
  }
}

fn retract(edge: Int, signer: ByteArray) -> Bool {
  let root = fx.oneLeaf(fx.keyA, fx.terminalLeaf)
  let redeemer: Data = types.Retract(fx.stateRef)
  request.request.spend(
    fx.cagePolicy,
    fx.cageTokenName(),
    Some(fx.requestDatum(fx.keyA, edge, fx.bookerKey, fx.readDestination())),
    types.Retract(fx.stateRef),
    fx.requestRef(0),
    Transaction {
      ..transaction.placeholder,
      validity_range: fx.phase2(),
      extra_signatories: [signer],
      redeemers: [Pair(Spend(fx.requestRef(0)), redeemer)],
      outputs: [
        Output {
          address: fx.addressOf(fx.bookerAddress),
          value: from_lovelace(fx.requestLovelace),
          datum: InlineDatum(fx.requestRef(0)),
          reference_script: None,
        },
      ],
      reference_inputs: [fx.stateInput(root)],
      inputs: [
        fx.requestInput(
          0,
          fx.keyA,
          edge,
          fx.bookerKey,
          fx.readDestination(),
          zero,
          fx.requestLovelace,
        ),
      ],
    },
  )
}

test read_retracted_by_its_owner_accepts() {
  retract(6, fx.bookerKey)
}

test read_retracted_by_a_stranger_refuses() fail {
  retract(6, fx.inserterKey)
}

test update_retract_refuses() fail {
  retract(3, fx.bookerKey)
}

test carried_datum_hash_is_the_named_hash() {
  and {
    lib.destinationDatumHash(Some(fx.recordDatum())) == fx.datumHashOf(
      fx.recordDatum(),
    ),
    lib.destinationDatumHash(None) == #"",
  }
}
