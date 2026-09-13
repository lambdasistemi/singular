# Resume Singular M1

Updated 2026-09-13T05:35:00Z. Active goal: finish E17 and E18, then STOP.
Both epics are INCOMPLETE. The latest goal turn is PROGRESS: a root
actual-handler control confirmed a foreign-policy retirement flaw, E17
acknowledged the repair, E18 received its consolidated continuation, and the
wiki now separates ticket state from user-story state.

The prior full resume is preserved byte-identically at
handoffs/resume-before-20260913-0535.md, SHA256
e62e9bf06e972d3359a7b026b2a86292d71ecd3def61b89318b35daf584220aa.
Use this file as the current state and the archived file only for history.

## Stakeholder outcome and reporting

Speak in user stories and observable outcomes. Do not ask the stakeholder to
manage implementation decisions or report internal “decision pending” prose.

M1 succeeds only when exact cardano-keri can obtain and use a versioned
on-chain Singular release that provides:

- real claim, unfulfilled-Insert withdrawal, payment-destination maintenance
  and precommitted control recovery;
- controller and fixed-quorum retirement into custody;
- permissionless completion to permanent Over, with authentic representative
  destruction and withdrawal, resolution and reuse refusals;
- one authentic registry, with copied or foreign registry substitution
  refused;
- real cardano-keri registration and operations with authentic proof-token
  lifecycle, evidence, allocations, payments, refunds and vetoes;
- exact full hypotheses, domains, quantifiers, both directions and full
  result/post-state agreement at both actual implementation layers;
- production-built Blaster validation for issue 87 and the 192 source-derived
  obligation baseline with zero hidden exemptions;
- reproducible, obtainable artifacts and a successful new-operator run.

Epics 15 and 16 are closed. E17 and E18 are the final epics. Grok owns E17;
GPT Sol owns E18. Stop after both are fully accepted. Issue 14 Scalus,
factoring, M2, later epics, deployment and a new service are outside this
goal. PR 67 release remains held.

The current wiki is
https://github.com/lambdasistemi/singular/wiki/Milestone-1 at commit
47359d2689c9d54a7cd0c70254950fd2d12df9fa. Register SHA256 is
86c545a848561ba9f03e17c3b811a75a62d821ed66800de1239cb1b6fe6eaaa3;
page SHA256 is
9f0a0b58597a5e628cfd6f28c563d7131be4eccc8c31afa2e86f8ff831522f4b.
It was reconciled at 05:30Z from the live milestone issue inventory: 36
tickets total, 26 closed and 10 open (17, 18, 68, 71, 74, 77, 78, 80, 81,
87). The 27 user stories are 6 delivered, 2 landed, 7 under review, 6 in
progress, 2 blocked and 4 standing. Ticket state and story state are separate.
Receipts are handoffs/wiki-reconciliation-current.json and
handoffs/current-outcomes-wiki-published.json.

## Authority and fences

Accepted Lean authority:
13231f58833b8feb57f4b0f9b1117bfcfba0c07d, tree
dd9e508bb11108c5c459fcf8e59e3dd1930eead6.
Bound cardano-keri consumer:
14a64a4681d3e429fab5877062b5c476c2a4bfe2.

Answers A-001 through A-006 remain authoritative:

- empty processing refuses; legitimate nonempty all-rejected, mixed and
  zero-net processing remains;
- SPO selection and existing batch earnings are accepted assumptions;
  expanded starvation, fairness, takeover and new-fee work is outside M1;
- Claude use stays restrained;
- Grok/Sol own the final epics;
- finish both epics and stop;
- the rejected-fold formal work is a candidate only, with no accepted-model
  adoption before full review.

The stakeholder authorizes ongoing wiki/recovery publication and root
disposable falsification controls. Root supervises immediate epic owners only,
never their ticket owners or implementers. Four existing implementers only:
no new native worker, auditor, Claude seat, reset, lost history or reset
counter. Preserve all failures, logs, worktrees, contexts and counters.
Timeout is neither process death nor permission to resend.

No upstream rewrite, dependency refresh, Scalus, extraction/indexer service,
deployment, waiver, silent acceptance, push, merge or release. A green build
is bounded evidence, not acceptance.

## Live owner identities

- M1 desk: pane %988, tmux session singular, cwd
  /tmp/projects/singular/milestone-1.
- E17 Grok 4.6: pane %913, PID 568965, startTicks 150360890, runtime
  epic-17/owner-grok-20260912, journal epic-17/STATUS.md.
- E18 gpt-5.6-sol high: pane %914, PID 568968, startTicks 150360894,
  runtime epic-18/owner-sol-20260912, journal epic-18/STATUS.md.

Existing implementers remain:

- %990 Muse, PID 3808876, startTicks 147649748,
  /code/singular-e17-issue-77, runtime epic-17/ticket-77/commit-owner-2.
- %995 GLM, PID 72262, startTicks 149321186,
  /code/singular-e17-issue-81, parked with 83b359f staging repair.
- %994 GLM/Pi, PID 4182517, startTicks 149071436,
  /code/singular-e18-exec plus /tmp/t80e-rival-witness, same native session
  01a09695-c87b-725c-9576-c0d6e9231e3c.
- %993 Muse, PID 4052478, startTicks 148440131,
  /code/singular-e18-blaster, uncommitted A006/#87 formal work.

Native %994 was compacted exactly once under NOTE-134 while preserving the
same PID, session, history, provider and model. Do not reset, recompact or
publish raw native history.

## Frozen cross-boundary contract

NamingDatum has four fields and is double wrapped. Retire is constructor 3
with representatives and the original 28-byte creation key hash.

The representative asset name is:

Rep || blake2b_224(state policy || cage token name ||
original creation payment-key hash) || incarnation.

The preimage uses the state policy, while the asset itself must be under the
state datum's configured representative policy. Current controller or fixed
quorum authorizes retirement. Original creation material must be recoverable
from public retained transaction evidence without the old secret or a hidden
fixture.

The authentic state NFT has exact quantity one and the same spent/reference
predicate. Generic State carries the consumer hash in field six. Every
nonempty Modify, including all-rejected and zero-net, invokes and preserves
that exact withdrawal. Empty processing and surplus actions refuse. The
generic layer admits correct checkpoint/refund flow; the actual consumer
judges operations, evidence, allocations and veto. E17 must hand back the
coherent ABI vectors and full applied/unapplied identities before E18 migrates.
No final tuple has been released.

## E17 current state

Current E17 implementation HEAD is
27e5f9a34f2a96356ce319885d5d0acc282dba62 over 954928c. It is an intermediate
candidate, not accepted.

The connected candidate now demonstrates real claim, recovery, recovered-key
maintenance and old-key refusal; controller and fixed-quorum retirement into
custody; public original-creation readback; a connected singleton retirement
Update to Over; custody consumption and burn; completed readback; withdrawal
and replay refusal; retired-name reuse refusal with a fresh-name positive.
The handoff is
epic-17/ticket-77/commit-owner-2/handoffs/note-027-031-over-journey.md.
Every preceding failed LO01/LO02/burn/rejection/readback exhibit remains
preserved.

E17 is still unsafe. Root copied the actual current state, request, consumer
and retirement-custody handlers into a disposable Aiken project and executed
one value-balanced singleton Active-to-Over context. The exact five-test run
passed 5/5:

- authentic representative-policy completion accepts;
- a foreign-policy token with the authentic representative name also accepts
  all four executing handlers;
- wrong-name, missing-burn and missing-hook controls refuse.

The authentic representative policy has no mint and need not execute, so the
real representative can remain live while the registry becomes Over.
Mechanism: retirement_custody.burned_of matches only the name and drops the
held policy; consumer.check_rep_mints observes only positive mints under the
configured representative policy.

Root receipt:
handoffs/e17-root-foreign-policy-control.json, SHA256
fcc23b8b03994bc2937c0c881ff4e4d99a26ed83b6273f7d1fad94dc33ebc47b.
Raw log and source are adjacent. The first durable-log invocation from the
wrong cwd is preserved separately as setup failure with no semantic credit.

NOTE-095 was durably acknowledged by E17 at 05:29:55Z. The same %990 worker
acknowledged downstream NOTE-032 at 05:30:51Z. It must bind the custody-held
and burned complete policy/name/quantity identity to the spent state's
representative_policy, keep the authentic positive, make the exact foreign
witness refuse at custody, and supply a policy-equality deletion mutant. Then
rerun the affected connected Over journey while retaining legitimate
all-rejected, mixed, zero-net and unspent-custody cases.

LT04 is ruled as the user outcome: any ordinary user can complete retirement
without controller or quorum approval. Required signers must be empty; exactly
one fresh ordinary fee-input-owner witness outside every privileged route is
allowed and expected. Never claim an empty witness set or “no signature of any
kind.” E17 recorded Q-002 resumed.

After the asset-policy repair, E17 still owes LX01/N2 actual control modes,
integration and acceptance of the 83b359f lone-fork staging fix, complete
final gates and the exact applied/unapplied ABI tuple. Root reviews the final
cross-contract tuple before E18 migration. No merge or epic acceptance yet.

## E18 formal state

The 192 source-derived obligations remain the denominator: 109 manifest plus
83 discovered. The earlier 188/188/11 result remains incomplete; zero
exemptions. The source/clause checker itself passed its bounded 3-positive and
17-negative review. That is checker acceptance only.

The current rejected-fold candidate is
b8a1ffef16e50990b7bc57d35197c879ce6a251b90e211a227f91f25380992da,
with Corr.lean SHA256
e677e457fd3392a5d9b81bfb8703069e1411a5ac62899d9d1a5bc7e5bb5daf7f.
Root independently built its arbitrary-list two-way FullCorr proof with full
result/post-state hypotheses in Lean 4.25. The corrected RootCorr and
RootWitness builds each exited 0 with nine jobs; thirteen declarations carry
only propext, Classical.choice and Quot.sound, with no sorryAx. The initial
root package missing its dependency roots is retained as setup failure.

RootWitness proved the old sZNBase, sCBase and sRel fixtures are not Reachable:
they violate accepted reachable_inv/WellFormed by holding representative
supply with no Active registry entry. Their finite computations are diagnostic
only.

The same %993 worker then supplied:

- Reachable.initial histories for mixed processed/rejected, delete-then-insert
  zero-net, and funded unspent-custody cases;
- FullCorr witnesses for those histories;
- a selected rejected request plus distinct unselected custody where funding
  both accepts and omitting only the orphan funding returns exactly
  custody-unassociated;
- proof that every other premise holds and no FullCorr result exists for the
  orphan;
- a guard-erasure mutant that makes the exact orphan negative accept.

Handoff:
epic-18/t87b-blaster-refinement/handoffs/note038-admission-orphan-result.md.
Current exact sources match the handoff hashes recorded in NOTE-152. This is
candidate-internal formal evidence under review. It is not accepted-model
adoption, actual Aiken correspondence, KERI instantiation or production-built
Blaster.

NOTE-152 was delivered once to E18. Its durable ACK was still pending at the
last journal read; the live Sol pane was executing one Nix-bound owner review
of the formal handback and had observed candidate, orphan-mutant and retained
mutant exits 0. Do not resend while that turn remains live. If the review
holds, Sol may authorize the same worker to make one local preservation commit
with all limitations intact, then continue #87 toward actual production-built
program validation and the full 192-row zero-debt result.

## E18 rival registry and real consumer

Product /code/singular-e18-exec remains clean at
0100012b1afa318df3bae6cf40d6d9ee3507110e. The rival witness lives in isolated
/tmp/t80e-rival-witness. The one authorized real three-variant command is
finished and frozen forever under handoffs/rival-ledger-results: each variant
failed during setup, target transactions zero. It is not acceptance or
refusal evidence and must never be overwritten or replayed.

The existing %994 worker repaired the offline path to use the production
seed-to-token derivation and a script-free mintless body, and added separate
body/full signed boot and target encodings plus detailed UTxO evidence and
honestly named post-confirmation record/custody/state queries. It stopped
honestly at 04:05Z with NOTE-053 incomplete. Remaining exact work:

1. full-signed-transaction round-trip versus body-only loss control;
2. serialized TxOut round-trip plus address/datum-loss control;
3. boot-body-input-derived references with only the configured seed changed
   in the negative;
4. changed-source Nix rebuild and source closure rebind;
5. fresh frozen index and self-contained unexecuted three-case command using
   a new absent guarded result root.

The failed placeholder control is retained with no credit. NOTE-152 directs
Sol to rearm the same %994 worker in the same Pi session/history, with no
reset/recompaction/new seat/model/counter. There is no second ledger grant.
No node, socket, query, submission, wrapper or result-root creation until the
complete offline packet is reviewed and root explicitly releases one command.

After that bounded packet, E18 still owes the full outcome: genuine
rival-registry result, actual cardano-keri registration using state/request/
adapter/bound checkpoint/lifecycle/hash-proof programs, authentic proof-token
acquisition and burn, correct payments/refunds/vetoes and precise refusal
attribution, reap receipt issue/burn, dormant rotation/revival,
conviction/duplicity, full two-layer correspondence, production-built
Blaster, versioned artifacts and new-operator replay.

Retirement-completion correspondence and final producer binding remain open
until E17 kills the foreign-policy witness and releases its final tuple.

## Immediate continuation

1. Observe E18 NOTE-152 through its immediate owner journal. A timeout is not a
   failed delivery; verify the same Sol PID/session and do not resend if its
   native turn is active.
2. E17 is already rearmed. At its next transition, verify the repaired custody
   source binds policy/name/quantity and that the exact root foreign-policy
   witness is killed without weakening the authentic positive or legitimate
   batch cases.
3. E18 owner completes its one formal review, commits the bounded tranche only
   after review, and rearms same %994 for the four named NOTE-053 omissions.
4. Review the complete rival offline packet before any second ledger command.
5. Continue both full epics beyond these slices. Do not stop at their current
   handbacks.
6. Publish the next wiki/recovery sweep on a material transition or around
   06:30Z, not for every journal line.

No root tool session is currently running. All previous send-pointer and build
handles are closed. Preserve current panes and evidence.
