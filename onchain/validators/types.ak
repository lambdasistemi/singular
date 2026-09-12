use aiken/crypto.{VerificationKeyHash}
use aiken/merkle_patricia_forestry.{Proof}
use cardano/assets.{PolicyId}
use cardano/transaction.{OutputReference}
use lib.{TokenId}

/// Core type definitions for the MPF Cage validator.
///
/// This module defines the data structures used for:
/// - Minting and burning caged tokens
/// - Managing state updates via the Merkle Patricia Forestry
/// - Processing contribution requests from other users
///
/// ## Cage Pattern Overview
///
/// A "caged" token is an NFT locked at a script address with an associated
/// Merkle Patricia Forestry (MPF) root. Anyone can fold pending requests
/// into the MPF via permissionless `Modify` (no owner signs since issue
/// #79), enabling collaborative data structures
/// on-chain.
///
/// ## Two-UTxO Architecture
///
/// The cage script manages two fundamentally different kinds of UTxOs,
/// distinguished by their datum type:
///
/// 1. **State UTxOs** (`StateDatum`): Hold the caged NFT and the current
///    MPF root hash. Only one State UTxO exists per caged token. There is
///    no registry-owner role (operator ruling NOTE-028/A-003): `Modify`
///    (folding) is permissionless since issue #79, and `End`, migration,
///    burning and `Sweep` refuse for every party. Request and application
///    authority and ordinary funding signatures keep their own clauses.
///
/// 2. **Request UTxOs** (`RequestDatum`): Created by users who want to
///    contribute data to someone else's caged token. They do NOT hold the
///    NFT -- they sit at the same script address with a different datum.
///    The `requestToken` field links the request to a specific caged token.
///
/// ## Lifecycle
///
/// ```
/// Mint  -->  State UTxO (empty root)
///                |
///                |  <-- Request UTxOs arrive (from contributors)
///                |
///                v
///            Modify (folds requests into MPF, updates root)
///                |
///                v
///            State UTxO (updated root)
/// ```
///
/// The M1 action set has no termination, migration or deposit-recovery
/// operation: `End` (burns the NFT), migration, burning and `Sweep`
/// refuse. This statement is about this design, not about all possible
/// future registries.
///
/// Request UTxOs that are not yet accepted can be reclaimed by their
/// creator via the `Retract` redeemer (request-owner authority, a
/// separate domain, untouched).
///
/// ## Test Planning Notes
///
/// The types themselves don't have validation logic, but tests should
/// verify that:
/// - All datum variants can be serialized/deserialized as inline datums
/// - Pattern matching on `CageDatum` correctly distinguishes `RequestDatum`
///   from `StateDatum`
/// - The `Operation` variants carry the right payloads (Insert has 1 value,
///   Delete has 1 value, Update has 2 values)
/// - `MintRedeemer` and `UpdateRedeemer` cover all action types exhaustively
/// Parameters for migrating a caged token from an old validator to a new one.
///
/// During migration, the old token is burned (under `oldPolicy`) and a new
/// token is minted (under the new policy) in the same transaction. The
/// `tokenId` is preserved across migration (same asset name).
///
/// Uniqueness of the new token is guaranteed by the atomic burn of the old
/// one -- no `OutputReference` consumption is needed.
pub type Migration {
  /// The policy ID of the old validator whose token is being burned.
  oldPolicy: PolicyId,
  /// The token identity (asset name) being migrated.
  tokenId: TokenId,
}

/// Redeemer for the minting policy.
///
/// The minting policy handles three cases:
/// - `Minting`: Full validation is applied (see `validateMint` in `state.ak`).
///   The seed `OutputReference` that authorizes the mint and derives the
///   asset name is the validator's parameter, not a redeemer field.
/// - `Migrating`: REFUSED (operator ruling NOTE-028/A-003, issue #77
///   repair). Migration is a destructive re-policying with no ownerless
///   justification. Constructor kept for the wire shape.
/// - `Burning`: REFUSED (same ruling). Burning the caged token destroys
///   the registry without touching `End` at all. Constructor kept for
///   the wire shape.
pub type MintRedeemer {
  /// Mint a new caged token. The seed output reference is consumed by the
  /// transaction and also determines the cage token asset name.
  Minting(OutputReference)
  /// Migrate a caged token from an old validator to this one. REFUSED.
  Migrating(Migration)
  /// Burn an existing caged token. REFUSED.
  Burning(TokenId)
}

/// Per-request action in a `Modify` redeemer.
///
/// Each action corresponds to one request input in the transaction:
/// - `Update(proof)`: verify the Merkle proof and apply the MPF operation
/// - `Rejected`: verify the request is rejectable (Phase 3 or dishonest)
///   and skip proof verification
///
/// ## On-chain encoding
/// - `Update(proof)` → Constr 0 [proof]
/// - `Rejected` → Constr 1 []
pub type RequestAction {
  /// Apply the request's operation to the MPF using this proof.
  UpdateAction(Proof)
  /// Reject the request (expiry or dishonest timestamp).
  Rejected
}

/// Redeemer for spending caged UTxOs.
///
/// This redeemer is used by the spending validator in `cage.ak`. The five
/// variants correspond to five distinct operations, each requiring a
/// different datum type on the UTxO being spent:
///
/// | Redeemer       | Required Datum         | Who Can Execute         | Purpose                                    |
/// |----------------|------------------------|-------------------------|--------------------------------------------|
/// | `End`          | `StateDatum`           | REFUSED (no owner role) | Termination is refused for every party     |
/// | `Contribute`   | `RequestDatum`         | Anyone (permissionless) | Link a request to a State UTxO             |
/// | `Modify`       | `StateDatum`           | Anyone (permissionless fold) | Process requests (update/reject)           |
/// | `Retract`      | `RequestDatum`         | Request owner           | Reclaim an unprocessed request             |
/// | `Sweep`        | any (incl. `None`)     | REFUSED (no owner role) | Seizure is refused for every party         |
///
/// Constructors are kept so the redeemer wire shape does not shift;
/// the `End` and `Sweep` arms refuse (operator ruling NOTE-028/A-003).
///
/// ## Test Hints
/// - Using `End` on any datum -> should fail (refused, owner-signed or not)
/// - Using `Retract` on a `StateDatum` UTxO -> should fail (expects RequestDatum)
/// - Using `Modify` without owner signature -> succeeds when the fold is
///   otherwise valid (permissionless since issue #79)
/// - Using `Contribute` with a request targeting a different token -> should fail
/// - Using `Retract` without request owner signature -> should fail
/// - Using `Sweep` on any datum -> should fail (refused, owner-signed or not)
pub type UpdateRedeemer {
  /// Termination (burns the NFT). REFUSED for every party: there is no
  /// registry-owner role. Constructor kept for the wire shape.
  End
  /// Validate that a Request UTxO targets the correct caged token.
  Contribute(OutputReference)
  /// Process requests with mixed update/reject actions. Requires State datum.
  /// The `List<RequestAction>` must contain exactly one action per request
  /// being processed, in the same order as the request inputs appear in
  /// the transaction's input list. `Update(proof)` applies the MPF operation;
  /// `Rejected` skips the proof and verifies rejectability instead.
  Modify(List<RequestAction>)
  /// Allow the request owner to reclaim their Request UTxO.
  Retract(OutputReference)
  /// Seizure of UTxOs at the cage's address. REFUSED for every party:
  /// there is no registry-owner role. Constructor kept for the wire shape.
  Sweep(OutputReference)
}

/// The state of a caged token, stored as inline datum.
///
/// This represents the MPF root and oracle economics of the caged token.
/// A State value lives inside a `StateDatum` wrapper as part of a `CageDatum`.
/// There is no owner field and no ownership model (operator ruling
/// NOTE-028/A-003, issue #77 repair).
///
/// ## Root Hash
/// The `root` field is a raw `ByteArray` (32 bytes for SHA2-256) representing
/// the MPF root hash. It starts as `root(empty)` when freshly minted.
/// It is updated each time `Modify` processes requests.
///
/// ## Test Hints
/// - Verify root must match computed MPF root after folding requests
/// - Verify initial root is `root(empty)` after minting
pub type State {
  /// Ownerless registry (operator ruling NOTE-028/A-003, issue #77
  /// repair): there is no registry-owner role — no owner field, no
  /// stake script, no ownership transfer. `Modify` is permissionless;
  /// `End`, migration and `Sweep` are explicit refusals.
  /// The current Merkle Patricia Forestry root hash.
  /// This commits to all key-value pairs stored in the MPF.
  root: ByteArray,
  /// The oracle's tip per request (in lovelace).
  /// Requesters agree to this tip by recording it in their Request datum.
  /// The actual tx fee is split across requests at Modify time (Plutus V3).
  tip: Int,
  /// Duration (in milliseconds) of Phase 1 — the oracle processing window.
  /// Set at mint time; enforced immutable across Modify/Reject operations.
  process_time: Int,
  /// Duration (in milliseconds) of Phase 2 — the requester retract window.
  /// Set at mint time; enforced immutable across Modify/Reject operations.
  retract_time: Int,
  /// The expected representative minting policy (issue #77, E-001 repair):
  /// `Singular.representativePolicy` refined on chain. Set at bootstrap from
  /// the honest applied representative policy; preserved immutable across
  /// every `Modify` (a fold altering it refuses). The naming application
  /// validator reads this field from the spent state and requires the moved
  /// representative's policy to equal it — foreign-policy fakes refuse with
  /// `representative-policy`. Appended, never reordered: the first four
  /// fields keep their indices.
  representative_policy: PolicyId,
}

/// Operations that can be performed on the MPF.
///
/// Each operation modifies the MPF in a specific way and requires
/// a corresponding proof to validate the transition. The proof
/// demonstrates that the operation is valid given the current MPF state.
///
/// These operations map directly to the `merkle_patricia_forestry` library
/// functions: `mpf.insert`, `mpf.delete`, and `mpf.update`.
///
/// ## Proof Requirements
///
/// Each operation requires a Merkle proof that demonstrates:
/// - `Insert(value)`: The key does NOT exist in the current trie.
///   The proof shows the absence of the key, and after insertion
///   the new root includes the key-value pair.
/// - `Delete(value)`: The key EXISTS with the given value.
///   The proof shows the key's current value, and after deletion
///   the new root excludes the key.
/// - `Update(old, new)`: The key EXISTS with value `old`.
///   The proof shows the key's current value, and after update
///   the new root maps the key to `new`.
///
/// ## Test Hints
/// - Insert on empty MPF with valid proof -> should succeed
/// - Insert on key that already exists -> should fail (MPF library rejects)
/// - Delete on non-existent key -> should fail
/// - Delete with wrong expected value -> should fail
/// - Update with wrong old value -> should fail
/// - Multiple operations in sequence (Insert then Update on same key across
///   two separate Modify transactions) -> should succeed
pub type Operation {
  /// Insert a new key-value pair. Fails if key already exists.
  /// The ByteArray is the value to associate with the request's key.
  Insert(ByteArray)
  /// Delete an existing key-value pair. The ByteArray is the expected
  /// current value -- must match what's in the MPF or the proof fails.
  Delete(ByteArray)
  /// Update an existing key's value. First ByteArray is the expected
  /// current value (old_value), second is the new value (new_value).
  /// Both must be correct for the proof to verify.
  Update(ByteArray, ByteArray)
}

/// A request to modify a caged token's MPF.
///
/// Requests are created by users who want to contribute data to
/// someone else's caged token. Anyone can then fold the request by
/// including it in a permissionless `Modify` transaction.
///
/// ## Request Lifecycle
///
/// 1. **Creation**: A user creates a UTxO at the cage script address
///    with a `RequestDatum(Request { ... })` inline datum. The UTxO
///    typically holds only ADA (no NFT).
///
/// 2. **Contribution**: The request UTxO is spent with `Contribute(tokenRef)`
///    redeemer, which validates that `requestToken` matches the token
///    at `tokenRef`. This step is permissionless.
///
/// 3. **Processing**: The request UTxO appears as an input in a `Modify`
///    transaction. The validator reads the `requestKey` and `requestValue`,
///    applies the operation to the MPF using the provided proof, and
///    advances the root hash.
///
/// 4. **Retraction** (alternative to 2-3): If the request is still
///    pending, the request creator can spend it back with `Retract`
///    when it is an insert request (`Update`/`Delete` requests are not
///    retractable since issue #79), which requires `requestOwner`'s
///    signature.
///
/// ## Linking Mechanism
/// The `requestToken` field is a `TokenId` (just an asset name). It must
/// match the asset name of the caged NFT. The policy ID is implicit --
/// it's the cage script's own policy ID.
///
/// ## Test Hints
/// - Request targeting token A processed in Modify for token A -> should succeed
/// - Request targeting token A included in Modify for token B -> should be skipped
///   (mkUpdate checks requestToken == tokenId and skips non-matching requests)
/// - Request with Insert("foo") for key "bar" -> inserts key "bar" with value "foo"
/// - Two requests for same key in same Modify tx -> depends on order and operation
///   type (e.g., Insert then Delete would insert then immediately delete)
pub type Request {
  /// The token this request targets (by asset name).
  /// Must match the TokenId of the caged NFT for the request to be processed.
  requestToken: TokenId,
  /// The owner of this request (can reclaim via Retract).
  /// This is the VerificationKeyHash that must sign a Retract transaction.
  requestOwner: VerificationKeyHash,
  /// The key to insert/update/delete in the MPF.
  /// This is an arbitrary ByteArray that becomes a key in the Merkle trie.
  requestKey: ByteArray,
  /// The operation to perform on the key.
  /// See `Operation` type for details on Insert, Delete, and Update.
  requestValue: Operation,
  /// The oracle tip (in lovelace) the requester agrees to pay.
  /// Must match `state.tip` at Modify time.
  tip: Int,
  /// The POSIXTime (in milliseconds) when the request was submitted.
  /// Used for time-gated phase enforcement: Phase 1 (oracle-only),
  /// Phase 2 (requester retract), Phase 3 (oracle reject/cleanup).
  submitted_at: Int,
}

/// Datum for UTxOs locked at the cage script address.
///
/// The cage script can hold two types of UTxOs:
/// - **State UTxOs** (`StateDatum`): contain the caged NFT and its MPF root.
///   There is exactly one State UTxO per caged token. It holds the NFT in
///   its value and the current MPF root in its datum.
/// - **Request UTxOs** (`RequestDatum`): contain pending requests to modify
///   a token's MPF. These hold only ADA (no NFT). Multiple Request UTxOs
///   can exist for the same caged token.
///
/// ## Dispatch Logic in the Spending Validator
///
/// The spending validator pattern-matches on the datum to determine
/// which operations are valid:
///
/// - `RequestDatum` + `Retract` -> request owner reclaims request
/// - `RequestDatum` + `Contribute(ref)` -> validate request targets correct token
/// - `StateDatum` + `Modify(proofs)` -> fold requests into MPF
/// - `StateDatum` + `End` -> REFUSED (no owner role; no termination)
/// - mint `Migrating` / `Burning`, any `Sweep` -> REFUSED
///
/// Any other combination (e.g., `RequestDatum` + `End`) will fail because
/// the `expect` pattern match in the validator will not succeed.
///
/// ## Test Hints
/// - Construct transactions with mismatched datum/redeemer combinations
///   and verify they all fail
/// - Verify that inline datums round-trip correctly through serialization
pub type CageDatum {
  /// A pending request to modify someone's caged token
  RequestDatum(Request)
  /// The current state of a caged token
  StateDatum(State)
}
