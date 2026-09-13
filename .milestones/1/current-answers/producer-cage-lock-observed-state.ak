use aiken/collection/list.{find, foldl, head}
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
    // NOTE-028/A-003). Lean `step .fold` checks only nativeSpend, net
    // mint equality and the mint witnesses. `End` refuses for every
    // party; see its arm below.
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
            let (root, actions, owners, locked) = acc
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
            // Locked accumulation (NOTE-014 item A2): every processed
            // request locks `input − tip` (bond stays, tip releases
            // implicitly); rejected rows lock nothing. The state output must
            // carry exactly previous plus locked — diverting locked value to
            // a trailing refund-shaped output shorts the state and refuses,
            // while self-funded overpayments (no victim) still pass.
            let (newOwners, newLocked) =
              when action is {
                UpdateAction(_) -> (owners, locked + inputLovelace - stateTip)
                Rejected ->
                  if inputLovelace > 0 {
                    (
                      [Pair(requestOwner, inputLovelace - stateTip), ..owners],
                      locked,
                    )
                  } else {
                    (owners, locked)
                  }
              }
            (
              newRoot,
              actionsTail,
              newOwners,
              newLocked,
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
  let Transaction { outputs, inputs, validity_range, fee: _tx_fee, .. } = tx
  let State { root, tip, process_time, retract_time, representative_policy } = state
  expect Some(output) = head(outputs)
  expect InlineDatum(outState) = output.datum
  expect StateDatum(State {
    root: newRoot,
    tip: outTip,
    process_time: outProcessTime,
    retract_time: outRetractTime,
    representative_policy: outRepresentativePolicy,
  }) = outState
  expect tip == outTip
  expect process_time == outProcessTime
  expect retract_time == outRetractTime
  // E-001 repair (issue #77): the expected representative policy is registry
  // configuration — genesis sets it, every fold preserves it. A fold altering
  // it refuses here, before any root or refund check.
  expect representative_policy == outRepresentativePolicy

  let (expectedNewRoot, _, owners, lockedTotal) =
    inputs
      |> foldl(
          (mpf.from_root(root), actions, [], 0),
          mkAction(tokenId, tip, process_time, retract_time, validity_range),
        )
  expect (mpf.root(expectedNewRoot) == newRoot)?
  expect
    output.address.payment_credential == input.output.address.payment_credential
  // Locked value accumulates exactly (NOTE-014 item A2): processed bonds
  // stay in the cage — previous plus locked, no more, no less. Together
  // with per-owner floors below and ledger conservation, every harmful
  // flow is refused (underpaid requester, drained state, diverted lock);
  // only self-funded overpayments pass, which have no victim.
  expect assets.lovelace_of(output.value) == assets.lovelace_of(input.output.value) + lockedTotal
  expect exactQuantity(policyId, output.value, tokenId, 1)

  let n = list.length(owners)
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
    })
    = tokenState
  expect tokenRoot == root(empty)
  expect exactQuantity(policyId, output.value, tokenId, 1)
  True
}
