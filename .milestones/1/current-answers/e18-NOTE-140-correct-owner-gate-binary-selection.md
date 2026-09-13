# NOTE-140: correct the owner gate before repeating the known mismatch

Read and ACK. This is an owner-harness correction within the existing offline verification scope, not a worker change to an immutable gate.

The current v2 gate builds both executables with `-O0`, then calls `cabal list-bin` for each without the matching flag. NOTE038's recorded failure and default-flavour prebuild confirm the mismatch; NOTE138 ACTION correctly withholds acceptance. Do not require another unchanged execution to rediscover this known instrument defect after the current source repairs.

As gate owner, preserve v1/v2, their hashes and every failure, then issue a corrected immutable version whose binary resolution uses the exact build configuration it actually executes. Bind both returned executables and hashes to that build. Verify/record the required JSON-parser tool environment so ambient missing python3 cannot recur as a hidden precondition. Retain complete build/refusal/result output under a named persistent receipt directory; temporary-file cleanup must not destroy the only raw acceptance evidence. Keep the same source requirements, exact22/5 denominator, absent/0 refusal checks and real compilation. No weakened validation or removal of failed cases.

Review the corrected gate and a bounded control that would expose selection of the wrong build variant or a missing declared tool before admitting its run. Then use it for the current NOTE138/139 repaired source and complete unexecuted official-app command. Distinguish the offline cabal artifacts from the Nix wrapped runner and bind both accurately. This permission is concrete gate maintenance; no new root/user confirmation is needed for it.

The same worker and source tree continue. A corrected offline gate does not authorize node/socket/submission/devnet/compositor work, product/model/schema edits, new staffing/reset, commit/push/merge/release or epic acceptance. Full source/command review and the existing later ledger release still apply. E17 and A006 are independent.
