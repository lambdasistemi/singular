# Ticket 107 candidate review

Candidate: 112d20c52c276012541f71b2926018b6f64a9cbc, draft PR https://github.com/lambdasistemi/singular/pull/116. Base: f558d0e8fc916eef494fffcef09cfe2ac5582b8e. This is a product candidate, not ticket acceptance.

## Frozen outcome mapping

1. Node replay: `Singular.Registry.Follower.followDeployment manifest socket` uses the already pinned chain-follower interface and node chain-sync client, recognizes the recorded bootstrap and seed, follows state-token spends, decodes consumed requests and ledger-ordered Modify actions, and replays insert/delete/update through the existing trie. A manifest has no bootstrap slot; the first run therefore scans from chain origin and begins registry replay at the recorded bootstrap.
2. Verified persistence: every replayed fold checks its resulting root; final node query requires the same still-live state output and root. Only then does the atomic mirror writer rename a new mirror into place. Named failures preserve the existing mirror.
3. Attach: `attachRebuilding` supplies `--rebuild` in existing registration/recovery/retirement writer entrypoints. Missing or mismatched root triggers full bootstrap replay, including when an existing checkpoint is corrupt.
4. Incremental: optional checkpoint carries exact deployment, point/hash, observed state output and outstanding requests. Legacy mirrors still parse. Ordinary saveMirror calls explicitly invalidate a checkpoint. Same-point initial rollback is a no-op; earlier rollback resets to origin.
5. Devnet/CI: `cd offchain && nix develop --quiet -c just follower-e2e`; workflow Registry/follower. Real node test deletes a populated mirror, rebuilds, resumes a request created before the checkpoint, refuses and preserves corrupt mirror bytes, repairs via attach, and accepts a subsequent machine-B fold.
6. Onboarding: second-machine paragraph now gives deployment follow, with an updated diagram/speech companion.
7. Preprod: NOT YET OBSERVED. A-002 says complete M1 manifest/mirror/chainpoint/release handoff is absent, so desk cannot assign the writer slot. No submission, copied manifest, new registry or identity was attempted.

## Evidence already complete

- Root CI: evidence/root-ci-27ed04f.log/.exit = 0; subsequent candidate only removes two HLint hints in offchain.
- Named packaged follower check: evidence/follower-packaged-af42d88.log/.exit = 0, 1 example 0 failures, 68.0695s. The final candidate's full-suite log also reports the follower scenario green.
- Meaningful node failure control: evidence/skip-insert-control.sh and accompanying diff, source/binary hashes, build/log/exit. Skipping the actual replay insert compiles but fails root-mismatch against chain root 2f43ae26b8a81727a4e36494029cc4c1435d42b2cbe0147ca77a5968b67d5f32. Original source restored. This tests the observable root boundary, not a canned refusal.
- Vector freshness: evidence/vectors-check-final.log/.exit = 0.
- Naming wire and live corpus drift: evidence/naming-wire-final.log/.exit = 0.
- Formatting/HLint: evidence/follower-lint-final.log = No hints.
- Nix deployment + three writer packages: evidence/final-runner-packages-2.log/.exit = 0. Deployment artifact /nix/store/nrcvrr1apcn3pp66501c2iv5yf1q9jar-deployment.
- Actual CLI refusal: evidence/deployment-cli-refusal.log/.exit = 1, names missing manifest before any wallet/blueprint loading.

Final full E2E passed, 10 examples and zero failures in 282.5507 seconds (evidence/full-e2e.log/.exit). Recovery and retirement row runs both passed (their *-rows-final.log/.exit receipts). Registration rows also passed (evidence/register-rows-final.log/.exit), completing local verification. All three affected writer runners executed their existing full devnet checks successfully. Remote CI remains in progress with 11 successes, 13 queued, two running and one skipped at the latest snapshot; no complete-CI claim. The preliminary remote snapshot is evidence/remote-checks-112d20c.json.

## Decisions and remaining authority

No protocol, validator, pricing-model or Lean changes. Lean binding f558d0e, Model.lean foldOne/foldItems/step. Existing ledger validation remains authoritative for transaction acceptance; the follower is a replay adapter and does not claim protocol revalidation.

Desk review must keep preprod acceptance pending until the same frozen manifest-only rebuild/fold story is observed on the existing deployment. Current main and accepted representative changes must be refreshed before integration. Merge requires green CI, frozen acceptance and desk sequencing, through merge-guard merge commit only. Existing pipeline owns release. No acceptance scope was widened and no additional workers/gates were commissioned.
