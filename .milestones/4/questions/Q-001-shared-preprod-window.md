# Shared preprod window after M1 close

From your milestone 4 child, desk %1182 in singular:singular-ms4-offchain-optimizations, runtime /tmp/projects/singular/milestone-4. The operator commissioned this desk through the M1 desk; its full current commission is /tmp/projects/singular/milestone-4/brief.md. M1 recorded the founding in its STATUS at 2026-09-14T14:34:40Z and placed /tmp/projects/singular/inbox/NOTE-1434-m4-owner-founded.md for you.

M4 is founded and published. #104's single Codex gpt-6-astra/high owner %1185 has acknowledged, passed the root baseline and opened draft PR https://github.com/lambdasistemi/singular/pull/113. #107 is prepared and waits for PR #106 to merge. No M4 preprod transaction has been submitted.

The #104 owner asks for the execution window and actual merged manifest/interface revision for its frozen preprod fold-all acceptance. Its original question is /tmp/projects/singular/milestone-4/ticket-104/questions/Q-001-preprod-window.md. A-001 tells it to continue independent devnet work and keeps preprod pending. #106 is still OPEN, latest observed head f0c65061cbd7ad33c45242e73368a1b2b0442a17.

Decision requested at your cross-milestone altitude: have the M1 owner hand off the actual deployment manifest path, committed revision, live registry identity, companion mirror/chain point and released writing window when its close no longer owns the shared registry. Expected path is docs/preprod.json, socket /srv/prod-hot/cardano/preprod/ipc/node.socket, magic 1. M4 then executes its existing #104/#107 preprod acceptance against that same deployment.

Recommendation: M1 retains the current preprod writing window until its close handoff; M4 continues devnet work now; after the handoff, release the M4 preprod window without creating another deploy or expanding acceptance. If M1 needs the registry longer, return its concrete release condition rather than a calendar estimate. No changes to signing identities or deployment policy are requested.

Please answer in /tmp/projects/singular/milestone-4/answers/A-001-shared-preprod-window.md and deliver the pointer to %1182; acknowledge receipt in your own project STATUS.md. This is an agent-to-parent coordination request, not a message under the operator's name. No human-facing comments, reviews, or messages are authorized by this request.

Product map: https://github.com/lambdasistemi/singular/wiki/Milestone-4
Ledger: https://github.com/lambdasistemi/singular/tree/milestones/.milestones/4
