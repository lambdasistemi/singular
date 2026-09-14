use aiken/builtin.{serialise_data}
use aiken/collection/dict
use aiken/collection/list.{all, concat, filter, find, has}
use aiken/collection/pairs
use aiken/crypto.{blake2b_256}
use aiken/primitive/bytearray
use application.{ApplicationRedeemer, Cancel, Fold, Maintain, Recover, Retire}
use cardano/address.{Address, Inline, Script, VerificationKey}
use cardano/assets.{add, lovelace_of, quantity_of, tokens, zero}
use cardano/transaction.{InlineDatum, Input, Mint, Output, OutputReference, Spend, Transaction}
use naming

/// Witness for the immutable proposal represented jointly by the two outputs.
pub type Registration {
  Registration {
    seed: OutputReference,
    registry_policy: ByteArray,
    registry_token: ByteArray,
    request_index: Int,
    request_address: ByteArray,
    request_datum: Data,
    refund: ByteArray,
    naming_datum: Data,
  }
}

pub type CertificateRedeemer {
  Register { registration: Registration, controller: ByteArray }
  FoldApproval { registration: Registration }
  CancelApproval { registration: Registration, issuer: ByteArray }
}

// The existing native request encoding, without inventing a refund field.
pub type NativeToken { NativeToken { name: ByteArray } }
pub type NativeOperation { Insert(ByteArray) Delete(ByteArray) Update(ByteArray, ByteArray) }
pub type NativeRequest {
  NativeRequest {
    token: NativeToken, owner: ByteArray, key: ByteArray,
    operation: NativeOperation, fee: Int, submitted_at: Int,
  }
}
pub type NativeDatum { RequestDatum(NativeRequest) }
pub type NativeSpend {
  End
  Contribute(OutputReference)
  Modify(Data)
  Retract(OutputReference)
}

type InsertCommitment { InsertCommitment { domain: ByteArray, registration: Registration } }
type WithdrawalCommitment {
  WithdrawalCommitment {
    domain: ByteArray, registry_policy: ByteArray, registry_token: ByteArray,
    request: OutputReference, refund: ByteArray,
  }
}

pub fn insert_name(registration: Registration) -> ByteArray {
  let data: Data = InsertCommitment {
    domain: "singular/naming/connected-insert/v1", registration,
  }
  blake2b_256(serialise_data(data))
}

pub fn withdrawal_name(registration: Registration, request: OutputReference) -> ByteArray {
  let data: Data = WithdrawalCommitment {
    domain: "singular/naming/connected-withdraw/v1",
    registry_policy: registration.registry_policy,
    registry_token: registration.registry_token,
    request, refund: registration.refund,
  }
  blake2b_256(serialise_data(data))
}

/// Address comparison includes the stake credential; the ledger checks network.
pub fn decode_full_address(bytes: ByteArray) -> Address {
  expect naming.canonical_address(bytes)
  let kind = bytearray.at(bytes, 0) / 16
  let payment = naming.payment_credential(bytes)
  let stake = if kind == 6 || kind == 7 {
    None
  } else {
    let digest = bytearray.slice(bytes, 29, 56)
    Some(Inline(if kind < 2 { VerificationKey(digest) } else { Script(digest) }))
  }
  Address { payment_credential: payment, stake_credential: stake }
}

fn state_input(registration: Registration, tx: Transaction) -> Input {
  expect registration.registry_policy == naming.mpfs_state_hash
  expect Some(state) = find(concat(tx.inputs, tx.reference_inputs), fn(input) {
    input.output.address.payment_credential == Script(registration.registry_policy)
      && dict.to_pairs(tokens(input.output.value, registration.registry_policy)) == [Pair(registration.registry_token, 1)]
  })
  state
}

fn native_request(registration: Registration) -> NativeRequest {
  expect RequestDatum(request): NativeDatum = registration.request_datum
  expect request.token.name == registration.registry_token
  expect Insert(_) = request.operation
  request
}

fn at_output(outputs: List<Output>, index: Int) -> Output {
  expect index >= 0
  when outputs is {
    [] -> fail
    [output, ..rest] -> if index == 0 { output } else { at_output(rest, index - 1) }
  }
}

fn claim_for(policy: ByteArray, registration: Registration, tx: Transaction) -> Input {
  expect [claim] = filter(tx.inputs, fn(input) {
    input.output.address.payment_credential == Script(policy)
      && quantity_of(input.output.value, policy, insert_name(registration)) == 1
  })
  expect claim.output.datum == InlineDatum(registration.naming_datum)
  claim
}

fn request_for(native_hash: ByteArray, registration: Registration, claim: Input, tx: Transaction) -> Input {
  let expected = OutputReference {
    transaction_id: claim.output_reference.transaction_id,
    output_index: registration.request_index,
  }
  expect Some(request) = find(tx.inputs, fn(input) { input.output_reference == expected })
  expect request.output.address == decode_full_address(registration.request_address)
  expect request.output.address.payment_credential == Script(native_hash)
  expect request.output.datum == InlineDatum(registration.request_datum)
  expect native_request(registration).token.name == registration.registry_token
  request
}

fn native_redeemer(request: Input, tx: Transaction) -> NativeSpend {
  expect Some(data) = pairs.get_first(tx.redeemers, Spend(request.output_reference))
  expect action: NativeSpend = data
  action
}

fn certificate(policy: ByteArray, tx: Transaction) -> CertificateRedeemer {
  expect Some(data) = pairs.get_first(tx.redeemers, Mint(policy))
  expect result: CertificateRedeemer = data
  result
}

fn continuation(policy: ByteArray, tx: Transaction) -> List<Output> {
  filter(tx.outputs, fn(output) { output.address.payment_credential == Script(policy) })
}

fn representative_policy(state: Input) -> ByteArray {
  expect InlineDatum(data) = state.output.datum
  naming.mpfs_state_policy(data)
}

fn active_custody(claim: Input, tx: Transaction) -> Bool {
  expect Some(state) = find(concat(tx.inputs, tx.reference_inputs), fn(input) {
    input.output.address.payment_credential == Script(naming.mpfs_state_hash)
      && when dict.to_pairs(tokens(input.output.value, naming.mpfs_state_hash)) is {
        [Pair(_, 1)] -> True
        _ -> False
      }
  })
  let policy = representative_policy(state)
  expect [Pair(_, 1)] = dict.to_pairs(tokens(claim.output.value, policy))
  True
}

validator connected(native_request_hash: ByteArray) {
  spend(datum: Option<Data>, action: ApplicationRedeemer, self: OutputReference, tx: Transaction) {
    expect Some(claim) = find(tx.inputs, fn(input) { input.output_reference == self })
    expect Script(policy) = claim.output.address.payment_credential
    when action is {
      Cancel { presented_refund } -> {
        expect CancelApproval { registration, issuer: _ } = certificate(policy, tx)
        expect claim_for(policy, registration, tx) == claim
        expect presented_refund == registration.refund
        let request = request_for(native_request_hash, registration, claim, tx)
        let state = state_input(registration, tx)
        expect Retract(state.output_reference) == native_redeemer(request, tx)
        expect !has(tx.inputs, state)
        expect continuation(policy, tx) == []
        let refund_address = decode_full_address(registration.refund)
        let withdrawal = withdrawal_name(registration, request.output_reference)
        expect [refund] = filter(tx.outputs, fn(output) {
          quantity_of(output.value, policy, withdrawal) == 1
        })
        expect refund.address == refund_address
        expect lovelace_of(refund.value) >= lovelace_of(claim.output.value) + lovelace_of(request.output.value) - tx.fee
        expect dict.is_empty(tokens(tx.mint, representative_policy(state)))
        True
      }
      Fold { representatives } -> {
        expect FoldApproval { registration } = certificate(policy, tx)
        expect claim_for(policy, registration, tx) == claim
        let request = request_for(native_request_hash, registration, claim, tx)
        let state = state_input(registration, tx)
        expect has(tx.inputs, state)
        expect Contribute(state.output_reference) == native_redeemer(request, tx)
        let native = native_request(registration)
        expect Insert(name) = native.operation
        expect name == application.representative_name(native.key)
        expect representatives == [name]
        let rep_policy = representative_policy(state)
        expect dict.to_pairs(tokens(tx.mint, rep_policy)) == [Pair(name, 1)]
        expect [output] = continuation(policy, tx)
        expect output.datum == InlineDatum(registration.naming_datum)
        expect output.value == add(add(claim.output.value, policy, insert_name(registration), -1), rep_policy, name, 1)
        True
      }
      Maintain | Recover { .. } | Retire { .. } -> {
        expect active_custody(claim, tx)
        expect Some(data) = datum
        application.active_transition(naming.expect_naming(data), action, claim, policy, tx)
      }
    }
  }

  mint(action: CertificateRedeemer, policy: ByteArray, tx: Transaction) {
    when action is {
      Register { registration, controller } -> {
        expect has(tx.extra_signatories, controller)
        expect Some(_) = find(tx.inputs, fn(input) { input.output_reference == registration.seed })
        let state = state_input(registration, tx)
        expect !has(tx.inputs, state)
        expect naming.well_formed(naming.expect_naming(registration.naming_datum))
        expect naming.canonical_address(registration.refund)
        let request = at_output(tx.outputs, registration.request_index)
        expect request.address == decode_full_address(registration.request_address)
        expect request.address.payment_credential == Script(native_request_hash)
        expect request.datum == InlineDatum(registration.request_datum)
        let native = native_request(registration)
        expect Insert(name) = native.operation
        expect name == application.representative_name(native.key)
        expect dict.to_pairs(tokens(tx.mint, policy)) == [Pair(insert_name(registration), 1)]
        expect [claim] = continuation(policy, tx)
        expect claim.datum == InlineDatum(registration.naming_datum)
        expect claim.value == add(add(zero, policy, insert_name(registration), 1), #"", #"", lovelace_of(claim.value))
        True
      }
      FoldApproval { registration } -> {
        let claim = claim_for(policy, registration, tx)
        expect Some(data) = pairs.get_first(tx.redeemers, Spend(claim.output_reference))
        expect Fold { .. }: ApplicationRedeemer = data
        expect dict.to_pairs(tokens(tx.mint, policy)) == [Pair(insert_name(registration), -1)]
        True
      }
      CancelApproval { registration, issuer } -> {
        // The distinct withdrawal approval has the same issuance rule as
        // WithdrawApproval +1: the expressly named issuer must sign.
        expect has(tx.extra_signatories, issuer)
        let claim = claim_for(policy, registration, tx)
        let request = request_for(native_request_hash, registration, claim, tx)
        expect Some(data) = pairs.get_first(tx.redeemers, Spend(claim.output_reference))
        expect Cancel { presented_refund }: ApplicationRedeemer = data
        expect presented_refund == registration.refund
        let withdrawal = withdrawal_name(registration, request.output_reference)
        expect tx.mint |> tokens(_, policy) |> dict.to_pairs |> all(_, fn(pair) {
          pair == Pair(insert_name(registration), -1) || pair == Pair(withdrawal, 1)
        })
        expect quantity_of(tx.mint, policy, insert_name(registration)) == -1
        expect quantity_of(tx.mint, policy, withdrawal) == 1
        True
      }
    }
  }
  else(_) { fail }
}
