# NOTE-039: Consolidated gate findings and #70b decisions

Keep current ownership and no-extra-auditor staffing. There are concrete next actions in both existing workers before #87's slot opens.

## #70b: resolve the already-filed questions now

Root read Q-001-ci-green-vs-held-rows-session-exit.md and Q-002-held-row-receipts-clobbered-by-their-controls.md in full. These are implementation/brief decisions within your authority, not new user design questions. The worker correctly refused to ship misleading receipts.

Authorize the receipt repair and a fresh clean-tip run: a negative control must not overwrite the main row's accepted/held observation. Preserve main and control outcomes with distinct identities and retained logs/attribution; the proposed no-main-row-write control helper is acceptable when the control remains independently evidenced and cannot silently fail. Keep historical overwritten receipts and describe their defect; never relabel them as fresh proof. Check the write path actually discriminates a deliberately clobbered main receipt.

For ordinary incremental CI, accept an explicit expected-debt assertion over actual session results, with an exact current held-set and no unexplained failures, while strict completion/release stays RED on that debt. Correct swapped recordHold arguments. Do not use a bare nonzero exit or grep of an error label as success: build/setup/unknown/crash, extra/missing rows or an unexpected verdict must fail. Distinguish a green regression check from fulfilled consumer promises in workflow/docs.

The question's proposed four-held-row list is stale: CG13 registry-owner pinning is resolved-by-ruling, with defect history; it is not a fourth unresolved user decision. Reconcile executable bookkeeping with that ruling, retaining its row/history and no false coverage. CG11/CG12/CG19 retain their actual unresolved consumer-contract dispositions. Any independent CG13 application requirement needs its exact Lean clause and a separate story, not revival of registry ownership.

## #80: current publication repair still has boundary gaps

Root inspected the evolving draft, not a frozen submission. In the first version read, expect_blocked accepted TIMEOUT. The file then changed while root was preparing a probe; the failed extraction is not behavioral evidence. Root froze the subsequent source and executed its EXACT expect_blocked helper in isolation: command-not-found exit127, timeout exit124 and unexplained exit1 with empty output all print HELD and leave CASE_EXIT=0. Evidence path is recorded in root handoffs/publication-v2-probe-path.txt; read its source/result/raw outputs. This establishes a classification defect in that helper, not a full publisher execution.

Resolve the full mechanism before submitting:

1. Only an actually reached, correctly attributed coverage refusal may satisfy a negative boundary case; missing command, timeout, build failure and empty output are errors, never HELD. Retain raw subprocess exits and require the expected gate result for each case.
2. The positive case must reach the recording replacement for the real final external publication operation. Aborting at assembly, or grepping `onchain` in output, proves at most an earlier stage. Supply runnable fixture assembly or narrowly controlled final external stubs so the actual publisher path executes. A gh log that is always empty cannot prove positive publication reachability.
3. Bind activation to the actual candidate object/configuration and enforce candidate identity/cleanliness before choosing the gate. Testing `-f $PWD/conformance/coverage/release-required` can be bypassed by deleting that working-tree file before the coverage gate gets to inspect dirty state. Preserve independent ordinary-docs policy; do not activate the global gate prematurely. Test marker deletion, stale/wrong cwd/candidate and direct invocation after integration.
4. The current mutation edits the LIVE provider nix/release.nix and restores only on the happy path. Run source mutation in a frozen disposable provider copy, with process cleanup and preserved baseline; never mutate the active worker tree. Prove the altered guard reaches the invoked wrapper.
5. Retain the guard-removal control, but do not let it replace the positive final-boundary test or expected-failure attribution. Keep all previously rejected versions. Freeze final source/command identities, then perform one complete real-path verification before returning the candidate.

## #87 inventory correction before implementation

The preimplementation inventory currently lists only onchain/validators. M1 also ships naming-onchain validators/policies. Include all production blueprints/titles from BOTH partitions and their applicable naming/lifecycle invariants, not just the copied generic registry. Keep a single full Lean declaration inventory, adding a separate compiled-invariant debt axis per applicable obligation. Missing applicability stays debt; the first ownerless/fold slice is not the full denominator. A working reference bridge is not inherited evidence.

Respond with the decisions delivered to existing workers and the concrete execution/result they will next produce. No additional packet-review round or new auditor is requested.
