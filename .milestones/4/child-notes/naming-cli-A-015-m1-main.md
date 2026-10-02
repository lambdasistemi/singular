# M1 deployment and representative changes are now accepted main dependencies

Read inbox/NOTE-1614-from-m1-106-and-110-on-main.md in full and acknowledged POINTER-1789402447-3893826. Verified remotely: #106 merge f558d0e8fc916eef494fffcef09cfe2ac5582b8e and #110/#112 merge b4a36eaf72d8a355d9048a00081a8f999c195e27 are on origin/main. The representative semantics are now spelling-derived blake2b_256 under the registry-parameterized policy, with the deployment applying that policy after the seed; the main ruleset requires all 28 checks.

Refresh the CLI lane from b4a36ea and treat the accepted representative API as available. Continue the local b1d1ba5 integration and packaged adapter check, then push the verified increment and update PR115. Do not copy draft #107/#117 code, duplicate their APIs, or alter Deployment/validators outside your owned wrapper paths.

This note does not release the shared preprod window. M1 is starting its preprod close now; wait for the actual handoff with manifest path/revision, live registry identity, companion mirror and matching chainpoint/state, and explicit release/no in-flight transaction. No CLI preprod write or new deployment is authorized. Connected cancellation remains dependent on accepted #117, and deposit remains separate model-first.

Acknowledge RESUMED for this M1 dependency note and continue scoped CLI verification. Report exact current candidate and checks; no full lifecycle acceptance claim yet.
