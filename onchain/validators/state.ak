use aiken/collection/list.{find, foldl, head}
use aiken/crypto.{VerificationKeyHash}
use aiken/primitive/bytearray
use aiken/merkle_patricia_forestry.{MerklePatriciaForestry, empty, root}
use aiken/merkle_patricia_forestry as mpf
use aiken/option.{is_some}
use cardano/address
use cardano/assets.{PolicyId}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, find_input,
}
use lib.{TokenId, assetName, exactQuantity, tokenFromPolicy}
use shared.{in_phase1, is_rejectable}
use types.{
  Burning, CageDatum, Delete, End, Insert, Migrating, MintRedeemer, Minting,
  Modify, Rejected, Request, RequestAction, RequestDatum, State, StateDatum,
  Update, UpdateAction, UpdateRedeemer,
}

// Ownerless registry (operator ruling NOTE-028/A-003, issue #77 repair):
// the state validator takes no parameters. The former `previousPolicies`
// migration allowlist is gone with migration itself.
validator state() {
  mint(redeemer: MintRedeemer, policyId: PolicyId, tx: Transaction) {
    when redeemer is {
      Minting(seed) -> validateMint(seed, policyId, tx)
      // Ownerless registry (operator ruling NOTE-028/A-003, issue #77
      // repair): migration and burning destroy or re-policy the registry
      // with no ownerless justification. Both refuse for every party;
      // the constructors stay for the wire shape.
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
    expect Some(StateDatum(state)) = maybeDatum
    // Permissionless fold (issue #79, Defect 1): Modify must NOT require
    // any owner — there is no registry-owner role (operator ruling
    // NOTE-028/A-003). Lean `step .fold` checks nativeSpend, nonempty
    // items, net mint equality, the mint witnesses, and the consumer
    // invocation witness. `End` refuses for every party; see its arm below.
    expect Some(input) = find(tx.inputs, fn(i) { i.output_reference == self })
    expect address.Script(policyId) = input.output.address.payment_credential
    expect Some(cageToken) = tokenFromPolicy(policyId, input.output.value)
    expect exactQuantity(policyId, input.output.value, cageToken, 1)
    when redeemer is {
      Modify(actions) ->
        validModify(state, input, policyId, cageToken, tx, actions)
      // Ownerless registry (operator ruling NOTE-028/A-003, issue #77
      // repair): termination is refused for every party — there is no
      // registry-owner role, creator or otherwise. The constructor stays
      // for the wire shape.
      End -> fail
      _ -> fail
    }
  }

  else(_) {
    fail
  }
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
    ),
  ) -> (
    MerklePatriciaForestry,
    List<RequestAction>,
    List<Pair<VerificationKeyHash, Int>>,
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
            let (root, actions, owners) = acc
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
            // Refund rows (NOTE-014 item A2 as corrected by NOTE-017): only
            // REJECTED rows are owed refunds, at `input − tip` with no fee
            // share deducted and none invented. Processed rows add nothing
            // here — their value may leave to a checkpoint lock or to
            // change; the generic side admits the shape and the pinned
            // consumer hook judges the allocation.
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
            (
              newRoot,
              actionsTail,
              newOwners,
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
) -> Bool {
  when owners is {
    [] -> True
    [Pair(owner, owed), ..rest] -> {
      expect [output, ..remaining] = outputs
      expect address.VerificationKey(vkh) = output.address.payment_credential
      expect vkh == owner
      // Per-owner no-underpayment (NOTE-014 item A2): this row's output
      // carries at least exactly what is owed. Unequal crossed allocations
      // fail here even when every credential passes and every total
      // matches. Min-UTxO top-ups from funding inputs may only add — the
      // ledger's conservation plus the state's no-drain rule below close
      // the rest, with no upper envelope to maintain.
      expect assets.lovelace_of(output.value) >= owed
      sumRefunds(remaining, rest)
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
  // Fees ride funding inputs and ledger conservation explicitly; the
  // validator pins per-owner floors, state preservation, and the root.
  let Transaction { outputs, inputs, withdrawals, validity_range, fee: _tx_fee, .. } = tx
  let State { root, tip, process_time, retract_time, representative_policy, consumer_pin } = state
  expect Some(output) = head(outputs)
  expect InlineDatum(outState) = output.datum
  expect StateDatum(State {
    root: newRoot,
    tip: outTip,
    process_time: outProcessTime,
    retract_time: outRetractTime,
    representative_policy: outRepresentativePolicy,
    consumer_pin: outConsumerPin,
  }) = outState
  expect tip == outTip
  expect process_time == outProcessTime
  expect retract_time == outRetractTime
  // E-001 repair (issue #77): the expected representative policy is registry
  // configuration — genesis sets it, every fold preserves it. A fold altering
  // it refuses here, before any root or refund check.
  expect representative_policy == outRepresentativePolicy
  // Pinned consumer hook (NOTE-013/NOTE-019): the pin is registry
  // configuration — genesis selects it (width-checked at mint), every fold
  // preserves it exactly. A fold altering it refuses here, beside the
  // representative policy above.
  expect consumer_pin == outConsumerPin

  let (expectedNewRoot, actionsTail, owners) =
    inputs
      |> foldl(
          (mpf.from_root(root), actions, []),
          mkAction(tokenId, tip, process_time, retract_time, validity_range),
        )
  expect (mpf.root(expectedNewRoot) == newRoot)?
  expect
    output.address.payment_credential == input.output.address.payment_credential
  // No-drain rule only (NOTE-017): the generic cage does NOT absorb
  // processed bonds — locking is the consumer's allocation, enforced at
  // the pinned hook, not here. Processed value may leave to a checkpoint
  // lock or (as our current builders route it) to change; what the generic
  // side refuses is losing track of it silently, which ledger conservation
  // plus the rejected-row floors below already close. See the boundary
  // table for what is admitted vs checked.
  expect
    assets.lovelace_of(output.value) >= assets.lovelace_of(input.output.value)
  expect exactQuantity(policyId, output.value, tokenId, 1)

  let n = list.length(owners)
  // Exact request/action pairing (NOTE-020, A001/root 071): empty
  // processing refuses — no matching request consumed, no batch. A dummy
  // withdrawal, or a nonempty action list with no matching request, does
  // not manufacture nonemptiness. Surplus unconsumed actions refuse —
  // every supplied action must pair with an actual matching request, and
  // missing actions still refuse at `uncons`. Both are checked before the
  // hook predicate below and before fee/refund failures, so each control
  // fails on its own reason.
  // Mandatory invocation (NOTE-013): a `Modify` that consumes at least one
  // request must withdraw the exact pinned consumer script. Presence of the
  // exact withdrawal credential forces ledger execution of that script — a
  // caller-declared flag, an input datum, or a redeemer label is not an
  // invocation. Absence refuses; a withdrawal from any other script does
  // not satisfy this.
  let consumed = list.length(actions) - list.length(actionsTail)
  expect consumed > 0
  expect actionsTail == []
  expect
    list.any(
          withdrawals,
          fn(w) {
            let Pair(credential, _) = w
            when credential is {
              address.Script(hash) -> hash == consumer_pin
              _ -> False
            }
          },
        )
  when n is {
    0 -> True
    _ -> {
      expect [_, ..refundOutputs] = outputs
      let orderedOwners = list.reverse(owners)
      // Exact per-owner floors above; totals are closed by ledger
      // conservation (inputs + mint = outputs + fee), the state's lovelace
      // no-drain rule above, and funding inputs covering fees and any
      // min-UTxO top-ups visibly. No aggregate envelope to keep in sync.
      expect sumRefunds(refundOutputs, orderedOwners)
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
  expect
    StateDatum(State {
      root: tokenRoot,
      tip: _tip,
      process_time: _processTime,
      retract_time: _retractTime,
      representative_policy: _representativePolicy,
      consumer_pin: tokenConsumerPin,
    })
    = tokenState
  expect tokenRoot == root(empty)
  // Pinned consumer hook (NOTE-013): genesis selects the pin — any 28-byte
  // script hash. Boot is permissionless (no owner), so the mint authorizes
  // no value, only the width: preservation plus mandatory invocation (both
  // in `validModify` above) give the pin its force, not mint-time approval.
  expect bytearray.length(tokenConsumerPin) == 28
  expect exactQuantity(policyId, output.value, tokenId, 1)
  True
}
