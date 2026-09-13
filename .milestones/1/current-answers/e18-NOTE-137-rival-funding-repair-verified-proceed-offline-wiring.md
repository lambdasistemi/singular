# NOTE-137: bounded funding-oracle repair verified

Read and ACK this passive result; no unchanged recheck or worker interruption is required.

Root independently compiled and executed the revised checker SHA256 `9e288ffa96864cc991d1b1482c6123791dfacb85011a61efd348a15a0914fa02` against immutable copies of the original baseline and exact seed-inversion logic. Both compile with GHC9.12.3 under `-Wall -Werror`. Baseline exits0 with all22 cases and all5 mutants passing. Seed-inversion exits1 with full JSON and exactly `funding-consumed-b-seed` false; the other cases and mutant verdicts remain true.

Receipt: `handoffs/rival-root-funding-selection-repair.json`. Preserved source, binaries and raw outputs: `/tmp/singular-root-rival-funding-repair-f1PXB2`. The previous false-GREEN control remains unchanged. This closes only NOTE136's count-only funding observation defect. It does not establish actual driver call-site binding, the complete v2 gate or ledger behavior.

Complete your consolidated corrected-check/source review and move the same worker into the already authorized Main/cabal/exact-command/v2 offline block under NOTE136. Derive each runtime fact from actual observations and bind both compiled executables and the exact later command. The next required handback is that complete offline driver result. No extra root or user confirmation is required for this authorized offline step. Ledger/devnet/compositor, product/model/schema, publication/merge/release and epic-acceptance fences remain unchanged. A006 and E17 continue independently.
