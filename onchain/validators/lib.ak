use aiken/cbor
use aiken/collection/dict
use aiken/collection/dict.{get, keys}
use aiken/collection/list.{delete, find}
use aiken/crypto.{Hash, Sha2_256, blake2b_256, sha2_256}
use aiken/primitive/bytearray
use aiken/primitive/bytearray.{concat, from_int_big_endian}
use cardano/address.{Address, Credential, Inline, Script, VerificationKey}
use cardano/assets.{PolicyId, Value, from_asset, policies, tokens}
use cardano/transaction.{
  Datum, InlineDatum, Input, NoDatum, Output, OutputReference,
}
use types.{TokenId}

/// Helper functions for token handling in the MPF Cage validator.
///
/// This module provides utilities for:
/// - Token identification and extraction from values
/// - Asset name computation from output references
/// - Value construction for single tokens
///
/// ## Role in the Cage System
///
/// The cage validator needs to identify, extract, and manipulate
/// single NFTs. This module provides the plumbing:
///
/// - `assetName`: Derives a unique, deterministic asset name from an
///   `OutputReference` using SHA2-256. This is the foundation of the
///   cage minting policy's uniqueness guarantee.
///
/// - `tokenFromValue`: Extracts the single non-ADA token from a value.
///   Used to identify which caged token a UTxO belongs to.
///
/// - `quantity`: Checks how many of a specific token exist in a value.
///   Used during minting validation to ensure exactly 1 token is minted.
///
/// - `valueFromToken`: Constructs a value with exactly 1 of a token.
///   Used in tests and when building expected output values.
///
/// ## Design Decisions
///
/// `TokenId` only contains the `assetName`, not the `PolicyId`. This is
/// because the policy ID is always the cage script's own hash, which is
/// available from context. Separating them avoids redundancy and makes
/// it easier to compare tokens across different operations.
///
/// ## Test Hints
/// - `assetName` is deterministic: same OutputReference always produces
///   same asset name
/// - `assetName` is collision-resistant: different OutputReferences produce
///   different asset names (SHA2-256 property)
/// - `tokenFromValue` returns None for ADA-only values
/// - `tokenFromValue` returns None for multi-policy values
/// - `tokenFromValue` returns None for multi-asset-name values under one policy
/// - `quantity` returns None when the policy or asset name is absent

/// Get the quantity of a specific token in a value.
///
/// Looks up the given policy ID in the value's token map, then looks up
/// the asset name within that policy's token entries.
///
/// Returns `Some(quantity)` if the token exists (quantity may be positive
/// or negative, e.g., in mint fields), `None` if the policy or asset name
/// is not present.
///
/// ## Usage in Validators
/// Used in `validateMint` to verify that exactly 1 token is minted:
/// ```
/// quantity(policyId, mint, tokenId) == Some(1)
/// ```
///
/// ## Test Hints
/// - Token present with quantity 1 -> Some(1)
/// - Token present with quantity -1 (burn) -> Some(-1)
/// - Token not present (wrong policy) -> None
/// - Token not present (wrong asset name) -> None
/// - Empty value -> None
pub fn quantity(
  policyId: PolicyId,
  value: Value,
  TokenId { assetName },
) -> Option<Int> {
  get(tokens(value, policyId), assetName)
}

/// Check that a value's token map for `policyId` contains exactly one asset,
/// namely `tokenId`, at the expected quantity. Other policies in the value are
/// ignored; this is used by the global state policy to avoid minting unrelated
/// assets under the discovery policy id.
pub fn exactQuantity(
  policyId: PolicyId,
  value: Value,
  TokenId { assetName }: TokenId,
  expected: Int,
) -> Bool {
  let policyTokens = tokens(value, policyId)
  when keys(policyTokens) is {
    [actualName] ->
      actualName == assetName && when get(policyTokens, actualName) is {
        Some(quantity) -> quantity == expected
        None -> False
      }
    _ -> False
  }
}

/// Extract the sole asset name under a specific policy id, ignoring other
/// policies. Returns `None` if that policy has zero or multiple asset names.
pub fn tokenFromPolicy(policyId: PolicyId, value: Value) -> Option<TokenId> {
  when keys(tokens(value, policyId)) is {
    [assetName] -> Some(TokenId { assetName })
    _ -> None
  }
}

/// Compute a unique asset name from an output reference.
///
/// The asset name is the SHA2-256 hash of the transaction ID concatenated
/// with the output index (as 2 big-endian bytes). This ensures uniqueness
/// since an output reference can only be consumed once.
///
/// ## Algorithm
/// 1. Take the transaction ID (a 32-byte hash)
/// 2. Encode the output index as 2 bytes in big-endian format
/// 3. Concatenate: tx_id ++ output_index_bytes
/// 4. Apply SHA2-256 to the concatenation
///
/// ## Why 2 Bytes for Output Index
/// Using `from_int_big_endian(ref.output_index, 2)` encodes the output
/// index as exactly 2 bytes. This supports output indices from 0 to 65535,
/// which is more than sufficient for Cardano transactions (which have far
/// fewer outputs in practice).
///
/// ## Uniqueness Guarantee
/// Since an OutputReference (tx_id, output_index) can only appear once
/// in the UTXO set, and `validateMint` requires this OutputReference to
/// be consumed in the minting transaction, the same asset name can never
/// be minted twice. The SHA2-256 hash makes it computationally infeasible
/// to find a different OutputReference that produces the same asset name.
///
/// ## Test Hints
/// - Same OutputReference always produces same hash (deterministic)
/// - Different tx_id -> different hash
/// - Different output_index -> different hash
/// - Output index 0 vs 256 -> different hash (tests big-endian encoding)
pub fn assetName(ref: OutputReference) -> Hash<Sha2_256, OutputReference> {
  let bytes =
    concat(ref.transaction_id, from_int_big_endian(ref.output_index, 2))
  sha2_256(bytes)
}

/// Construct a Value containing exactly 1 of the specified token.
///
/// Creates a Cardano Value with a single native token at quantity 1 under
/// the given policy ID and asset name. Does NOT include any ADA -- the
/// caller is responsible for adding minimum ADA if needed.
///
/// ## Usage
/// - In `validateMint`: the expected output value is built with this
///   function to compare against the actual minted value.
/// - In tests: used to construct expected UTxO values.
///
/// ## Test Hints
/// - The resulting value should have exactly one policy (besides ADA)
/// - The token quantity should be exactly 1
/// - `tokenFromValue(valueFromToken(pid, tid))` should return `Some(tid)`
pub fn valueFromToken(
  policyId: PolicyId,
  TokenId { assetName }: TokenId,
) -> Value {
  from_asset(policyId, assetName, 1)
}

/// Extract a single token ID from a value.
///
/// This function expects the value to contain exactly one non-ADA policy
/// with exactly one asset name. Returns `None` if the value doesn't match
/// this pattern (e.g., contains multiple tokens or no tokens).
///
/// This is useful for extracting the caged token from a UTxO that should
/// contain only ADA and a single NFT.
///
/// ## Algorithm (step by step)
/// 1. Get all policy IDs from the value via `policies(value)`
/// 2. Remove the ADA policy (empty string "") from the list via `delete`
/// 3. If exactly one non-ADA policy remains:
///    a. Get its token map via `tokens(value, policyId)`
///    b. Get all asset name keys from the token map
///    c. If exactly one asset name exists:
///       - Look it up in the token map (this always succeeds)
///       - Return `Some(TokenId { assetName })`
///    d. Otherwise return `None`
/// 4. If zero or more than one non-ADA policy, return `None`
///
/// ## Important: Ignores Quantity
/// Note that this function does NOT check the token quantity. It returns
/// the TokenId regardless of whether the quantity is 1, 2, or even -1.
/// The caller must verify quantity separately if needed.
///
/// ## Security Consideration
/// This function is used in `extractToken` (cage.ak) which is called for
/// both `Modify` and `End` operations. If a UTxO somehow contained two
/// different NFTs, this function would return `None` and the validator
/// would fail -- this is the correct behavior.
///
/// ## Test Hints
/// - Value with ADA + 1 NFT -> Some(TokenId)
/// - Value with only ADA -> None
/// - Value with ADA + 2 different policies -> None
/// - Value with ADA + 1 policy + 2 asset names -> None
/// - Value with 1 NFT (no ADA entry) -> Some(TokenId)
/// - Value with ADA + 1 NFT quantity 5 -> Some(TokenId) (quantity ignored)
pub fn tokenFromValue(value: Value) -> Option<TokenId> {
  // Remove ADA policy ("") from the policy list
  when delete(policies(value), "") is {
    // Exactly one non-ADA policy
    [policyId] -> {
      let tokens = tokens(value, policyId)
      // Check that there's exactly one asset name under this policy
      when keys(tokens) is {
        [assetName] ->
          // Look up the asset name (should always succeed since we got it from keys)
          when get(tokens, assetName) is {
            Some(_) -> Some(TokenId { assetName })
            _ -> None
          }
        _ -> None
      }
    }
    _ -> None
  }
}

/// Find an input by output reference and extract its token.
///
/// Searches the input list for the specified output reference and extracts
/// the single token from that input's value. Returns `None` if the input
/// is not found or doesn't contain exactly one token (aside from ADA).
///
/// This is a convenience function that combines input lookup with token
/// extraction. It's used in the `Contribute` validation path where we need
/// to find the State UTxO and extract its caged token to compare against
/// the request's `requestToken`.
///
/// ## Differences from `extractToken` in cage.ak
/// This function returns `Option` (graceful failure), while `extractToken`
/// in cage.ak uses `expect` (hard failure). This version is defined in the
/// library for reuse, while the cage.ak version is specialized for the
/// spending validator context where failure should abort the transaction.
///
/// ## Test Hints
/// - Input exists and contains exactly one NFT -> Some((input, tokenId))
/// - Input exists but has no NFT (ADA only) -> None
/// - Input exists but has multiple NFTs -> None
/// - Output reference not found in inputs -> None
pub fn extractTokenFromInputs(what: OutputReference, inputs: List<Input>) {
  when find(inputs, fn(input) { input.output_reference == what }) is {
    Some(input) ->
      when tokenFromValue(input.output.value) is {
        Some(tokenId) -> Some((input, tokenId))
        _ -> None
      }
    _ -> None
  }
}

// ============================================================================
// Registry mode (#157): the leaf codec, the seven edges, the approval name
// and destination matching
// ============================================================================
//
// These are the pure helpers the cage and its tests share. Every one of
// them is total: it answers for every input rather than crashing, so the
// cage can name its own reason for a refusal instead of dying inside a
// library. `state.ak` is the only caller that turns a `None` here into a
// traced refusal.

/// The Absent leaf byte (#157 D-CODEC).
pub const leafAbsent: ByteArray = #"00"

/// The Active leaf byte.
pub const leafActive: ByteArray = #"01"

/// The Terminal leaf byte.
pub const leafTerminal: ByteArray = #"02"

/// The C2 row index of each admitted edge. The six tree edges are `0..5`
/// in the order D-APPROVAL fixes (`0` insertAbsent … `5` deleteActive),
/// so the edge byte of an approval name is this index; the read is `6`
/// and never appears in an approval, because a read needs none (C4).
pub const edgeInsertAbsent: Int = 0

pub const edgeInsertActive: Int = 1

pub const edgeUpdateActive: Int = 2

pub const edgeUpdateTerminal: Int = 3

pub const edgeDeleteAbsent: Int = 4

pub const edgeDeleteActive: Int = 5

pub const edgeWitnessTerminal: Int = 6

/// The three token kinds, in the order the state pins their policies.
pub const kindAbsent: Int = 0

pub const kindActive: Int = 1

pub const kindTerminal: Int = 2

// #183 slice b: requests carry an edge index, not value bytes. The leaf
// bytes above are what each edge's trie move reads and writes, and the
// seven C2 rows (table in `types.ak`) are named by the request's own tag,
// admitted `0..6` by the fold before approval. Nothing derives an edge
// from bytes any more, so `decodeState`, `statedBefore` and `edgeOf`
// retire with the `Operation` wire.

/// The token column of C2, read off the edge and nothing else (#157 C5):
/// `(kind, quantity)` pairs the fold sums per key and the mint must then
/// equal exactly. An unknown edge moves nothing.
pub fn deltaOf(edge: Int) -> List<(Int, Int)> {
  if edge == edgeInsertAbsent {
    [(kindAbsent, 1)]
  } else if edge == edgeInsertActive {
    [(kindActive, 1)]
  } else if edge == edgeUpdateActive {
    [(kindAbsent, -1), (kindActive, 1)]
  } else if edge == edgeUpdateTerminal {
    [(kindActive, -1)]
  } else if edge == edgeDeleteAbsent {
    [(kindAbsent, -1)]
  } else if edge == edgeDeleteActive {
    [(kindActive, -1)]
  } else if edge == edgeWitnessTerminal {
    [(kindTerminal, 1)]
  } else {
    []
  }
}

/// The approval binding (#157 D-APPROVAL):
/// `blake2b_256(edge ‖ key ‖ owner ‖ destination)`, where `edge` is one
/// byte (the C2 row index), `key` the registry key, `owner` the request
/// owner's credential bytes and `destination` the D-DEST bytes — its
/// address followed by its datum hash, both exactly as the request
/// carries them.
///
/// One approval certifies one `(edge, key, owner, destination)`. The cage
/// recomputes this name from the request and refuses a mismatch, so an
/// approval minted for a different owner, edge, key or destination
/// cannot be spent here; reuse by the same owner for the same tuple is
/// the same authority and is harmless. Shared with naming's mint arm,
/// which computes the identical bytes from its redeemer — one formula,
/// two partitions, so drift makes honest batches refuse loudly.
pub fn approvalName(
  edge: Int,
  key: ByteArray,
  owner: ByteArray,
  destination: (ByteArray, ByteArray),
) -> ByteArray {
  let (address, datumHash) = destination
  blake2b_256(
    from_int_big_endian(edge, 1)
      |> concat(key)
      |> concat(owner)
      |> concat(address)
      |> concat(datumHash),
  )
}

/// Decode the binary address bytes a request names into the ledger's own
/// `Address` (#157 D-DEST). Header kinds 6-7 are enterprise addresses
/// (header plus a 28-byte payment hash), kinds 0-3 are base addresses
/// (header, 28-byte payment hash, 28-byte stake hash); everything else —
/// pointer addresses, reward addresses, a wrong length — is refused.
/// Any network nibble is accepted, exactly as naming's own codec does.
///
/// Both credentials are recovered, so a destination binds the stake part
/// too: a folder cannot deliver Alice's token to her payment credential
/// under its own staking key.
pub fn decodeAddress(bytes: ByteArray) -> Option<Address> {
  let size = bytearray.length(bytes)
  if size < 1 {
    None
  } else {
    let kind = bytearray.at(bytes, 0) / 16
    if (kind == 6 || kind == 7) && size == 29 {
      Some(
        Address {
          payment_credential: credentialOf(kind == 6, bytearray.slice(bytes, 1, 28)),
          stake_credential: None,
        },
      )
    } else if kind < 4 && size == 57 {
      Some(
        Address {
          payment_credential: credentialOf(
            kind == 0 || kind == 2,
            bytearray.slice(bytes, 1, 28),
          ),
          stake_credential: Some(
            Inline(
              credentialOf(kind == 0 || kind == 1, bytearray.slice(bytes, 29, 56)),
            ),
          ),
        },
      )
    } else {
      None
    }
  }
}

fn credentialOf(isKey: Bool, hash: ByteArray) -> Credential {
  if isKey {
    VerificationKey(hash)
  } else {
    Script(hash)
  }
}

/// Does this output sit at the destination the request named, carrying
/// the inline datum it named (#157 D-DEST)? Address equality is over the
/// whole address, payment and stake credential alike; datum equality is
/// over the BLAKE2b-256 of the serialised inline datum, with an empty
/// hash meaning the output must carry no datum at all.
///
/// Total: an undecodable destination matches nothing, so a request that
/// names nonsense cannot be folded rather than folding anywhere.
pub fn destinationMatches(
  destination: (ByteArray, ByteArray),
  out: Output,
) -> Bool {
  let (address, datumHash) = destination
  when decodeAddress(address) is {
    Some(expected) -> expected == out.address && datumMatches(datumHash, out.datum)
    None -> False
  }
}

/// The datum half of `destinationMatches`, split out so the custody and
/// record checks can reuse it.
pub fn datumMatches(datumHash: ByteArray, datum: Datum) -> Bool {
  if datumHash == #"" {
    datum == NoDatum
  } else {
    when datum is {
      InlineDatum(inline) -> blake2b_256(cbor.serialise(inline)) == datumHash
      _ -> False
    }
  }
}

/// Does an output pay this destination address at all, whatever it
/// carries? The refund leg of custody (#157 C6, R-ADA) binds the address
/// and the lovelace, never the datum.
pub fn paysAddress(address: ByteArray, out: Output) -> Bool {
  when decodeAddress(address) is {
    Some(expected) -> expected == out.address
    None -> False
  }
}

// #183 slice b: `insertRefusal` retires with the `Operation` wire. An
// insert carries no value byte, so the request fault `insert-terminal`
// is inexpressible; an insert on a key the trie already binds is refused
// `key-exists` at `occupiedRefusal` below, which is now the only insert
// refusal left to name.

/// The reason an insert on a key the trie already binds is refused
/// (#173 A-006, A-009; interface §2; Lean `refusal`, which answers
/// `key-exists` for every occupied key). The primitive refuses BEFORE
/// any mint arithmetic runs, so this is not the keyed-mint witness and
/// must not be confused with it.
///
/// Called where `mpf.miss(trie, key, proof)` answers false on an insert.
/// KNOWN LIMIT, accepted in A-009: `mpf.miss` answers false both for an
/// occupied key and for a malformed exclusion proof, and the cage
/// cannot tell them apart. Both are REFUSED, so nothing the model
/// refuses is admitted; the trace name is imprecise for the
/// malformed-proof case.
pub fn occupiedRefusal() -> Option<String> {
  Some(@"key-exists")
}

/// The reason a fold whose claimed mint disagrees with the summed delta
/// of its edges is refused (#173 A-006, Lean L2
/// `fold_batch_claimed_mint_by_kind_key`).
///
/// One construction site, so a test asserting the reason asserts the
/// value the fold actually traces. The name is the model's
/// (`net-mint-mismatch`); it replaces the pre-#173 `delta-mismatch` at
/// this one site, for every edge, because there is one mint guard.
pub fn mintRefusal() -> Option<String> {
  Some(@"net-mint-mismatch")
}

/// The total quantity a value moves under one policy, summed across
/// every asset name — the COARSER accounting the keyed guard refines.
///
/// It exists to make the keyed guard's row non-vacuous: without it, a
/// test asserting that a wrong keyed distribution is refused cannot show
/// that the distribution it used agrees per kind, and a batch that also
/// disagreed per kind would be refused by the coarser rule for a reason
/// that says nothing about keys.
pub fn kindTotal(value: Value, policy: PolicyId) -> Int {
  sumQuantities(dict.values(tokens(value, policy)))
}

fn sumQuantities(quantities: List<Int>) -> Int {
  when quantities is {
    [] -> 0
    [q, ..rest] -> q + sumQuantities(rest)
  }
}
