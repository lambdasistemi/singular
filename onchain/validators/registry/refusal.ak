//// How the state validator reports a refusal, and the refusal reasons
//// that more than one registry owner constructs.
////
//// ## Responsibility
////
//// A named refusal — one the `Modify` decision or the custody spending path
//// gives a reason for — is one user-defined trace followed by `False`, never
//// a crash: a script that dies inside a library cannot say why. `traceFalse`
//// is that report. It covers only those paths: genesis, the unmatched arms
//// of the validator and the `expect`s of the `Modify` decision (a malformed
//// continuation, an invalid proof no named refusal covers) still crash. `depositReturned` and `refundShort`
//// are the one construction site of the reasons `deposit-returned` and
//// `refund` for every registry owner that emits them, so a test asserting
//// either reason asserts the value the validator traces.
////
//// ## Dependencies
////
//// Imports nothing from this project. `state`,
//// `registry/discharge`, `registry/settlement` and `registry/modify` import
//// it; it imports none of them, so it sits at the bottom of the registry's
//// dependency order.
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
//// - The reasons `deposit-returned` and `refund` are spelled here and
////   nowhere else in the state validator's owners.

/// Report a refusal: trace `reason` once and answer `False`. A refused
/// `Modify` in the spend handler and every refusal of the custody spending
/// path answer through here, so exactly one user-defined trace names why.
pub fn traceFalse(reason: String) -> Bool {
  trace reason
  False
}

/// A payment the fold owes a payee is short, misdirected or missing.
pub fn depositReturned() -> Option<String> {
  Some(@"deposit-returned")
}

/// A custody refund is not paid to the address its custody recorded.
pub fn refundShort() -> Option<String> {
  Some(@"refund")
}
