//// How the state validator reports a refusal.
////
//// ## Responsibility
////
//// A named refusal — one the `Modify` decision or the custody spending path
//// gives a reason for — is one user-defined trace followed by `False`, never
//// a crash: a script that dies inside a library cannot say why. `traceFalse`
//// is that report. It covers only those paths: genesis, the unmatched arms
//// of the validator and the `expect`s of the `Modify` decision (a malformed
//// continuation, an invalid proof no named refusal covers) still crash.
////
//// ## Dependencies
////
//// Imports nothing from this project. `state`, `request`, the open-datum
//// application and `registry/modify` import it; it imports none of them, so
//// it sits at the bottom of the registry's dependency order.
////
//// ## Assumptions
////
//// - A caller returns `traceFalse`'s result as its handler's result, so the
////   reason it traces is the only user-defined trace of that refusal.
//// - The published blueprint keeps user-defined traces, so the reason is
////   part of the compiled script and of its hash; the Aiken suite asserts
////   the same trace. Compiler-generated `expect` traces are not kept there.
////
//// ## Invariants
////
//// - `traceFalse` never fails the script: it evaluates to `False`.

/// Report a refusal: trace `reason` once and answer `False`. A refused
/// `Modify` in the spend handler and every refusal of the custody spending
/// path answer through here, so exactly one user-defined trace names why.
pub fn traceFalse(reason: String) -> Bool {
  trace reason
  False
}
