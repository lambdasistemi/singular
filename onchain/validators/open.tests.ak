use cardano/assets.{PolicyId, Value, from_asset, merge, zero}
use cardano/transaction.{Transaction}
use cardano/transaction as tx_mod
use lib.{approvalName}
use open
use types.{Approve, OpenRedeemer}

// ============================================================================
// #173 A173-APPROVAL — the open application's admission rule
// ============================================================================
//
// The open policy mints one approval token per scoping tuple
// `(edge, key, owner, destination)`, for the six TREE edges 0..5. Its
// asset name IS the binding: `lib.approvalName` over the whole tuple, the
// same function the cage recomputes at fold time (D-APPROVAL), so an
// approval cannot be pointed at a request it was not minted for.
//
// `witnessTerminal` (edge 6) needs no approval at all in the model
// (`admitsFor` admits it unconditionally), so minting one is refused
// rather than silently useful; edge 7 is not an edge.
//
// Quantity is part of the binding: exactly one asset name, exactly `+1`.
// Widening it would let one mint certify a batch.
//
// A PURE burn accepts under any redeemer: an approval is evidence, never
// a consumable, so destroying your own copy costs the registry nothing.

const openPolicy: PolicyId = "open_policy_id__________________"

const testKey: ByteArray = #"6b6579"

const testOwner: ByteArray = #"6f776e6572"

const testAddress: ByteArray = #"6164647265737300000000000000000000000000000000000000000000"

const testDatumHash: ByteArray = #"00"

const testDestination: (ByteArray, ByteArray) = (testAddress, testDatumHash)

/// The transaction whose mint field moves exactly the named assets under
/// the open policy.
fn mint_tx(moved: List<(ByteArray, Int)>) -> Transaction {
  Transaction {
    ..tx_mod.placeholder,
    mint: build_mint(moved),
  }
}

fn build_mint(moved: List<(ByteArray, Int)>) -> Value {
  when moved is {
    [] -> zero
    [(name, quantity), ..rest] ->
      merge(from_asset(openPolicy, name, quantity), build_mint(rest))
  }
}

fn approve(edge: Int) -> OpenRedeemer {
  Approve {
    edge,
    key: testKey,
    owner: testOwner,
    destination: testDestination,
  }
}

fn bound_name(edge: Int) -> ByteArray {
  approvalName(edge, testKey, testOwner, testDestination)
}

/// The rule, at each of the six tree edges: one `+1` asset whose name is
/// the tuple's own binding is admitted.
fn admits_edge(edge: Int) -> Bool {
  open.open.mint(
    approve(edge),
    openPolicy,
    mint_tx([(bound_name(edge), 1)]),
  )
}

test open_admits_insert_absent() {
  admits_edge(0)
}

test open_admits_insert_active() {
  admits_edge(1)
}

test open_admits_update_active() {
  admits_edge(2)
}

test open_admits_update_terminal() {
  admits_edge(3)
}

test open_admits_delete_absent() {
  admits_edge(4)
}

test open_admits_delete_active() {
  admits_edge(5)
}

/// A PURE burn is the holder's own business (evidence, not a
/// consumable). Every movement under the policy is negative and there is
/// at least one.
test open_admits_pure_burn() {
  open.open.mint(
    approve(1),
    openPolicy,
    mint_tx([(bound_name(1), -1)]),
  )
}

/// The name is the binding: an asset name that is not this tuple's
/// `approvalName` is refused, however well-formed the redeemer.
test open_refuses_wrong_binding() {
  !open.open.mint(
    approve(1),
    openPolicy,
    mint_tx([(bound_name(2), 1)]),
  )
}

/// A single wrong byte in the name is enough — the whole tuple is
/// committed, so this is the control that the check is not comparing
/// lengths or prefixes.
test open_refuses_foreign_name() {
  !open.open.mint(
    approve(1),
    openPolicy,
    mint_tx([(#"00", 1)]),
  )
}

/// `witnessTerminal` needs no approval in the model, so minting one
/// under the open policy is refused rather than left meaningfully
/// mintable.
test open_refuses_edge_six() {
  !open.open.mint(
    approve(6),
    openPolicy,
    mint_tx([(bound_name(6), 1)]),
  )
}

/// Edge 7 is not an edge at all.
test open_refuses_edge_seven() {
  !open.open.mint(
    approve(7),
    openPolicy,
    mint_tx([(bound_name(7), 1)]),
  )
}

/// Quantity widening: two of the bound asset in one mint would let a
/// single approval certify more than the one request it names.
test open_refuses_widened_quantity() {
  !open.open.mint(
    approve(1),
    openPolicy,
    mint_tx([(bound_name(1), 2)]),
  )
}

/// Two distinct approval names in one mint is the same widening by
/// another route: one redeemer cannot bind two tuples.
test open_refuses_two_assets() {
  !open.open.mint(
    approve(1),
    openPolicy,
    mint_tx([(bound_name(1), 1), (bound_name(2), 1)]),
  )
}

/// A mint hiding beside a burn is not a pure burn and is held to the
/// binding rule like any other mint.
test open_refuses_mint_beside_burn() {
  !open.open.mint(
    approve(1),
    openPolicy,
    mint_tx([(bound_name(1), 1), (bound_name(2), -1)]),
  )
}

/// Nothing moves under the policy at all: there is no approval to admit
/// and no burn to allow.
test open_refuses_empty_mint() {
  !open.open.mint(approve(1), openPolicy, mint_tx([]))
}
