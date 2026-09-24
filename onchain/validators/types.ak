use aiken/crypto.{VerificationKeyHash}
use aiken/merkle_patricia_forestry.{Proof}
use cardano/assets.{AssetName, PolicyId}
use cardano/transaction.{OutputReference}

/// A unique identifier for a token, consisting of just the asset name.
///
/// The policy ID is provided separately in functions that need it,
/// allowing the same TokenId to be used across different contexts.
///
/// ## Why Only AssetName
/// In the cage system, the policy ID is always the cage script's own
/// hash (since it's a combined minting+spending validator). By storing
/// only the asset name, we avoid carrying redundant policy ID references
/// through the datum structures. The asset name alone uniquely identifies
/// a caged token within the cage script's namespace.
///
/// ## Derivation
/// The asset name is derived from an OutputReference via `assetName()`.
/// It is the SHA2-256 hash of (transaction_id ++ output_index_as_2_bytes).
pub type TokenId {
  assetName: AssetName,
}

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
/// - The seven `edge` row indices land on their C2 rows (0 insertAbsent
///   through 6 witnessTerminal)
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
  /// The application policy that certifies requests (#157 C4/C7). A
  /// request whose operation changes the trie is folded only if its UTxO
  /// carries exactly one asset under this policy at quantity 1, whose
  /// asset name is the approval binding of that request
  /// (`lib.approvalName`, D-APPROVAL). No application script runs at fold
  /// time: the approval is evidence the application already certified the
  /// edge, and the cage recomputes its name rather than trusting it.
  /// Set at genesis, preserved by every `Modify`.
  application_policy: PolicyId,
  /// The policy that mints the ACTIVE token (#157 C5/C7, renamed from
  /// `representative_policy`): the live registration's witness. Under it
  /// the asset name is the registry key itself (D-ASSET).
  /// Set at genesis, preserved by every `Modify`.
  active_policy: PolicyId,
  /// The policy that mints the ABSENT token (#157 C5/C7): the witness
  /// that a key is known-absent, held in the cage's own custody beside
  /// the inserter's refund address (D-CUSTODY).
  /// Set at genesis, preserved by every `Modify`.
  absent_policy: PolicyId,
  /// The policy that mints the TERMINAL token (#157 C5/C7): the witness
  /// that a key is over, forever. Minted by a `Read(0x02)` at the read's
  /// position in the fold; freely burnable by its holder (W3).
  /// Set at genesis, preserved by every `Modify`.
  terminal_policy: PolicyId,
}

/// The C2 row index of a request (#183, Lean `Request.edge`). An edge names
/// its own leaf bytes, so no value bytes travel with the request:
///
/// | edge | name              | trie move            |
/// |------|-------------------|----------------------|
/// | 0    | insertAbsent      | insert `0x00`        |
/// | 1    | insertActive      | insert `0x01`        |
/// | 2    | updateActive      | update `0x00`→`0x01` |
/// | 3    | updateTerminal    | update `0x01`→`0x02` |
/// | 4    | deleteAbsent      | delete `0x00`        |
/// | 5    | deleteActive      | delete `0x01`        |
/// | 6    | witnessTerminal   | read `0x02`          |
///
/// The constants live in `lib.ak` (`edgeInsertAbsent` …
/// `edgeWitnessTerminal`). A tag outside `0..6` is refused
/// `edge-inadmissible` before approval and before any proof is checked.
///
/// Each edge maps directly to a `merkle_patricia_forestry` step with the
/// leaf bytes above; the proof demonstrates the transition given the
/// current trie. Illegal value-byte shapes of the old `Operation` wire
/// (G1/G3) are not expressible in this encoding and retired with the
/// wire; see the slice-(b) decision record for the per-trace mapping.
///
/// A request to modify a caged token's MPF, on the Lean wire (#183).
///
/// The request carries the C2 row index (`edge` 0-6, Lean `Request.edge`)
/// instead of value bytes: the edge names its own leaf bytes (see above),
/// so illegal value-byte shapes are inexpressible. No `tip` field: the
/// fold requires the input lovelace to reach `state.tip`
/// (Lean `lovelaceCoversTip`); `deposit` is the value above the tip the
/// request rides with (`held - state.tip`). `approval` (Lean) is the
/// carried asset under the application policy, not a datum field;
/// `claimed` (Lean) is the transaction mint, not a datum field;
/// `refundAddress` (Lean) is `destination`'s first component for the
/// absent edges and the custody refund otherwise.
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
///    transaction. The validator reads the request's `edge` and `requestKey`,
///    applies the edge's trie move with the provided proof, and
///    advances the root hash.
///
/// 4. **Retraction** (alternative to 2-3): If the request is still
///    pending, the request creator can spend it back with `Retract`
///    when it is an insert or read request (update/delete requests are not
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
/// - Request with edge 1 for key "bar" -> inserts `0x01` at "bar"
/// - Two requests for same key in same Modify tx -> depends on order and edge
///   type (e.g., edge 1 then edge 5 would insert then immediately delete)
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
  /// The C2 row index of this request (0-6; see above).
  /// The edge names the trie move and its leaf bytes.
  edge: Int,
  /// The deposit (in lovelace) the request rides with, over and above the tip.
  /// Must equal the input lovelace less `state.tip` at Modify time.
  ///
  /// The deposit is the requester's value, never a payment to anyone; the
  /// tip pays the folder. Where the deposit goes, by how the request ends
  /// (#253):
  ///
  /// | Exit | Tip | Deposit |
  /// |---|---|---|
  /// | Fold delivering a token (edges 0, 1, 2, 6) | folder | with the token, at the named destination (the cage's custody for 0) |
  /// | Fold delivering nothing (edges 3, 4, 5) | folder | `requestOwner`'s key, at least the deposit |
  /// | Reject | folder | `requestOwner`'s key, at least the deposit |
  /// | Retract | returned | `requestOwner`, at least the held value (deposit + tip) |
  ///
  /// A shortfall or misdirection is refused `deposit-returned`. Everything
  /// one fold owes one payee — deposits, reject refunds, and the custody
  /// refunds that return an absence witness's deposit — is paid on the
  /// summed lovelace of the outputs with that payee's payment credential,
  /// token carriers aside, so one output never pays two of them; custody
  /// refunds are also summed per exact refund address (`refund`). Value
  /// outside these obligations (fees, the folder's tip) is unconstrained.
  deposit: Int,
  /// The POSIXTime (in milliseconds) when the request was submitted.
  /// Used for time-gated phase enforcement: Phase 1 (oracle-only),
  /// Phase 2 (requester retract), Phase 3 (oracle reject/cleanup).
  submitted_at: Int,
  /// Where this request's minted token goes, and the inline datum the
  /// receiving output must carry (#157 D-DEST; appended last, so the
  /// published field order never moves): the binary address bytes and
  /// the BLAKE2b-256 hash of the receiving output's inline datum (empty
  /// for a datum-less output).
  ///
  /// The folder is permissionless. Without a bound destination a folder
  /// could route Alice's active token to itself; without a bound datum
  /// it could create her record with a controller of its own choosing.
  /// The cage requires exactly one output matching both and carrying
  /// the minted token, holding at least this request's value minus the
  /// tip (C6, T6). For edge 0 the token goes to the cage's own
  /// custody instead and the first component is the refund address
  /// (D-CUSTODY); for edge 6 it is where the terminal token goes.
  destination: (ByteArray, ByteArray),
}

// #183 slice b: `RequestDatum` at index 0 now carries the edge-only
// `Request`. The old `Operation` wire and the S20 transient are gone;
// the dual-codec checkpoint stands in history.

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
  /// The cage's own custody of an absent token (#157 D-CUSTODY;
  /// appended at index 2, so `RequestDatum` 0 and `StateDatum` 1 never
  /// move). A fold of edge 0 mints the absent token and locks
  /// it here, at the cage's own address, beside the address the inserter
  /// named for their refund. The witnessed key is the sole non-ADA asset
  /// in the custody output, not a second datum identity. Its lovelace
  /// is the request's residual after the tip — the min-ADA that R-ADA
  /// returns.
  ///
  /// The cage's spending path for it is exactly one shape: spent in a
  /// `Modify` that consumes a request for this key with edge 2
  /// (`updateActive`) or edge 4 (`deleteAbsent`), paying its lovelace to an
  /// output at `refund`. Whoever books the name later, the deposit goes
  /// back to whoever witnessed the absence.
  AbsentCustody { refund: ByteArray }
}

/// The open application's mint redeemer (#173 I1).
///
/// It names the scoping tuple the approval is being minted for. The
/// policy recomputes `lib.approvalName` over exactly these four
/// components and requires the minted asset name to equal it, so the
/// redeemer cannot point a token at a tuple it does not commit to.
/// `destination` is the same pair the cage's `Request` carries: the
/// binary address bytes and the BLAKE2b-256 hash of the receiving
/// output's inline datum.
pub type OpenRedeemer {
  Approve {
    /// The edge ordinal this approval certifies: 0 `insertAbsent`,
    /// 1 `insertActive`, 2 `updateActive`, 3 `updateTerminal`,
    /// 4 `deleteAbsent`, 5 `deleteActive`. Edge 6 (`witnessTerminal`)
    /// needs no approval and is refused here.
    edge: Int,
    /// The registry key the certified edge moves.
    key: ByteArray,
    /// The controller (or, for the absent edges, the refund address)
    /// the request acts for.
    owner: ByteArray,
    /// Where the request's minted token goes, and the inline datum the
    /// receiving output must carry.
    destination: (ByteArray, ByteArray),
  }
}
