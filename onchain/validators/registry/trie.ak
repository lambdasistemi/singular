//// What the trie refuses for an edge, read off the trie itself (#177, #183).
////
//// ## Responsibility
////
//// The named refusals a fold raises when the leaf an edge needs is not the
//// leaf the trie binds: `terminalFault` for a retirement (`updateTerminal`),
//// registration refuses every occupied key. Each is the one construction site
//// of its reasons, so a test asserting a reason asserts the value the
//// validator traces. An insert on a key the trie already binds keeps its
//// construction site in `lib` (`occupiedRefusal`, `key-exists`).
////
//// ## Dependencies
////
//// Imports the Merkle Patricia Forestry library and `lib` (the edge table's
//// leaf bytes). Imported by `registry/fold`, which decides when to ask, and
//// by the Aiken suite. It knows nothing of requests, duties or values.
////
//// ## Assumptions
////
//// - `proof` is the proof the request's action supplies for `key`, against
////   the trie as the fold has advanced it so far in the batch.
//// - The request states no leaf bytes: the leaf is what the trie binds.
////
//// ## Invariants
////
//// - Every classification uses the library's total checks (`mpf.miss`,
////   `mpf.has`), which answer for any input instead of crashing, so a wrong
////   leaf is an attributable refusal rather than a death inside
////   `mpf.update`.
//// - A key the trie does not bind at all is `key-unknown` for both the
////   retirement and the read.
//// - `terminalFault` answers `None` for an `Active` leaf and for a proof
////   matching no root; the latter then fails in `mpf.update` exactly as on
////   every other edge.

use aiken/merkle_patricia_forestry.{MerklePatriciaForestry}
use aiken/merkle_patricia_forestry as mpf
use lib.{leafAbsent, leafActive, leafTerminal}

/// Why the trie refuses this `updateTerminal`, or `None` when the leaf
/// it binds is the `Active` one the edge moves (#177 I177-CHAIN).
///
/// The subject is the leaf the trie ACTUALLY binds — established here,
/// against this request's own proof, with the MPF library's own TOTAL
/// checks. `miss` and `has` answer for every input instead of crashing,
/// so a wrong leaf becomes an attributable refusal rather than a death
/// inside `mpf.update`, which says only that the script died.
///
/// It is NOT a leaf the request states — edge-only requests state none:
/// a claim by the requester says nothing about the trie.
///
/// One construction site, so a test asserting a reason asserts the
/// value this validator traces rather than a helper nothing calls
/// (#173 A-006, applied to this edge). The names are Lean's, from
/// `update_terminal_transaction_row`.
///
/// `None` is the residue, and it is also where an INVALID proof lands:
/// a proof matching no root matches none of the three checks either.
/// That case then dies in `mpf.update` exactly as it does on every
/// other edge. The three leaves Lean names are what this classifies.
pub fn terminalFault(
  trie: MerklePatriciaForestry,
  key: ByteArray,
  proof: mpf.Proof,
) -> Option<String> {
  if mpf.miss(trie, key, proof) {
    Some(@"key-unknown")
  } else if mpf.has(trie, key, leafAbsent, proof) {
    Some(@"not-booked")
  } else if mpf.has(trie, key, leafTerminal, proof) {
    Some(@"terminal-immutable")
  } else {
    None
  }
}
