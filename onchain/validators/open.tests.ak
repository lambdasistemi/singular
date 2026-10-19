use booking.{applicationTagName}
use cardano/assets.{PolicyId, Value, from_asset, merge, zero}
use cardano/transaction.{Transaction}
use cardano/transaction as tx_mod
use lib.{approvalName}
use open
use types.{Approve, ApproveRegistration, OpenRedeemer}

// ============================================================================
// The open application's admission rule
// ============================================================================
//
// The open policy mints one application tag per registration booking. Its asset
// name IS the binding: `booking.applicationTagName` over the request's key,
// refund address, destination and nonce, the same function the request
// policy's booking judgement recomputes, so a tag cannot be pointed at a
// request it was not minted for. Quantity is part of the binding: exactly one
// asset name, exactly `+1`. Widening it would let one mint certify a batch.
//
// A PURE burn accepts under any redeemer: a tag is evidence, never a
// consumable, and the fold burns the tag of every registration it folds.
//
// The edge-numbered `Approve` of the old fold is retired for every edge (its
// constructor stays for the wire shape); `ApproveRegistration` is the one
// lawful approval. Old to new map of the retired rows, each of which started
// from an `Approve` mint that is now refused for every edge (so none can stay
// as an individual guard of the binding): `open_admits_insert_absent`,
// `open_admits_insert_active`, `open_admits_update_active`,
// `open_admits_delete_absent`, `open_admits_delete_active` are the
// `tagged_registration_open_refuses_the_legacy_approval_of_*` rows below and
// the lawful `tagged_registration_open_admits_the_registration_approval`;
// `open_refuses_wrong_binding` and `open_refuses_foreign_name` are the names of
// another nonce and of another key; `open_refuses_widened_quantity`,
// `open_refuses_two_assets`, `open_refuses_mint_beside_burn` and
// `open_refuses_empty_mint` are the same-shaped `ApproveRegistration` rows;
// `open_refuses_edge_six` and `open_refuses_edge_seven` are the two
// `..._of_edge_six` and `..._of_edge_seven` rows. `open_admits_pure_burn` and
// `open_refuses_the_termination_approval` stay: the burn is lawful under any
// redeemer, and the termination approval is retired under its own name.
// No generic application consent, script spending protection or cross-registry
// separation is claimed.

const openPolicy: PolicyId = "open_policy_id__________________"

const testKey: ByteArray = #"6b6579"

const testOwner: ByteArray = #"6f776e6572"

const testAddress: ByteArray =
  #"6164647265737300000000000000000000000000000000000000000000"

const testDatumHash: ByteArray = #"00"

const testDestination: (ByteArray, ByteArray) = (testAddress, testDatumHash)

/// The transaction whose mint field moves exactly the named assets under
/// the open policy.
fn mint_tx(moved: List<(ByteArray, Int)>) -> Transaction {
  Transaction { ..tx_mod.placeholder, mint: build_mint(moved) }
}

fn build_mint(moved: List<(ByteArray, Int)>) -> Value {
  when moved is {
    [] -> zero
    [(name, quantity), ..rest] ->
      merge(from_asset(openPolicy, name, quantity), build_mint(rest))
  }
}

fn approve(edge: Int) -> OpenRedeemer {
  Approve { edge, key: testKey, owner: testOwner, destination: testDestination }
}

fn bound_name(edge: Int) -> ByteArray {
  approvalName(edge, testKey, testOwner, testDestination)
}

/// The rule, at each of the six tree edges: one `+1` asset whose name is
/// the tuple's own binding is admitted.
fn admits_edge(edge: Int) -> Bool {
  open.open.mint(approve(edge), openPolicy, mint_tx([(bound_name(edge), 1)]))
}

/// A PURE burn is the holder's own business (evidence, not a
/// consumable). Every movement under the policy is negative and there is
/// at least one.
test open_admits_pure_burn() {
  open.open.mint(approve(1), openPolicy, mint_tx([(bound_name(1), -1)]))
}

/// The model has no application approval for a termination: the booking is
/// the application's spend plus the request policy's mint. The generic open
/// policy stays mint-only and no longer certifies the `updateTerminal` edge.
test open_refuses_the_termination_approval() {
  admits_edge(3) == False
}

// ============================================================================
// The registration approval and the retired edge approvals (A-035)
// ============================================================================
//
// Classes of rows (`tagged_registration_*`): the refusals of the legacy tree
// edges were RED (the old policy admitted five of them) and are the GREEN of
// this continuation. A retired-arm refusal is one reason for every edge and is
// not individual guard coverage. The registration positive, its canonical
// binding, quantity, empty, multiple and mixed-mint guards and the pure burn
// existed already and passed at once: preservation evidence, never RED.

fn refuses_legacy_edge(edge: Int) -> Bool {
  open.open.mint(approve(edge), openPolicy, mint_tx([(bound_name(edge), 1)])) == False
}

test tagged_registration_open_refuses_the_legacy_approval_of_insert_absent() {
  refuses_legacy_edge(0)
}

test tagged_registration_open_refuses_the_legacy_approval_of_insert_active() {
  refuses_legacy_edge(1)
}

test tagged_registration_open_refuses_the_legacy_approval_of_update_active() {
  refuses_legacy_edge(2)
}

test tagged_registration_open_refuses_the_legacy_approval_of_delete_absent() {
  refuses_legacy_edge(4)
}

test tagged_registration_open_refuses_the_legacy_approval_of_delete_active() {
  refuses_legacy_edge(5)
}

fn register(nonce: Int) -> OpenRedeemer {
  ApproveRegistration {
    key: testKey,
    refund_address: testOwner,
    destination: testAddress,
    nonce,
  }
}

fn registration_name(nonce: Int) -> ByteArray {
  applicationTagName(testKey, testOwner, testAddress, nonce)
}

test tagged_registration_open_admits_the_registration_approval() {
  open.open.mint(register(1), openPolicy, mint_tx([(registration_name(1), 1)]))
}

/// The name is the binding: the tag of another nonce is refused.
test tagged_registration_open_refuses_the_name_of_another_nonce() {
  open.open.mint(register(1), openPolicy, mint_tx([(registration_name(2), 1)])) == False
}

/// And the tag of another key.
test tagged_registration_open_refuses_the_name_of_another_key() {
  let other = applicationTagName(#"6f74686572", testOwner, testAddress, 1)
  open.open.mint(register(1), openPolicy, mint_tx([(other, 1)])) == False
}

test tagged_registration_open_refuses_a_widened_quantity() {
  open.open.mint(register(1), openPolicy, mint_tx([(registration_name(1), 2)])) == False
}

test tagged_registration_open_refuses_two_registration_names() {
  open.open.mint(
    register(1),
    openPolicy,
    mint_tx([(registration_name(1), 1), (registration_name(2), 1)]),
  ) == False
}

test tagged_registration_open_refuses_a_registration_mint_beside_a_burn() {
  open.open.mint(
    register(1),
    openPolicy,
    mint_tx([(registration_name(1), 1), (registration_name(2), -1)]),
  ) == False
}

test tagged_registration_open_refuses_an_empty_registration_mint() {
  open.open.mint(register(1), openPolicy, mint_tx([])) == False
}

/// A pure burn of a registration approval stays lawful under any redeemer.
test tagged_registration_open_admits_a_pure_burn_of_a_registration_approval() {
  open.open.mint(register(1), openPolicy, mint_tx([(registration_name(1), -1)]))
}

test tagged_registration_open_refuses_the_legacy_approval_of_edge_six() {
  refuses_legacy_edge(6)
}

test tagged_registration_open_refuses_the_legacy_approval_of_edge_seven() {
  refuses_legacy_edge(7)
}
