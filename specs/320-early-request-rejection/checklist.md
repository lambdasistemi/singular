# Requirements checklist

## Specification quality

- [x] The story names the actor, the action and the observable outcome.
- [x] Every requirement cites the Lean definition it follows, or is marked as a validator rule outside Lean.
- [x] Success and refusal are both specified, including who signs and who is paid.
- [x] Each invariant names the layer where it can fail and what failing looks like.
- [x] Unchanged behaviour is listed explicitly, not implied.
- [x] The consumer conflict is preserved as unmet, with its exact source revision.
- [x] No requirement depends on a decision that is still open. The early-reject row scope is settled: the new row CG24 and CG23's two timing sentences.

## Evidence quality

- [x] RED is behavioural and on the base. Setup and decoding failures are excluded.
- [x] Each live claim has a ledger transaction behind it. Each refusal reason has a compiled test that names it.
- [x] Model comparison goes through the existing story language, not a per-theorem projection.
- [x] Every gate row is a verbatim CI command, with its workflow line.
- [x] Every nested nix invocation and devnet boot is counted.

## Scope

- [x] Every caller of the old rule has a disposition.
- [x] Every identity pin the repair moves has an owner and a generator.
- [x] Forbidden paths are listed.
- [x] Historical receipts and the published book are not rewritten.
