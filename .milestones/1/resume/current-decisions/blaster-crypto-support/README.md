# Read-only upstream crypto support evidence

Source inspection at 2026-09-12. No compatibility build or Singular execution is established by these files.

- Current pinned PlutusCore17cee18 lacks crypto dispatch (read in the local pinned package).
- PlutusCore ed3126b6a2f5cc32bd151fdefb26e66dcf514888 supplies Blake2b_256 dispatch and an opaque definition with executable Cryptograph.Blake2b body; its manifest resolves Blasterc576289cb55412b359411d6c89568f95af50730c, Lean4.24.
- CardanoLedgerApi5dab3c43f042b8735b6d067223baaa8d32ed28a1 resolves PlutusCore4ef48606303c45225d3ed2e2a87fc50280a763b7 and Blaster59db213ca6396269d2606b7dd9ac2bc26ae7c4ce, Lean4.24.
- Additional inspection: PlutusCore4ef48606303c45225d3ed2e2a87fc50280a763b7 ALSO dispatches Blake2b_256. Its own manifest resolves Blasterc576289c, differing from the Cardano manifest. Files prefixed 4ef- retain that evidence. This is a smaller manifest-linked candidate than arbitrarily mixing latest packages, but compatibility is still an executable question.

Choose and record a coherent resolved tuple in an isolated probe under NOTE056. Do not claim opaque hash reduction or quantified proof support from an executable definition alone; check the actual execution and symbolic path. Do not use this evidence as deployment identity or to waive failed/unknown claims.
