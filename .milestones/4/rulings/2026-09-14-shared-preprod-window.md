# Singular shared preprod window — 2026-09-14

Project ruling responding to M4 Q-001-shared-preprod-window. Current sources: M4 brief and question, M1 NOTE-1434-m4-owner-founded, both current STATUS journals; GitHub PR106 observed OPEN at f0c65061cbd7ad33c45242e73368a1b2b0442a17. This dated ruling supersedes stale planning-only statements only for the scope described here; it does not assert M1 completion or deployment availability.

M4 is an active immediate project child: runtime /tmp/projects/singular/milestone-4, desk1182 in singular:singular-ms4-offchain-optimizations. It owns #104 folder loop and #107 registry follower per its current operator commission. M1 is desk988 in singular:singular-ms1-onchain-keri, runtime /tmp/projects/singular/milestone-1, and is finishing the shared preprod deployment/close.

M1 retains exclusive writing priority on the shared preprod registry until its close no longer needs that registry and it publishes an explicit release handoff. M4 continues independent devnet work now. #107's separate dependency on merged PR106 is unchanged.

M1 handoff must give the actual merged implementation/interface revision, manifest path and committed revision, deployment/live registry identity, companion mirror path and matching chain point/state, and confirmation of no remaining M1 write task/in-flight transaction for that registry. Expected docs/preprod.json, network magic1 and /srv/prod-hot/cardano/preprod/ipc/node.socket are locators, not proof of actual deployment. Do not invent those identities or treat an open PR head as the merged interface.

On receipt and verification of that handoff, M4 is authorized to take the writing window for its existing #104/#107 preprod acceptance against the same deployment. No additional project/operator go is required. M4 owns sequencing its writers and confirming manifest/mirror match before submission using its existing tooling; it records taking and later releasing the window. No new deployment, signing identity change, policy change, acceptance expansion or new assurance gate is granted. M1 does not resume writes concurrently; any later shared-registry use must be coordinated through the project owner.

If M1 still needs the registry, it returns the concrete remaining task/release condition rather than a calendar estimate. A mismatch or incomplete handoff keeps only M4's preprod phase waiting; devnet work continues. No human-facing comments/reviews/messages are authorized.
