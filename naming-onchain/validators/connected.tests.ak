use aiken/collection/dict
use aiken/crypto.{blake2b_256}
use application.{Cancel, Maintain}
use cardano/assets.{add, from_lovelace, tokens, zero}
use cardano/transaction.{InlineDatum, Input, Mint, NoDatum, Output, OutputReference, Spend, Transaction}
use connected.{CancelApproval, FoldApproval, Insert, NativeRequest, NativeToken, Registration, Register, RequestDatum, Retract}
use fixtures
use naming

const request_hash = #"11111111111111111111111111111111111111111111111111111111"
const request_address = #"7011111111111111111111111111111111111111111111111111111111"

fn registration() -> Registration {
  let datum: Data = RequestDatum(NativeRequest {
    token: NativeToken { name: fixtures.mock_registry_token },
    owner: fixtures.controller, key: "cancel", operation: Insert(application.representative_name(fixtures.controller, naming.mpfs_state_hash, fixtures.mock_registry_token)),
    fee: 1000000, submitted_at: 0,
  })
  Registration {
    seed: fixtures.self_ref, registry_policy: naming.mpfs_state_hash,
    registry_token: fixtures.mock_registry_token, request_index: 0,
    request_address, request_datum: datum, refund: fixtures.refund_destination,
    naming_datum: fixtures.as_datum(fixtures.source_record()),
  }
}

fn claim(reg: Registration) -> Input {
  fixtures.claim_input(reg.naming_datum, add(from_lovelace(10000000), fixtures.app_policy, connected.insert_name(reg), 1))
}

fn request(reg: Registration) -> Input {
  let self = fixtures.self_ref
  Input {
    output_reference: OutputReference { transaction_id: self.transaction_id, output_index: 0 },
    output: Output { address: connected.decode_full_address(request_address), value: from_lovelace(3000000), datum: InlineDatum(reg.request_datum), reference_script: None },
  }
}

fn cancellation() -> Transaction {
  let reg = registration()
  let req = request(reg)
  let certificate_name = connected.withdrawal_name(reg, req.output_reference)
  let approval: Data = CancelApproval { registration: reg, issuer: fixtures.controller }
  let spend: Data = Cancel { presented_refund: reg.refund }
  let retract: Data = Retract(fixtures.state_ref)
  let refund = Output {
    address: connected.decode_full_address(reg.refund),
    value: add(from_lovelace(13000000), fixtures.app_policy, certificate_name, 1),
    datum: NoDatum, reference_script: None,
  }
  Transaction {
    ..fixtures.tx([claim(reg), req], [refund], [fixtures.controller],
      add(add(zero, fixtures.app_policy, connected.insert_name(reg), -1), fixtures.app_policy, certificate_name, 1),
      [Pair(Mint(fixtures.app_policy), approval), Pair(Spend(fixtures.self_ref), spend), Pair(Spend(req.output_reference), retract)]),
    reference_inputs: [fixtures.state_input()],
  }
}

test connected_registration_mints_bound_pair() {
  let reg = registration()
  let minted = Register { registration: reg, controller: fixtures.controller }
  let tx = Transaction {
    ..fixtures.tx([fixtures.claim_input(reg.naming_datum, from_lovelace(20000000))],
      [request(reg).output, claim(reg).output], [fixtures.controller],
      add(zero, fixtures.app_policy, connected.insert_name(reg), 1), []),
    reference_inputs: [fixtures.state_input()],
  }
  connected.connected.mint(request_hash, minted, fixtures.app_policy, tx)
}

test connected_cancellation_distinct_certificate_accepts() {
  let reg = registration()
  let tx = cancellation()
  connected.connected.mint(request_hash, CancelApproval { registration: reg, issuer: fixtures.controller }, fixtures.app_policy, tx)
    && connected.connected.spend(request_hash, Some(reg.naming_datum), Cancel { presented_refund: reg.refund }, fixtures.self_ref, tx)
}

test connected_insert_attestation_alone_refuses() fail {
  let reg = registration()
  let tx = cancellation()
  let only_insert: Data = FoldApproval { registration: reg }
  let tx = Transaction { ..tx, redeemers: [Pair(Mint(fixtures.app_policy), only_insert)] }
  connected.connected.spend(request_hash, Some(reg.naming_datum), Cancel { presented_refund: reg.refund }, fixtures.self_ref, tx)
}

test connected_missing_withdraw_issuer_refuses() fail {
  let tx = Transaction { ..cancellation(), extra_signatories: [] }
  connected.connected.mint(request_hash, CancelApproval { registration: registration(), issuer: fixtures.controller }, fixtures.app_policy, tx)
}

test connected_redirect_refuses() fail {
  let reg = registration()
  connected.connected.spend(request_hash, Some(reg.naming_datum), Cancel { presented_refund: fixtures.redirected_refund }, fixtures.self_ref, cancellation())
}

test connected_wrong_native_credential_refuses() fail {
  let reg = registration()
  connected.connected.spend(blake2b_256(request_hash), Some(reg.naming_datum), Cancel { presented_refund: reg.refund }, fixtures.self_ref, cancellation())
}

test connected_different_request_refuses() fail {
  let reg = registration()
  let wrong = Input { ..request(reg), output_reference: OutputReference { transaction_id: "another-request", output_index: 0 } }
  let tx = Transaction { ..cancellation(), inputs: [claim(reg), wrong] }
  connected.connected.spend(request_hash, Some(reg.naming_datum), Cancel { presented_refund: reg.refund }, fixtures.self_ref, tx)
}

test connected_pending_maintain_refuses() fail {
  let reg = registration()
  let tx = Transaction { ..cancellation(), mint: zero, outputs: [claim(reg).output], redeemers: [] }
  connected.connected.spend(request_hash, Some(reg.naming_datum), Maintain, fixtures.self_ref, tx)
}

test connected_withdraw_certificate_is_distinct() {
  let reg = registration()
  connected.withdrawal_name(reg, request(reg).output_reference) != connected.insert_name(reg)
    && dict.size(tokens(cancellation().mint, fixtures.app_policy)) == 2
}

test connected_active_maintain_accepts() {
  let source = fixtures.as_datum(fixtures.source_record())
  let maintained = fixtures.as_datum(fixtures.maintained_record())
  let value = add(fixtures.record_value, fixtures.rep_policy, "representative", 1)
  let tx = Transaction {
    ..fixtures.tx([fixtures.claim_input(source, value)],
      [fixtures.continuation_output(maintained, value)], [fixtures.controller], zero, []),
    reference_inputs: [fixtures.state_input()],
  }
  connected.connected.spend(request_hash, Some(source), Maintain, fixtures.self_ref, tx)
}

test connected_retirement_request_cancel_refuses() fail {
  let original = registration()
  expect RequestDatum(native): connected.NativeDatum = original.request_datum
  let updated: Data = RequestDatum(NativeRequest { ..native, operation: connected.Update("representative", "over") })
  let reg = Registration { ..original, request_datum: updated }
  let cert: Data = CancelApproval { registration: reg, issuer: fixtures.controller }
  let tx = Transaction { ..cancellation(), inputs: [claim(reg), request(reg)],
    redeemers: [Pair(Mint(fixtures.app_policy), cert)] }
  connected.connected.spend(request_hash, Some(reg.naming_datum), Cancel { presented_refund: reg.refund }, fixtures.self_ref, tx)
}
