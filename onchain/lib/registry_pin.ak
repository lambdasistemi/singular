//// The registry state hash pin, shared by the witness and the co-located application.
////
//// ## Responsibility
//// Holds the single compiled `state.state.spend` hash every co-located script names.
////
//// ## Dependencies
//// None.
////
//// ## Assumptions
//// The pin equals the compiled state validator in this same source tree.
////
//// ## Invariants
//// The `script-identity` check reads this constant and requires it to equal the built `state.state.spend`.

/// The state script this registry family's witnesses co-locate with
/// (#157 N1). It is the compiled hash of `state.ak` in this same
/// partition, pinned rather than derived: Aiken cannot name a
/// validator's own hash, and deriving it from the `registry` parameter
/// instead would admit a witness parametrised against a fabricated
/// script whose hash merely prefixes the parameter.
///
/// The pin has no compile-time check. It has two EXECUTABLE ones.
///
/// A stale pin makes `foldPresent` find no registry, so every mint
/// under every kind refuses and the devnet rows go red on the first
/// token this registry tries to move.
///
/// #177 I177-COPIES closes the gap that left: the `script-identity`
/// check now reads THIS constant out of this file and requires it to
/// equal the `state.state.spend` hash of the blueprint it just built,
/// so a stale pin is a red identity check on every commit rather than
/// a red devnet row on whichever ticket next moves a token.
pub const registryStateHash: ByteArray =
  #"21c303e0a3ddf43834d9050cf33ec57a9dfd75dcd606b48a38ec9fc1"
