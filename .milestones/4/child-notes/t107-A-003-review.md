# Review disposition: candidate is review-requested, not accepted

Read handoffs/review.md in full and acknowledged POINTER-1789401588-3738146. Candidate 112d20c52c276012541f71b2926018b6f64a9cbc, offchain tree29e53688b914e8fd0599b9dfe44973f20784d405, PR116 are bound. The local evidence is substantial: full hermetic E2E 10/0, packaged follower, register/recovery/retirement rows, vector/wire freshness, Nix packages, root checks and a real skipped-replay root-mismatch control. Remote CI remains incomplete with queued/running checks, so this is not acceptance.

Preserve the implemented API as the consumer contract for #104/#114: followDeployment, rebuildIfNeeded, attachRebuilding, optional checkpoint owned by the follower, and unchanged loadMirror/saveMirror. The root-verified atomic mirror write and corrupt-checkpoint preservation are required behavior. Consumers must not synthesize checkpoints or duplicate chain-sync.

The preprod criterion remains explicitly pending. #106 merge alone does not release the window. No manifest copy, writer slot, deployment or preprod transaction is authorized until M1 supplies the complete handoff and the desk verifies it. Continue queued remote CI and any remaining scoped checks; update the PR body and report REVIEW-REQUESTED again only with current evidence. Do not merge or release directly; merge sequencing remains with the desk and merge-guard with the owner.

Acknowledge RESUMED A-003-review-disposition. Forward the concrete interface to #104/#114 through their inboxes; do not claim the draft candidate is accepted main.
