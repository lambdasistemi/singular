use aiken/collection/list
use aiken/collection/list.{find, foldl, head}
use aiken/crypto.{VerificationKeyHash}
use aiken/merkle_patricia_forestry.{MerklePatriciaForestry, empty, root}
use aiken/merkle_patricia_forestry as mpf
use aiken/option.{is_some}
use cardano/address
use cardano/assets
use cardano/assets.{PolicyId, lovelace_of}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, find_input,
}
use lib.{assetName, exactQuantity, tokenFromPolicy}
use shared.{in_phase1, is_rejectable}
use types.{
  Burning, CageDatum, Delete, End, Insert, Migrating, MintRedeemer, Minting,
  Modify, Read, Rejected, Request, RequestAction, RequestDatum, State,
  StateDatum, TokenId, Update, UpdateAction, UpdateRedeemer,
}

// ============================================================================
// The cage — RED: registry mode is NOT implemented here yet
// ============================================================================
//
// This is the pre-#157 fold, carried over to the eight-field `State` so the
// row suite compiles and EXECUTES against it. The consumer pin and its
// mandatory withdrawal are gone with `consumer.ak`; nothing of registry mode
// has taken their place.
//
// Not here, on purpose:
//
// - C1/C2 the leaf codec and the seven admitted edges — every value byte is
//   still accepted, so every refusal row of G1, G3, M3 and N10 is folded;
// - C3 the read at its own position — `Read` walks the trie with no
//   verification of its own, so G4's position controls do not refuse;
// - C4 admission by approval — A1, A2 and A3 fold without one;
// - C5 the delta against the mint — M1-M5, P3 and G2's off-by-one column
//   fold whatever the transaction mints;
// - C6 destinations and custody — T1-T6 fold with the token anywhere, or
//   nowhere;
// - C8 request value coverage — V1 folds an unfunded request.
//
// And nothing here emits a user-defined trace, so the trace map has no
// executable extent at all: `conformance/ticket-157-trace-map.tsv` names 92
// refusals this file cannot produce.

validator state() {
  mint(redeemer: MintRedeemer, policyId: PolicyId, tx: Transaction) {
    when redeemer is {
      Minting(seed) -> validateMint(seed, policyId, tx)
      Migrating(_) -> fail
      Burning(_) -> fail
    }
  }

  spend(
    maybeDatum: Option<CageDatum>,
    redeemer: UpdateRedeemer,
    self: OutputReference,
    tx: Transaction,
  ) {
    expect Some(StateDatum(pins)) = maybeDatum
    expect Some(input) = find(tx.inputs, fn(i) { i.output_reference == self })
    expect address.Script(policyId) = input.output.address.payment_credential
    expect Some(cageToken) = tokenFromPolicy(policyId, input.output.value)
    expect exactQuantity(policyId, input.output.value, cageToken, 1)
    when redeemer is {
      Modify(actions) ->
        validModify(pins, input, policyId, cageToken, tx, actions)
      End -> fail
      _ -> fail
    }
  }

  else(_) {
    fail
  }
}

fn uncons(items: List<a>, cont: fn(a, List<a>) -> b) -> b {
  when items is {
    [] -> fail
    [x, ..xs] -> cont(x, xs)
  }
}

fn mkAction(tokenId, stateTip, process_time, retract_time, validity_range) {
  fn(
    input: Input,
    acc: (
      MerklePatriciaForestry,
      List<RequestAction>,
      List<Pair<VerificationKeyHash, Int>>,
    ),
  ) -> (
    MerklePatriciaForestry,
    List<RequestAction>,
    List<Pair<VerificationKeyHash, Int>>,
  ) {
    when input.output.datum is {
      InlineDatum(datum) ->
        if datum is RequestDatum(request): CageDatum {
          let Request { requestToken, requestKey, requestValue, requestOwner, tip, submitted_at, .. } =
            request
          if requestToken == tokenId {
            expect tip == stateTip
            let (trie, actions, owners) = acc
            let action, actionsTail <- uncons(actions)
            let inputLovelace = lovelace_of(input.output.value)
            let newRoot =
              when action is {
                UpdateAction(proof) -> {
                  expect in_phase1(validity_range, submitted_at, process_time)
                  when requestValue is {
                    Insert(value) -> mpf.insert(trie, requestKey, value, proof)
                    Delete(value) -> mpf.delete(trie, requestKey, value, proof)
                    Update(oldValue, newValue) ->
                      mpf.update(trie, requestKey, proof, oldValue, newValue)
                    // RED: a read is walked, never verified at its position.
                    Read(value) ->
                      mpf.update(trie, requestKey, proof, value, value)
                  }
                }
                Rejected -> {
                  expect
                    is_rejectable(
                      validity_range,
                      submitted_at,
                      process_time,
                      retract_time,
                    )
                  trie
                }
              }
            let newOwners =
              when action is {
                UpdateAction(_) -> owners
                Rejected ->
                  if inputLovelace > 0 {
                    [Pair(requestOwner, inputLovelace - stateTip), ..owners]
                  } else {
                    owners
                  }
              }
            (newRoot, actionsTail, newOwners)
          } else {
            acc
          }
        } else {
          acc
        }
      _ -> acc
    }
  }
}

fn sumRefunds(
  outputs: List<Output>,
  owners: List<Pair<VerificationKeyHash, Int>>,
) -> Bool {
  when owners is {
    [] -> True
    [Pair(owner, owed), ..rest] -> {
      expect [output, ..remaining] = outputs
      expect address.VerificationKey(vkh) = output.address.payment_credential
      expect vkh == owner
      expect lovelace_of(output.value) >= owed
      sumRefunds(remaining, rest)
    }
  }
}

fn validModify(
  pins: State,
  input: Input,
  policyId: PolicyId,
  tokenId: TokenId,
  tx: Transaction,
  actions: List<RequestAction>,
) -> Bool {
  let Transaction { outputs, inputs, validity_range, .. } = tx
  expect Some(output) = head(outputs)
  expect InlineDatum(outState) = output.datum
  expect StateDatum(next) = outState
  // The seven non-root fields are registry configuration. Preserved, as the
  // six were before — with no trace to say so when they are not.
  expect pins.tip == next.tip
  expect pins.process_time == next.process_time
  expect pins.retract_time == next.retract_time
  expect pins.application_policy == next.application_policy
  expect pins.active_policy == next.active_policy
  expect pins.absent_policy == next.absent_policy
  expect pins.terminal_policy == next.terminal_policy
  let (expectedNewRoot, actionsTail, owners) =
    inputs
      |> foldl(
          (mpf.from_root(pins.root), actions, []),
          mkAction(
            tokenId,
            pins.tip,
            pins.process_time,
            pins.retract_time,
            validity_range,
          ),
        )
  expect mpf.root(expectedNewRoot) == next.root
  expect
    output.address.payment_credential == input.output.address.payment_credential
  expect lovelace_of(output.value) >= lovelace_of(input.output.value)
  expect exactQuantity(policyId, output.value, tokenId, 1)
  let n = list.length(owners)
  let consumed = list.length(actions) - list.length(actionsTail)
  expect consumed > 0
  expect actionsTail == []
  when n is {
    0 -> True
    _ -> {
      expect [_, ..refundOutputs] = outputs
      expect sumRefunds(refundOutputs, list.reverse(owners))
      True
    }
  }
}

pub fn validateMint(seed: OutputReference, policyId: PolicyId, tx: Transaction) {
  let Transaction { outputs, mint, inputs, .. } = tx
  let tokenId = TokenId { assetName: assetName(seed) }
  expect is_some(find_input(inputs, seed))
  expect exactQuantity(policyId, mint, tokenId, 1)
  expect Some(output) = head(outputs)
  expect address.Script(targetScriptHash) = output.address.payment_credential
  expect targetScriptHash == policyId
  expect InlineDatum(tokenState) = output.datum
  expect StateDatum(State { root: tokenRoot, .. }) = tokenState
  expect tokenRoot == root(empty)
  expect exactQuantity(policyId, output.value, tokenId, 1)
  True
}
