use aiken/collection/list.{find, foldl, has, head}
use aiken/crypto.{VerificationKeyHash}
use aiken/merkle_patricia_forestry.{MerklePatriciaForestry, empty, root}
use aiken/merkle_patricia_forestry as mpf
use aiken/option.{is_some}
use cardano/address
use cardano/assets.{PolicyId}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, find_input,
}
use lib.{TokenId, assetName, exactQuantity, tokenFromPolicy}
use shared.{in_phase1, is_rejectable, readState, validateOwnership}
use types.{
  Burning, CageDatum, Delete, End, Insert, Migrating, Migration, MintRedeemer,
  Minting, Modify, Rejected, Request, RequestAction, RequestDatum, State,
  StateDatum, Update, UpdateAction, UpdateRedeemer,
}

validator state(previousPolicies: List<PolicyId>) {
  mint(redeemer: MintRedeemer, policyId: PolicyId, tx: Transaction) {
    when redeemer is {
      Minting(seed) -> validateMint(seed, policyId, tx)
      Migrating(migration) ->
        validateMigration(previousPolicies, migration, policyId, tx)
      Burning(tokenId) -> validateBurn(tokenId, policyId, tx)
    }
  }

  spend(
    maybeDatum: Option<CageDatum>,
    redeemer: UpdateRedeemer,
    self: OutputReference,
    tx: Transaction,
  ) {
    expect Some(StateDatum(state)) = maybeDatum
    expect validateOwnership(state, tx)
    expect Some(input) = find(tx.inputs, fn(i) { i.output_reference == self })
    expect address.Script(policyId) = input.output.address.payment_credential
    expect Some(cageToken) = tokenFromPolicy(policyId, input.output.value)
    expect exactQuantity(policyId, input.output.value, cageToken, 1)
    when redeemer is {
      Modify(actions) ->
        validModify(state, input, policyId, cageToken, tx, actions)
      End -> validateEnd(policyId, cageToken, tx)
      _ -> fail
    }
  }

  else(_) {
    fail
  }
}

fn validateBurn(tokenId: TokenId, policyId: PolicyId, tx: Transaction) {
  let Transaction { mint, .. } = tx
  expect exactQuantity(policyId, mint, tokenId, -1)
  True
}

fn validateEnd(policyId: PolicyId, tokenId: TokenId, tx: Transaction) {
  validateBurn(tokenId, policyId, tx)
}

fn uncons(list: List<a>, cont: fn(a, List<a>) -> b) -> b {
  when list is {
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
      Int,
    ),
  ) -> (
    MerklePatriciaForestry,
    List<RequestAction>,
    List<Pair<VerificationKeyHash, Int>>,
    Int,
  ) {
    when input.output.datum is {
      InlineDatum(datum) ->
        if datum is RequestDatum(request): CageDatum {
          let Request {
            requestToken,
            requestKey,
            requestValue,
            requestOwner,
            tip,
            submitted_at,
          } = request
          if requestToken == tokenId {
            expect tip == stateTip
            let (root, actions, owners, totalInputLovelace) = acc
            let action, actionsTail <- uncons(actions)
            let inputLovelace = assets.lovelace_of(input.output.value)
            let newRoot =
              when action is {
                UpdateAction(proof) -> {
                  expect in_phase1(validity_range, submitted_at, process_time)
                  when requestValue is {
                    Insert(value) -> mpf.insert(root, requestKey, value, proof)
                    Delete(value) -> mpf.delete(root, requestKey, value, proof)
                    Update(oldValue, newValue) ->
                      mpf.update(root, requestKey, proof, oldValue, newValue)
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
                  root
                }
              }
            let newOwners =
              if inputLovelace > 0 {
                [Pair(requestOwner, inputLovelace), ..owners]
              } else {
                owners
              }
            (
              newRoot,
              actionsTail,
              newOwners,
              totalInputLovelace + inputLovelace,
            )
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
) -> Int {
  when owners is {
    [] -> 0
    [Pair(owner, _), ..rest] -> {
      expect [output, ..remaining] = outputs
      expect address.VerificationKey(vkh) = output.address.payment_credential
      expect vkh == owner
      assets.lovelace_of(output.value) + sumRefunds(remaining, rest)
    }
  }
}

fn validModify(
  state: State,
  input: Input,
  policyId: PolicyId,
  tokenId: TokenId,
  tx: Transaction,
  actions: List<RequestAction>,
) {
  let Transaction { outputs, inputs, validity_range, fee: tx_fee, .. } = tx
  let State { root, tip, process_time, retract_time, .. } = state
  expect Some(output) = head(outputs)
  expect InlineDatum(outState) = output.datum
  expect StateDatum(State {
    root: newRoot,
    tip: outTip,
    process_time: outProcessTime,
    retract_time: outRetractTime,
    ..
  }) = outState
  expect tip == outTip
  expect process_time == outProcessTime
  expect retract_time == outRetractTime

  let (expectedNewRoot, _, owners, totalInputLovelace) =
    inputs
      |> foldl(
          (mpf.from_root(root), actions, [], 0),
          mkAction(tokenId, tip, process_time, retract_time, validity_range),
        )
  expect (mpf.root(expectedNewRoot) == newRoot)?
  expect
    output.address.payment_credential == input.output.address.payment_credential
  expect
    assets.lovelace_of(output.value) >= assets.lovelace_of(input.output.value)
  expect exactQuantity(policyId, output.value, tokenId, 1)

  let n = list.length(owners)
  when n is {
    0 -> True
    _ -> {
      expect [_, ..refundOutputs] = outputs
      let orderedOwners = list.reverse(owners)
      let totalRefunded = sumRefunds(refundOutputs, orderedOwners)
      let owed = totalInputLovelace - tx_fee - n * tip
      let maxRefunded = totalInputLovelace - n * tip
      // Refunds may exceed owed only to satisfy ledger min-UTxO. The state
      // output preserves its lovelace above, so any bounded top-up comes from
      // owner-signed funding inputs rather than from the cage.
      expect totalRefunded >= owed
      expect totalRefunded <= maxRefunded
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

pub fn validateMigration(
  previousPolicies: List<PolicyId>,
  migration: Migration,
  policyId: PolicyId,
  tx: Transaction,
) {
  let Migration { oldPolicy, tokenId } = migration
  let Transaction { outputs, mint, inputs, .. } = tx
  // FR1: oldPolicy must be an audited, allowlisted predecessor.
  expect has(previousPolicies, oldPolicy)
  // FR5: mint integrity — burn the old token, mint exactly one new one.
  expect exactQuantity(oldPolicy, mint, tokenId, -1)
  expect exactQuantity(policyId, mint, tokenId, 1)
  // FR2: the predecessor state UTxO carrying (oldPolicy, tokenId) must
  // actually be spent; the migrated State is read from it.
  expect Some(predIn) =
    find(inputs, fn(i) { exactQuantity(oldPolicy, i.output.value, tokenId, 1) })
  let predState = readState(predIn)
  // FR3: the predecessor owner authorizes the migration.
  expect validateOwnership(predState, tx)
  // FR5: output[0] goes to the new state script and holds the new token.
  expect Some(output) = head(outputs)
  expect address.Script(targetScriptHash) = output.address.payment_credential
  expect targetScriptHash == policyId
  expect exactQuantity(policyId, output.value, tokenId, 1)
  expect InlineDatum(tokenState) = output.datum
  expect StateDatum(outState) = tokenState
  // FR4: migration is a pure re-policy operation — every field is preserved.
  expect outState == predState
  True
}
