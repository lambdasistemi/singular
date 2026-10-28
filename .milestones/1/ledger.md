# Singular M1 milestone ledger

Snapshot 2026-10-12T13:01Z (main 6d2de3a5; #528 closed with the keri stub; #518 PR 2 merged; queue 575 > 578 > 577 > 585; release 574 held). Desk: Claude Opus 5.5 at pane %0 (relaunched after the host crash; was Claude Fable 5.1 at %2706), window singular-ms1-m1-owner, session z-singular-M1, runtime root /home/paolino/.orch-runtime/singular/m1 (journal STATUS.md there). The operator moved the seat here on 2026-10-09; the previous desk journal at /tmp/projects/singular/milestone-1/STATUS.md is history.

## State at 2026-10-28 17:00 UTC (supersedes the sections below where they differ)

M1 is the registry without pinned policies. Decided 22 October (epic #731) and narrowed on 26 October: Singular is the state of one application's keys and acts only at the fold; the request lifecycle, deposits, reclaim, cleanup, termination and money belong to the application, with open datum the shipped application. Closed as not planned on 26 October: protected rejection and request tags (#498, #495–#497, #529, #532, #668, #487, #488, #500, #519), the policy-pin checks (#678, #681), the bounded-contract and earlier-line epics (#507, #506, #396, #371, #310, #484) and #671. The ledger-level proofs moved to the assurance milestone; the M1 release states the ledger assumption as a limit instead (#747).

Main: the epic merged on 2026-10-28 (PR 763, d69ab005). Release **0.17.0** published on 2026-10-28 as a pre-release (tag v0.17.0 at deb4b5c9, 11 assets, the on-chain archive's identity check passes for 30 validators); its release page was rewritten for users. Earlier releases since the last snapshot: 0.12.0 (18 October, the vault), 0.13.0 and 0.13.1 (19–20 October, executables without Nix, readable release pages), 0.14.0 (21 October, Linux packages and Homebrew with the development node), 0.15.0 (21 October, payloads as plain JSON), 0.16.0 (22 October, the registry address; last release of the earlier contract).

Commands in 0.17.0: `singular registry create`, `singular wallet create`, `wallet address`, `wallet sign`, `singular submit`; `open-datum create`, `insert`, `fold`, `reclaim`, `cleanup`, `update`, `terminate`. Removed with the earlier line: `registry fold`, `reclaim`, `reject`, `address`, `describe`, `inspect`, and `open-datum inspect`. No key reader until #744.

Children of #731: #741 closed 24 October (model stated and proved). #742 on main and in 0.17.0, open for its acceptance walk. #743 in progress (removal of the old line from main, CI warnings PR 766). #744 started, Lean reader first. #745, #746 not started. #747 in progress; its body still names protected rejection and needs rewriting for the 26 October scope. #764 opened: port the end-to-end checks retired with the old command line, the negative host first.

Demo 1 still plays 0.16.0; singular-demo PR 34 moves it to 0.17.0. The review card #261 (22 October) is still open.

cardano-keri has its own milestone lane since 2026-10-28 and pins its Lean to the merged Singular main (cardano-keri PR 484); it adopts the new contract on a local test chain only.

Open M1 issues, each mapped to a story in the wiki register (Milestone-1-Stories.json): 764 747 746 745 744 743 742 731 729 717 682 672 624 623 503 490 486 359 335 334 301 300 261.

Not ready for mainnet until on-chain verification and an independent audit are complete; the documentation and the release page say so.




## State at 2026-10-18 15:10 UTC (supersedes the sections below where they differ)

Main abf2ad2e = tag v0.12.0, published 13:45Z and verified from its downloaded assets; the Demo 1 journey from the release archive is green at the tag (Registry dispatched on v0.12.0, run 39134307989). The release carries the vault, the external signer (#638 to #642) and #684 (2b of #491, merged 53ca21d1 on the desk's grant; Sonnet writer, one Codex Sol checkpoint). The goal of 2026-10-18 is met.

Lanes: t656 (#656 one-command rehearsal) running: writer COMPLETE at ad03526b, the ticket owner rebased it onto abf2ad2e and opens the pull request; the scene 3 chain refusal uses a test wallet of the negative host's own (A-001; vault signing for the negative host placed in #672). t406 PARKED after #684 (part 3 of #491 waits for a release: update, the pages, a row per signer, a devnet terminate from a token-only wallet). e498 PAUSED 13:54Z with #529 chunk 1 green at 0983711c on PR 692 (1.x integration branch). t642 COMPLETE parked. Everything else paused.

Next for the operator: the go for the preprod run of Demo 1 from v0.12.0 (Alice's vault, Bob's external signer); then the recording with `nix run .#demo1-rehearsal` once #656 merges.

## State at 2026-10-18 12:45 UTC (supersedes the sections below where they differ)

Main a1cb80cc. RUNNING: the operator resumed work on 2026-10-18 after the pause of 2026-10-17 20:21Z. Latest release still v0.11.0 (no vault); the release-please pull request 673 (0.12.0) is open and is regenerated as merges land. Merging it publishes nothing: push the tag v0.12.0 at its merge commit.

The wallet work is delivered. #490's signing design is on main except its last ticket:
- #638 vault (PR 647), #639 sign a bundle (PR 665), #640 submit (PR 674, 45cd8a75): merged before 2026-10-17.
- #641 registry write commands end in a bundle or sign from the vault: PR 675 merged 73e9c2c3, closed.
- #642 open-datum commands and the guides: PR 685 (open-datum signers, 4ba0f5b4), PR 688 (Demo 1 with wallets from `singular wallet create`, Alice from her vault, Bob externally; devnet `--fund-address`, 0b3c04c3), PR 689 (guides, a1cb80cc); closed 2026-10-18 09:13Z.
- #672 (retire `--wallet-skey`, move the harnesses to the vault, plus open-datum's key file, the bounded journey and the deployment tool): operator 2026-10-18: waits; not before the review.
- #334 widened by the desk with the deadline-free bundle defect (a staged member without an upper bound makes an unlandable bundle stop its wallet for ever; devnet reproduction) and an acceptance line. Ways out stated in the guides: `--seed` for create, `--state-dir` for the others.
- Per-registry admission (a pending bundle stops writes only in its own registry): M1 non-goal, stated in the guides.

Goal set by the operator 2026-10-18: Demo 1 released with the vault in it. Done when #684 (2b of #491) is rebased onto main by a fresh Sonnet 5.5 xhigh writer with one Codex Sol checkpoint and merged on the desk's grant, and the release-please pull request is merged with v0.12.0 pushed at its merge commit and the release archive's Demo 1 journey green at the tag. The preprod run of Demo 1 (Alice's vault, Bob's external signer) needs the operator's go.

Operator rulings 2026-10-17/18:
- Staffing, each for its lane only: #642 writer Sonnet 5.5 xhigh; #684 rebase writer Sonnet 5.5 xhigh (GLM's limit out until 2026-10-21 18:04Z); #656 writer Sonnet 5.5 xhigh. #641's writer was Opus 5.5 xhigh. Auditors Codex gpt-6.1-sol high.
- Deadline-free bundles: a stated limit now; fix under #334 (every staged member carries an upper bound), timing open.
- #672 waits. The key-file flag stays until then; a key file can be sealed into a vault with `age --encrypt --passphrase` (format-compatible, untested); an import command is not ticketed.
- #529 (request tag, protected rejection, 1.x line) continues as released 2026-10-17; #495-#497 stay paused.

Lanes:
- t406 (#491): PR 684 rebased onto a1cb80cc (one conflict in CommandRunSpec.hs; two WriteContext constructions adapted), review 001 approved at d73d021b by auditor-9; push and hosted CI next, then merge-ready and the desk's grant. Writer commit-owner-9 Sonnet (pane in window singular-ms1-t406-create-funding), auditor-9 Codex pane %662.
- t656 (#656 one-command rehearsal `nix run .#demo1-rehearsal`): released 2026-10-18 11:31Z; GLM writer retired by pid; writer-2 Sonnet pane %664 rebases bc481cb2 onto main and moves the scenes to the vault and external signer; nothing pushed yet. Target: record the play from v0.12.0 before 22 October.
- t642: COMPLETE and PARKED 09:13Z (pane %606).
- t641: COMPLETE, retired.
- e498 (#529 only): to-529-astra-1 writing, chunk 1 draft PR pushed at 21b5ec47 (hosted open-datum tests red: #642's new signer rows miss #529's required cost/width; the lane fixes it); questions Q-022..Q-026 answered or being answered inside the lane.
- keri-grounds: idle, verdict delivered (Codex gpt-6-astra medium, pane %648).
- Paused: #676/#679 (PR 683 at 57935f9d), #495-#497, everything else.

Open for the operator:
- The new devnet job "Registry bundles signed elsewhere and from the vault, stopped while pending, dead past their deadline": add to main's required checks?
- #334 timing (before or after Thursday; desk recommends after).
- The KERI study document rewrite around the final framing.
- A per-registry admission ticket after the review.
- The memory cap kills Chromium (`just browser`): host tooling.

Evidence pages: KERI study https://claude.ai/code/artifact/12b3915d-e498-493e-b074-da2ffa8431b5; verification https://claude.ai/artifact/5AW7ASTaoBzYDZmr3fG3im.

## State at 2026-10-16 11:45 UTC (update 13:40 UTC: PR 674 merged 45cd8a75, #640 submit delivered; #641 slice 1 accepted ed2f5c00, slices 2–6 released, ceiling Sat 18:00Z; #491 2b lines 1–2 closed, line 3 repairing a preview precedence regression) (supersedes the sections below where they differ)

Main 0ee8db63. Release **v0.11.0 published** (https://github.com/lambdasistemi/singular/releases/tag/v0.11.0; merging the release-please PR publishes nothing: push a lightweight tag vX.Y.Z at its merge commit).

Merged since 2026-10-15 12:30Z: PR 646 (#519 part 3, fold window), 648 (#398), 649 (#637), 647 (#638 vault), 658 (#491 part 2), 653, 657, 662, 664 (#650 closed-datum epic, COMPLETE), 665 (#639 bundle and `wallet sign`), 574 (release 0.11.0), 615 (#494 protected rejection in Lean + paper; merged by the lane without a desk grant, allowed by A-013).

Operator rulings 2026-10-15/16:
- Demo 1 is the 0.x series; the protected-rejection implementation is 1.x, built on a rebasing integration branch, merged after the 22 October review as 1.0.0.
- Retraction fee: the requester pays (Lean slice eleven, merged).
- "Not convicted" means active; terminal = convicted; unknown = not registered.
- closed-datum: a flag over open-datum, no Lean (declared limit).
- Staffing: GLM 5.3 for every coder seat from now on (M1-wide); #641/#642 ticket owners Opus 5.5; #640 writer Sonnet to its finish; auditors Codex Sol until Grok resets.
- Signing design (#490 split into #638–#642, #672): every write command ends in a bundle or signs from the vault; `submit` checks only transactions it will send.

Lanes:
- t490: #640 `submit` all audits passed at f8961512; push next; ceiling Sat 17 15:00Z.
- t641: #641 slice 1 (chained view) green f9ce888e; slices 2–6 after #640.
- t642: #642 plan final, parked until #641's slice-2 checkpoint.
- t406: #491 PR 2b writing (GLM), ceiling Sat 17 12:00Z; part 3 after.
- e498: parked; implementation waits (operator decision open).
- Unowned flakes: #659, #667. Rehearsal command #656 filed, unstaffed.
- Presenter's play: /home/paolino/.orch-runtime/singular/m1/demo1-play/play.md; page https://claude.ai/artifact/Rd4DxArW1qFfzc2XV8XWAC (v5).

## State at 2026-10-15 12:30 UTC (supersedes the sections below where they differ)

Resumed by the operator lane by lane. Main 939bfc64: PR 645 merged (#491 part 1: fold, reject and reclaim prepare a funding output; part 2 owes insert/update/terminate with the preparation shown in preview).

Operator rulings today:
- Protected rejection is off the Demo 1 critical path; its lane runs at its own pace (resumed by the operator directly, naming rulings NOTE-057..060).
- Signing: every write command ends in a bundle; `submit` checks witnesses; the vault is one signer; no executable state. #490 moved to M1 and split into #638 (vault), #639 (sign a bundle), #640 (submit), #641 (registry commands), #642 (open-datum and guides). Lane staffing: Sonnet 5.5 ticket owner, GLM 5.3 writer, Codex Sol auditor (this lane only).
- Providers: the devnet Koios fake leaves this repository; the provider interface moves to a new repository lockness-haskell, package lockness-ledger-client, no HTTP in the core; running the real Koios stack rejected; Koios considered a bad provider. Epic layout (24 tickets, 19 decisions) at /home/paolino/.orch-runtime/lockness/ledger-client-epic/handoffs/epic-layout.md, D1 pending with the operator. PR 644 (ledger client core as an in-repo library, filed outside the desk) awaiting the operator's word.

Lanes:
- e396: #519 PR 3, every checkpoint approved but the pre-push repair (mint guard counted foreign-policy mints); push after it, hosted CI as the gate (grind check ruled: no local just ci).
- t490: #638 vault core approved (001, 002-r1); S2 (flags check, docs, packaged controls) running past its window; grind check at ~13:00.
- e498: #494 slices 8a, 7b, 7c done and audited; continues.
- Cardano KERI hunter discussion seat (Opus 5.5, remote control) open for the operator; outside the desk.

## PAUSED 2026-10-14 ~17:00 UTC (operator; supersedes the sections below where they differ)

Order /tmp/machine/pausa/2026-10-14T1630-M1-singular.md. Main 7dbe3568. Merged on 14 October: PR 625, 626, 627 (#518 closed), 628 (#503 part two), 630 and 634 (#519 Lean). Rehearsal story on a local devnet published privately: https://claude.ai/artifact/DSfpBsPMp3cEHGUDdAufjq (recorder retired).

Paused lanes and resume points:
- e396: #519 pull request 3 (builder and receipt), local head 9cc40a69, review 003 BLOCKED by the Codex Sol auditor (ordering of token-missing versus edge-inadmissible); resume /home/paolino/.orch-runtime/singular/m1/epic-396/RESUME.md.
- t406: #491 pull request 1, local head 28b0c435 (builder, funding check, journal and receipt; review 004 pending), the devnet legs remain (one dirty file kept, patch copy saved); resume .orch/resume.md of the lane.
- e498: #494 local 59c303bb (slices one to seven rebased onto 7dbe3568, rebase review blocked on the recorded base; A-012 retires reject_reads_no_time); PR 615 green at 499160c6; slices eight to ten then the paper; resume RESUME.md of the lane.
- Auditors: Codex gpt-6.1-sol high until the Grok weekly limit resets.
- Open: #637 (rollback adoption-record flake, required check) without an owner; factory-check discovery prompt at /home/paolino/.cache/prompt-factory-check-discovery.md not yet handed to the machine owner.

On resume: wake e396, t406, e498 with a release note; re-arm the desk watcher.

## State at 2026-10-14 15:55 UTC (supersedes the sections below where they differ)

Main 7dbe3568: PR 628 merged (#503 part two; #503 open for follow-ups). The desk goal of 14 October is met: #518 closed (PRs 626, 627), page part two merged, wallet preparation dispatched, economic Lean rework running. Wiki 59c0c97.

- t503: ticket idle after merge; residual sweep and cleanup.
- t406: #491 PR 1, handoff after review 003 (decision (a), 15:32): fresh writer takes the devnet legs.
- e396: #519 PR 3 (builder and receipt) in progress, in parallel with #491 PR 1; first green merges first.
- e498: slice seven done; rebase onto 55a64aa9 paused mid-way on A-012 (CONTRACT: protected rejection governs; PR 615 retires reject_reads_no_time and replaces it with the fold deadline not governing rejection); slices eight to ten, paper after ten.
- Main Registry red at 55a64aa9 on the rollback adoption-record clauses: filed #637 (recurrence of closed #364), one re-run; owner to assign (fold lane owns the recovery controls).

## State at 2026-10-14 14:50 UTC (supersedes the sections below where they differ)

Main 55a64aa9: PR 634 merged (#519 pull request 2, window admission in the model). Both #519 Lean pull requests are on main; #494 rebases its fold slices onto them. #519 pull request 3 starts now in parallel with #491 pull request 1 (A-020; first green merges first). PR 628 (#503 part two) registry run red on the printed describe command, under repair. Wiki bf55556.

## State at 2026-10-14 12:05 UTC (supersedes the sections below where they differ)

Main d4f8d94a. PR 630 merged (#519 pull request 1 of 4, Lean). #519 released by the operator (option A) for Demo 1; no pull request of #519 moves a script identity, so no fresh preprod registry follows from it. Order: #519 pull request 2 (Lean) before #494 fold slices eight to ten; #491 pull request 1 before #519 pull request 3. Wiki 1f26732.

- e396: #519 pull request 2 next; model follow-ups filed as three issues in milestone Assurance refinements (A-019).
- t503: page part two, PR 628 draft (slices 6 and 7 accepted); slice 8 with muse-5 (muse-4 retired at capacity).
- t406: wallet preparation pull request 1, writer commit-owner-3 in phase 2 (builder done).
- e498: slice five-b (naming and structure review) done; slice six running; rebase PR 615 onto d4f8d94a.
- e545 session closed (paused, delivered).

Operator rulings today: astra medium code writers in the protected rejection lane only (llm-settings 94d0b41); every published check is required by default (llm-settings e270fcd; ruleset now 96 required checks).

## State at 2026-10-14 09:40 UTC (supersedes the sections below where they differ)

Main 38c7fbc1. PR 627 merged (#518 3c); #518 closed (pull requests 556, 569, 591, 622, 626, 627). Wiki 7397a96, sha256 63357750d2d2e46b.

- t503: slices 6 and 7 complete (Muse muse-4), slice 8 started; journey script edits allowed from 38c7fbc1. Writer stays Muse.
- t406: wallet preparation PR 1 (Muse commit-owner-3, Grok auditor-3), review 001 blocked and under repair; touch list A-005.
- e498: Lean slice five done and repaired (EXPECTED-RED on PR 615 head 1df78394 until the repair push); slice five-b (naming and structure review of the Lean base, Codex astra medium) then six to ten; paper after.
- e396: #518 done; next per its epic.

Staffing, operator 2026-10-14: the astra-medium code-writer ruling applies to the protected rejection lane only; the desk had widened it M1-wide and reverted it (skills: llm-settings 94d0b41). Root disk was full 08:20-08:45 UTC, freed by the operator; lanes told to re-run steps that failed in that window.

## State at 2026-10-14 07:45 UTC (supersedes the sections below where they differ)

Resumed by the operator at 06:20 UTC (release record /tmp/machine/pausa/RELEASE-20261014-singular-M1.md). Main 33ed29fc. Merged on 14 October: PR 625 (create from one output, #406 and #479 closed, 0272dadc) and PR 626 (#518 3b, 33ed29fc). Wiki register 2e8616a, sha256 25f0616956554636.

Lanes:
- e396 (#518): 3c next (interrupted two-request fold recovered on a devnet), rebase onto 33ed29fc, merge slot granted at a green exact head; sequence its push against t503 slice 8 (both edit tools/demo1_cli_journey.sh).
- t503 (#503 page part two): relaunched 06:27 in session z-singular-t503, Sonnet owner %374, Muse writer muse-4, Grok auditor grok-2; plan A-003; slices 6 and 7 in progress, slice 8 released by the 3b merge.
- t406 (#491 remainder, wallet preparation, A-004): released by the 3b merge; plan question to the desk first.
- e498 (protected rejection): economics and Lean model only (operator: research done; paper waits for the Lean rework so it can cite it). Lean plan c825773c reviewed (A-011: fee pin and minimum tip both kept, relation open; slice four dropped; slices five to ten; Codex gpt-6-astra high writer, Grok auditor). Paper after slice ten, citing fully qualified declarations, revision and axiom lines. Remote control on the Opus epic owner %282. Ruled design: m1/econ-hearing/handoffs/economic-design-as-ruled.md.
- Parked: e545 (543 and 544 delivered; 425 and 426 unreleased), e437, t592.

The desk goal is set (operator /goal): 3b, 3c and page part two merged; wallet-preparation slice dispatched; Lean rework running.

## PAUSED 2026-10-13 ~20:30 UTC (operator; supersedes the sections below where they differ)

Order: /tmp/machine/pausa/2026-10-13T2030-M1-singular.md. Merged on 13 October: PR 613 (create from several outputs), 617 (#543), 622 (#518 3a), 619 (#526, follow-ups #623 #624), 614 (#503 page from chain part one, Fixes #616), 620 (#544, desk REST merge at exact head 15cb3a9b because the guard refused only on cancelled unaffected checks). Main 6315099f.

On resume, in order: (1) PR 625, create from one output (#406, Fixes #479), head 92bfedc5, CI was running at the pause: merge when green, then relaunch t503 from m1/ticket-503/RESUME.md for the page's part two (archive run, create prints describe); (2) #518 3b (bound nine, readers, Demo 1 two actors in one fold, node guide; formatting fix then push) and 3c (interrupted two-request fold on devnet); (3) t406's wallet-preparation slices (A-004: two pull requests, fold files after 3b merges). Economics stays with the operator (his hearing session z-singular-econ-hearing; desk counterfindings at m1/review-response/handoffs/counterfindings.md); e498 paused by intent.

The desk watcher is stopped; re-arm it on resume (DESK_ROOT=<root> <root>/watch/desk-watch.sh as a 30-minute Monitor).

## State at 2026-10-13 17:45 UTC (supersedes the sections below where they differ)

Merged today: PR 613 (create funded from several outputs, refused up front; #478 closed), PR 617 (#543 bookkeeping, M4), PR 622 (#518 pull request 3a: fold, builder and journal carry any selection, bound still one), PR 619 (#526 wallet floor; follow-ups #623 #624). Main 6ec6b7f8; a Conformance job failed on a Hackage index update (infrastructure) and was re-run once.

Merge sequence tonight (desk PRIORITY 17:35): PR 614 (page from chain, #503 first pull request) merges first; PR 620 (#544, M4) and the one-output create (#406, branch feat/406-one-output-create) hold their pushes, then integrate once onto 614's merge and regenerate narration with the tool. Page pull request 2 (archive run, create prints describe) after the create merges (Create.hs).

Lanes (all lane roots under /home/paolino/.orch-runtime/singular/m1 unless stated):
- t406 (#406 one-output create; then #479 check and #491 remainder): Sonnet ticket owner %274; push held.
- t503 (#503 page from chain): Sonnet owner %296; PR 614 rebasing for the merge; PR 2 planned.
- e396 (#518 3b: bound nine done, receipt readers, Demo 1 two actors in one fold; 3c interrupted fold on devnet after): Opus epic owner %294, ticket owner %295. Due 18 October.
- e498 (protected rejection, root /code/singular-protected-rejection/.orch/protected-rejection): Lean rule steps one to three on PR 615 (head 70fc0960); economics model and paper PAUSED by the operator after the review /tmp/singular-economics-review-8a091f94.md (copy in its inbox, REVIEW-economics-8a091f94.md). Desk counterfindings: m1/review-response/handoffs/counterfindings.md (all eight findings agreed; four operator decisions; the desk's burden-flip proposal found unsafe; recommendation C: the tag mint refuses faulty bookings and the bond is dropped). Decision 1 of 4 is with the operator.
- e545 (#544, M4, root /home/paolino/.orch-runtime/singular/epic-545): Codex owner %131; PR 620 push held.
- Parked: e437 (restoring reference scripts, re-cut into #603-#612; after the review), t592 (CI result cache, PR 597), e507, others retired.

Rulings of 13 October: Koios only (several providers deferred; Koios answers are unverified under the Lockness rules); protected rejection epic's implementation after Demo 1, the Lean model and the economics paper now; staffing amendment: Lean models, papers and research go to Codex gpt-6-astra high, Muse writes code only (rulings/staffing-2026-10-09.md); termination pays the treasury (termination fee); bond split processor/treasury as a parameter (all subject to the review's decisions).

Desk process: factory-check clean on the desk tree after retiring 27 stale project-level roots; the desk holds a process claim (PROCESS, pane %0); factory-check R2 fixed in llm-settings ea0e74c. Machine owner's nudge strategy answered (/tmp/machine/inbox/factory-nudge-strategy-singular.md).

Wiki story register: commit 4bfd382, sha256 20e25168a93df89d, every open M1 issue mapped.

## State at 2026-10-13 07:50 UTC (supersedes the sections below where they differ)

Desk: Claude Opus 5.5 took the seat on 2026-10-13 in pane %0 (session z-singular-M1, window 1); pane ids were renumbered after a tmux server restart, so the pane ids in older sections are dead. The desk watcher runs as a 30-minute Monitor over watch/roots.txt.

The milestone was paused on 2026-10-12 at about 18:10 UTC (/tmp/machine/pausa/2026-10-12T18-M1-singular.md). Main is e7b55ac9: since the pause #601 (#531 retry ceiling test), #600 (CI summary skips cancelled runs), #602 (#573 devnet 20000-slot epochs), #598 (#491 docs: create from one output) and #599 (#555 measured booking seed) merged.

Released on 2026-10-13 by the operator:
- t406, #406 and #478 create funding: root m1/ticket-406, ticket owner %274, commit owner %276, auditor %277; branch fix/406-create-funding already on current main. Next: verdict on review 004, gates, one push, then MERGE-READY. Release record /tmp/machine/pausa/RELEASE-20261013-singular-t406.md.
- e545, epic #545 (milestone M4: #543 then #544): root epic-545, epic owner %131 (Codex), writer %133, auditor %269. Released to finish the epic (NOTE-032). Q-001 workflow wiring authorized. It lands before #518 pull request 3 because both edit Session.hs, Receipt.hs and Reconcile.hs. Release record RELEASE-20261013-singular-e545.md.

Woken for a rebase onto main only, then they park again (operator: every in-flight branch rebased correctly):
- t592, PR 597 (#592 result cache): NOTE-002; acknowledged.
- e437, PR 516 (#471): WIP commit of 15 files, backup ref backup/471-pre-rebase-20261013, rebase over 294 commits, build check, one push. Forwarded by the epic owner to its ticket owner as NOTE-018.
- Not yet rebased: PR 508 (#494, e498; no live seat, 349 behind); spec-only branches of #477, #491, #493, #494, #495, #519, #529 (rebased when their lanes resume). Operator asked whether to respawn e498 for the rebase; no answer yet.

Proposed to the operator, undecided: re-cut #471 into small slices from current main, with PR 516 closed as superseded.

Wiki story register reconciled and published 2026-10-13: wiki commit e3cea5a, 38 stories, register sha256 e0c53373d5fc6db6; every open M1 issue mapped (new stories: negative-host-hardening, documented-flags-from-binaries, test-suite-in-docs).

## #518 PR 2 and the keri stub merged, 2026-10-12 11:34 and 12:55 UTC

- **PR 569 (#518 PR 2)** merged as e3af83c1 at head 49e3eb57. The desk merged it itself through the REST endpoint at the operator's instruction, after a desk note had wrongly made the green PR take a new commit (rule saved: a green PR next in line merges as it is, and a push goes only on the current main). The cleanup wait (#586, b6901690) follows separately.
- **PR 561 (the keri stub)** merged as 6d2de3a5 (parents e3af83c1 and e4f47dab). It needed brief 7 to read the settled list after #518 PR 2 changed the receipt. #528 is closed, and the t528 lane is told to pause.
- **CI root causes** (investigation 10:30):
  - the /srv/ci-work disk filled up; the machine owner freed it and committed a one-day age rule (infrastructure ab992c6);
  - the deployment-identity cleanup race (#586);
  - #573 is the 50 s devnet epoch-end validity cap under 30-runner load. The fix is the devnet epoch length, and it is not routed yet.
- **Next in the queue:** 575 (#563 and #564; CI re-triggered after GitHub dropped a push event), then 578 (#565), then 577 (#559) and 585 (#541).

## The census merged, 2026-10-12 10:27 UTC

- PR 572 merged as 6cb27c70 (parents 1d9f8b0d and ada21e6f) ahead of the keri stub, under the ready-first rule. No rebase was needed: the only intervening change was docs (#567), and the lane ran a merge simulation.
- **Work-in-progress limit** (operator: "PRs are piling up"). Merge order: 561 (needs its two-actor window fix push), then 575 and 578 back to back, then 569, 577 and 585. No new PR until at most three remain. One push per ready candidate. Release PR 574 (0.11.0) is held until the queue drains.
- **Small fixes ride in the observing PR** (operator; skill a46b625). The keri stub raises the two-actor windows to fix #573.
- **Intermittent CI failures today** (#573, the deployment-identity cleanup race, the verify-release control): a read-only investigation of shared-devnet interference on the self-hosted runners is running.

## #358 part B2 merged, 2026-10-12 08:56 UTC

- **The merge.** PR 567 merged as 1d9f8b0d (parents 2c61a1c2 and d555aeae), with the reclaim step and the docs page. The desk walked the table and gave MERGE-GO under the ready-first rule, ahead of the draft census PR 572, because no files are shared.
- **#358 is closed.** Its follow-ups each have an issue: #559, #552, #551, #498, #529, #486, #560, and #573, a new signed bug for the two-actor job validity window.
- **Process changes on 2026-10-12** (operator):
  - the auditor is an alarm: a block names a concrete failure scenario, and advisories are never a requirement;
  - process is sized to what the diff can break;
  - auditors are Grok 4.7;
  - skills on llm-settings bb59bae and 0c26656;
  - #518 and #358 resumed beside #562;
  - GLM writer quota out until 2026-10-14 18:04 UTC.

## Fix main first, 2026-10-11 21:30 to 2026-10-12 07:00 UTC (supersedes the sections below where they differ)

- **Why.** On 2026-10-11 the operator found that tests exist that no hosted job runs ("tests not running, this is rookie"). A desk audit at d2e3c180 filed:
  - #562: four recovery parts and seven checks ran in no hosted job;
  - #563: rollback was red on main;
  - #564: trie-capability was red on main;
  - #565: the release review check had never passed since 2026-09-17;
  - #566: two Lean mutant checkers broken at baseline (Assurance milestone).

  Then the operator: "Stop the rest. Just fix main." And: "Pause after the fixes."
- **Merged since:**
  - #343 (PR 568, d20f88e9): hooks out of the release binary; the recovery parts judged in a hosted job, rollback green;
  - release 0.10.1 (PR 570, 83118bea, tag v0.10.1, published);
  - **PR 571 (2c61a1c2, parents 83118bea and 73aacf7b):** the seven checks get hosted jobs, verified by the desk.
- **#562 lane** (root /home/paolino/.orch-runtime/singular/m1/ticket-562, owner pane %202):
  - next is the census PR, a hosted check that turns red for any declared app or check with no hosted job, with a "tool" class for marked tools;
  - then S2, the recovery partitions, closing #563 and #564 (#564 after a clause audit);
  - then S3, #565.

  The lane pauses after #562 to #565 are merged.
- **Resumed by the operator** beside it: #545 (#541, #543, #544) and the keri stub (PR 561). #518 (PR 569) and #358 B2 stay paused.
  - Rule for all lanes: before merging, run the unhosted checks in the areas you touch, at the exact head, with receipts.
  - #562's PRs merge first.
- **Root cause, investigated.** All 12 orphans came from agent lanes:
  - eight were proof scripts run once and cited as evidence;
  - four were dropped in the 2026-10-06 CI clean-up without an issue.

  The skills were fixed on llm-settings main (e2670cc, then 5920b51): an obligation runs in a hosted job, a tool is marked and never cited, a temporary check is deleted before merge, and citing an unhosted check is what the auditor blocks.

## #358 part B1 merged, 2026-10-11 17:51 UTC

- **The merge.** PR 558 merged as 403b4800 (parents 95e1d880 and 4906ce59), after the desk checked its acceptance table and gave MERGE-GO.
  - The nine application pairs of `singular-negative` each have a mutant job that turns them red.
  - The two aggregate checks `Negative host pairs` and `Negative host mutants` exist. Requiring them is a repository setting to propose to the operator.
  - No identity file changed, so the hash set is unchanged.
- **Follow-up issues filed by e521:**
  - #559: a mutant for the four registry-insertion pairs, which needs a scratch-only regeneration of the pin and the identity files;
  - #560: a finished local part run leaves its devnet behind. Desk A-017 took the cleanup out of #358 after nine blocked reviews.
- **#358 part B2:** the reclaim step and the documentation page. Its reclaim candidate has been blocked twice (reviews 334 and 335); e521 decides between a third writer and taking it out.
- **Queue, ready first:**
  1. #518 PR 2: in the slot from 17:55, still being cut.
  2. #358 B2.
  3. #557 pin bump.
  4. #518 PR 3.
  5. The keri stub: briefs 1b and 2 done or in repair.
- **#545:** woken by the operator at 16:48 ("Merge 343 and release"). It finishes #343 with a GLM writer and a Sol auditor, merges it, then pauses again. The desk then merges release PR 354 (0.10.0) on the operator's instruction, after release-please refreshes it.

## #547 merged, 2026-10-11 16:32 UTC

- **The merge.** PR 554 merged as 95e1d880 (parents 9d5f4c7a and 84193e99), after the desk checked its acceptance table and gave MERGE-GO.
  - `singular`, `open-datum` and the negative host now read the common flags through one function, in `offchain/cli/src/Singular/CLI/FlagGroup.hs`.
  - No on-chain or identity file changed, so the hash set is unchanged. Issue #547 is closed.
  - #528's one-flag-group item is met for the two binaries on main. The keri stub's PR owns the third parser.
- **Queue:**
  1. #358 part B1 (PR 558): in the slot from 16:36. It rebases onto 95e1d880, re-greens, and cites the new registry-state mutant issue (A-016) in its table.
  2. #518 PR 2.
  3. #358 part B2.
  4. The #557 pin bump.
  5. #518 PR 3.
  6. The keri stub, whose parser may start now.
- **#545:** paused by the operator's order, at a safe point before merging #343 rather than after a merge. Its question Q005 (inherited `pkill` cleanup paths) is unresolved; the desk's 15:50 note in its inbox answers it (A-018 tolerance, migration owned by #553). The operator is the wake.

## #518 PR 1 merged, 2026-10-11 15:03 UTC

PR 556 merged as 9d5f4c7a (parents d8bc7dbc and 43fcef26), after a desk MERGE-GO on its acceptance table. The published hash set is unchanged. #547 (PR 554, the shared flag reader) holds the slot from 15:05. It rebases over #518's edits to Command.hs. After it come #358 part B, #518 PR 2, #518 PR 3 (many requests per fold) and the keri stub. Release PR 354 (0.10.0) waits for the operator.

## State at 2026-10-11 14:10 UTC (supersedes the sections below where they differ)

- **Main:** d8bc7dbc. Merged today, in order:
  - #528 (c6748950);
  - #545's #539 (b55053a2) and #542 (f9652eb7);
  - #381 (f6783383);
  - #545's #540 (8a99415d), confirmation on the calling thread under the operator's single-thread ruling;
  - PR 550, #358 slice 3A (d8bc7dbc), merged after a desk MERGE-GO on its acceptance table.

  The published hash set is unchanged throughout.
- **Merge slot:** #518 PR 1 (e396), granted at 14:07. It rebases onto d8bc7dbc, re-greens, writes its acceptance table and waits for MERGE-GO. Then #547 (PR 554), #358 part B, #518 PR 2, and the keri stub.
- **Release:** the operator approved re-enabling the Documentation release workflow. Release-please refreshed PR 354 as 0.10.0 from 8a99415d. The desk checked the notes: the bounded contract, managed state, the CLI split and open-datum executable, the booking refusal and the independent actors are present. Two remarks went to the operator: there is no breaking-change section (the open-datum verbs left `singular`), and #540's commits are not picked up. Merging it is the operator's call.
- **Known main defects:**
  - #555, MeasuredBookingSpec failing for some seeds (filed today, signed; #368 was closed without a fix);
  - #531, the Koios retry-ceiling test.

  Slot holders journal these and re-run the job once.
- **Incidents in #358:** two signalling incidents, a host-wide `pkill` at 10:21Z and invented process ids between 11:30 and 12:10Z. No lane loss was found. The staffing rule now reads: stop targets are only pids this run started and read from the process itself; no patterns, except one anchored to the run's own unique folder in existing code (A-018).
- **e371:** parked after #381 (#389, #503 and #492 unstarted). **e545:** #343 is in final review; #541, #543 and #544 are next.

## #381 merged, 2026-10-11 11:03 UTC

PR 433 merged as f6783383 (parents f9652eb7 and 15e02183). The desk verified it on origin/main: 106 hosted checks with none failing, and the published hash set unchanged. Issue #381 is closed. PR 550 (#358 slice 3A) holds the slot from 11:06: it rebases onto f6783383, re-greens, and the desk gives MERGE-GO after checking its acceptance table. Next is the release: the desk asks the operator to re-enable the Documentation release workflow. Wiki commit: see the story register.

## State at 2026-10-11 10:45 UTC (supersedes the sections below where they differ)

- **Main:** f9652eb7. The quality lane #545 (milestone M4, watch-only, Codex parent %131 in session singular-e545, root /home/paolino/.orch-runtime/singular/epic-545) merged two PRs outside the queue: PR 546 (#539) and PR 549 (#542). Neither touches on-chain code or M1 files.
- **Queue, operator "ready first" 08:48:**
  1. #381 (PR 433, in the slot): rebased onto f9652eb7 and approved; push pending after a #99-missed wake at 10:40.
  2. PR 550: #358 slice 3 part A, green at cbfa8013.
  3. #518 PR 1: code approved; the devnet item and the fold page are left.
  4. #547: shared flag reader. Muse won the race; the pre-push evidence is being rerun after the f9652eb7 rebase.
  5. #358 part B.
  6. #518 PR 2.
  7. The keri stub, whose parser waits for #547.
- **The release:** after #381 merges, the desk asks the operator before re-enabling the Documentation release workflow (disabled by hand), then checks PR 354's notes.
- **Rulings today:**
  - **Staffing 07:10:** Muse and GLM alternate, and race on difficult or re-cut briefs; Codex audits.
  - **No killing by pattern (10:32):** a pattern anchored to the run's own temporary folder is tolerated in existing code (A-018), with a follow-up issue for the ten scripts.
  - **Operator, to #545 (09:05):** single-threaded unless there is a written reason. Constitution Principle VII is drafted, opened by #545 first.
- **Races so far:**
  - #518 run B2b: GLM won on the smaller diff, 1 finding each.
  - #547: Muse won on the smaller diff, 2 findings each.
  - #358 cleanup: GLM was disqualified for a host-wide `pkill` at 10:21Z.
- **Desk misses recorded:**
  - #528 merged with its one-flag-group item unmet (#547). Memory rule: walk every acceptance item before a merge slot.
  - A-011's race box omitted the gate run time.
- **Tooling issues:** llm-settings #99 (wait-channels misses lines landed before arm) and #101 (the postman settles answers at discovery) are open; #100 is fixed; #102 was closed as a duplicate of #101.

## #528 merged, 2026-10-11 06:41 UTC (supersedes the current-state section below where they differ)

- **The merge.** PR 535 merged as c6748950: first parent 7d76efb0, second parent 04746bfb. The desk verified it on origin/main:
  - the published hash set is identical to e91de2f1;
  - onchain/validators, offchain/lib and offchain/cli hold no open-datum code.

  Hosted CI was green at the exact head: 85 checks, none failing. Issue #528 stays open for the cardano-keri stub, which follows as t528's own PR in applications/keri-stub/ and takes no merge window.
- **Merge slot.** #381 (PR 433) holds it, granted at 06:45 (MERGE-SLOT-M1-20261011T0645Z-381 in epic-371/inbox). It rebases onto c6748950, moves its ordinary calls to the open-datum executable, follows the early booking refusal, and merges on green.
- **Queue.** After #381: #518 PR 1 (e396), #358 slice 3 (e521), #518 PR 2.
- **Rebases.** e396 and e521 were told to `git rebase --onto c6748950 <old #528 base>` at a safe boundary. They may push draft PRs.
- **Quality lane.** The operator is setting up an epic that fixes quality on main in parallel. It belongs to M1, but its issue number and runtime root are not yet known to the desk. Main may move outside the queue: a slot holder rebases and re-greens before merging, and a script-hash change goes to the operator.
- **Wiki.** The story register is updated: command-line-split is in progress with PR 535 landed and the keri stub next. Wiki commit 17aa4c1.

## Current state, 2026-10-11 06:15 UTC (supersedes the sections below where they differ)

The operator resumed M1 on 2026-10-10 at 08:00 UTC: first #528, then #381 (e371), then "do both" for #396 and #521, each building on #528 and merging after it. Every other lane stays PAUSED: e301, e437, e498, e507, e520, e522.

| lane | work | state |
|---|---|---|
| t528 (pane %3) | #528, the CLI split, PR 535 | Pushed 2026-10-11 04:10 as six squashed commits on e91de2f1, head 4246a147. Hosted CI red on its own regressions (devnet genesis directory, hlint), recorded as EXPECTED-RED. The repair is reviewed in rounds; the latest commit is 04746bfb (H2-r1). Then the pre-push checkpoint, push, hosted CI (about 16 min) and merge in the exclusive window. The keri stub follows as #528's own next PR in applications/keri-stub/. |
| e371 (%7) | #381, two actors on separate machines, PR 433 | Merge-ready at 296e1715 (all reviews approved, hosted CI green). Next in the queue after #528: rebase, move insert/update/terminate to the open-datum executable, merge. |
| e396 (%85) | #518, one fold settles every settleable request | PR 1 = selection, builder, command change, devnet item and fold page. Ceiling 9.5 h of writer time; only the devnet item and the page may pass it, 100 min together (A-008, A-009, A-010). About 400 min spent; run B2b in review. PR 2 = receipt readers and docs pages, on #528's final head. |
| e521 (%5) | #358 slice 3, the negative host | PR A has seven pair patches on #528's old ba0cc2d4 base. PR B (mutants) is in progress. The two part scripts belong to slice 3 by A-009. |

Separation, as the operator ordered on 2026-10-10 ("the 2 applications live in completely separated hierarchies, on-chain and off-chain"):
- the open datum lives in applications/open-datum/, with its own Aiken project (onchain/) and its own cabal package (offchain/);
- onchain/validators, offchain/lib and offchain/cli hold no open-datum code;
- the published hash set is identical to e91de2f1. The open datum's entries moved to applications/open-datum/onchain/script-identity.json and permanent-contract.json with the same hash cdc67586 and compiled-code fingerprint 897dadc5. Verified by the desk at ab0e394b and 4246a147;
- the application's Aiken tests run in a test-only workspace the application's build assembles from both trees, against the registry's real state validator.

Desk rulings 2026-10-10/11, all in the lanes' answers/ folders:
- t528 A-003b: the flag checker closes with two named limits; follow-up #538.
- t528 A-005a1: the bare "/" fix lands; the pre-push re-plants every reach spelling.
- e521 A-007: #528 adapts the negative-host part scripts.
- e521 A-008: #486's check is a library function that every ordinary verb calls before signing; the booking primitive and the application builders stay permissive, so the negative host can still book a taken key.
- e521 A-009: the part scripts are handed to slice 3.
- e396 A-005 to A-010: the #518 base and its PR split.

Merge queue: #528 (exclusive), #381, #518 PR 1, #358 slice 3, #518 PR 2.

**Rebase rule.** #528's squash removed the commits that e396 and e521 stacked on (24e0c9ba, 58335316, ba0cc2d4). They push nothing and rebase only onto the #528 head the desk names (git rebase --onto), after #528's final head is approved and hosted green.

**Host constraint.** The root filesystem holds /tmp, with about 23 GB free. Two runs failed on "No space left on device" during the night. Standing rule: TMPDIR and RUNNER_TEMP on /code for every devnet, Demo 1, part or mutant run; each lane removes its own scratch.

**Tooling defects.**
- paolino/llm-settings#99 (wait-channels misses lines landed before arm) is still open. The desk wakes the missed parent by inbox note.
- paolino/llm-settings#100 (argv-differs after exec) is fixed in 40996fb; the issue is still open.

## Outcome and its test

M1 is the permanent two-edge registry for KERI plus Demo 1. The observable test: on a preprod registry created once from the bounded release, Alice and Bob, each with only the shipped executable, their own wallet, a Koios URL and the registry's public state token, register, update and terminate keys, fold each other's bookings, recover after an interrupted command, and see the chain refuse forbidden actions; the public page is rebuilt from chain by either of them. Review date 2026-10-22 (issue 261). Old registries are abandoned; no migration. The five other edges are M2; shared scripts and Demo 2 are M1.5; naming is M3.

## Epics and lanes

| epic | journey | children | lane | stage |
|---|---|---|---|---|
| 301 | Demo 1 packaging and rehearsal only | 300, 359, 481, 484 | z-singular-e301, Opus owner %2585 | waits on the journeys |
| 371 | Bob joins and operates Carl's registry independently | 389, 485, 381, 503, 492, 528 | z-singular-e371: owner %2720/%2717, Muse on 485 at %2712 | 485 in implementation; 381 PR 433 unfinished |
| 396 | several users book concurrently, one fold settles them | 518 then 519; defects 486, 487, 488 | z-singular-e396, Opus 5.5 owner %2722 | opened 2026-10-09; roster approved; 518 ticket owner to be dispatched |
| 437 | restore missing references and resume | 471, 502 | z-singular-e437: Opus owner %2715, GLM ticket owner %2719, Muse %2681 | 471 PR 516 draft, implementation live |
| 498 | protected rejection | 494, 495, 496, 497, 529; research 500 | z-singular-e498, Opus owner %2713 | 494 PR 508; 529 filed 2026-10-08 |
| 507 | bounded M1 contract, M2 preserved | 505, 506 (504 done) | z-singular-e507: Opus owner %2714, codex on 505 at %2703 | 505 in progress |
| 520 | Carl creates without a stranded partial run | 406, 478, 479, 491 | z-singular-e520, Opus 5.5 owner %2723 | opened 2026-10-09; roster approved |
| 521 | forbidden actions refused by the chain | 358 | z-singular-e521, Opus 5.5 owner %2725 | opened 2026-10-09; roster approved |
| 522 | live narration and safe recovery | 477, 493, 415, 526, 334, 335, 416, 483 | z-singular-e522, Opus 5.5 owner %2724 | opened 2026-10-09; mapping |

Child teams, by the operator's ruling of 2026-10-09 (Codex out, the operator is on credits): epic owners Claude Opus 5.5 high; ticket owners Claude Sonnet 5.5 xhigh; commit owners Muse through the pi harness; auditors GLM through the pi harness, and from 2026-10-09 14:00 UTC Codex gpt-6.1-sol high on every newly launched slice (operator: Codex is back; running GLM auditors finish their slice); gate authors the ticket owner and the auditor; one team per epic at a time; the Codex seat on #505 in e507 stays by explicit exception. Every epic owner journals PLAN-REVIEWED on a ticket owner's mandate before a coder runs (rulings/planning-quality-2026-10-09.md).

## Priority order and why

1. Hash-changing contract work before the one new preprod registry: 505, 494 and 495, 529, then 506. A registry created before them cannot be protected or bounded afterwards.
2. The four journeys the demo cannot do without: 528 (every journey builds against the library from now on), creation (520), independent join (485, 381), one fold for several bookings (518, 519), restored references (471, 502), then 496 and 497 through the packaged commands.
3. What makes it show well: 477, 493, 415, 526, 334, 335, 416, 492, 503, 358.
4. Packaging and rehearsal: 481, 300, 359.

Inversions on the record: the conformance-bible epic 209 left M1 for assurance on 2026-10-08 and its lane is closed; the CI speed-up lane (449, PR 515) is M4 work and no longer a desk lane.

## Rulings in force

- 2026-10-08: the Singular CLI is the registry only (create, fold, reject, reclaim, inspect); the open datum is its own executable linking the Singular library up to the command line so Singular's flags pass through; cardano-keri's ckeri is built the same way (issue 528).
- 2026-10-08: every request carries a tag minted by Singular's request policy; untagged outputs at the request address are spendable by anyone; every tagged request has an exit; the mint demands a bond and a rejection forfeits, sized against fold capacity (issue 529, under 498).
- 2026-10-09: the request keeps carrying its datum inline; no size cap; the application decides what rides in it. Fold capacity under preprod's execution budget is estimated at about nine requests, proof-bound; measuring and raising it is issue 530 in M4.
- Every ticket is searched and placed before filing (llm-settings a3b51c4).

## Parked decisions

- Settled 2026-10-09 by the operator: the rejection forfeit is burned as a treasury donation in the rejecting transaction (fallback: registry state output, if the balancer proof fails); expiry forfeits too (e498 A-002).
- Settled 2026-10-09 by the operator: #494 merges alone; the in-window rejection row is published unmet until #495 (e498 A-001).
- Whether a failed trace file warns on stderr (issue 483): one answer when e522 asks.
- The preprod registry creation authorization: given once, after priority group 1 lands.

## Standalone and cross-cutting

Issue 528 sits under 371 for ownership but every journey builds against it. Issue 530 (fold capacity) is M4 and feeds 396. No standalone ticket lane is open.

## Public projection

Live dashboard (tailnet only, refreshed every minute by a user timer, no model): http://100.85.229.71:8460/ . Wiki story register https://github.com/lambdasistemi/singular/wiki/Milestone-1 regenerated 2026-10-09 from Milestone-1-Stories.json (34 stories, 6 groups, every open M1 issue mapped); wiki commit c79ce6e, register sha256 adea44c3d762ffb5. Roadmap, demo path and October logbook pages updated 2026-10-08 (wiki commit 26914cd).

## Concurrency and merge rules in force

Two logic-changing lanes at a time plus one almost conflict-free lane; cleanup that moves code without changing behaviour takes the stage. Working now: the bounded contract (505), restoration (471), the negative host (358, conflict-free). Paused at a safe boundary: join (485, operator pause of 2026-10-08), concurrent booking, creation, recovery, protected rejection. Merges one at a time through a desk-granted slot: 485, 505, then the command-line split (528) in an exclusive window as a standalone desk lane, then 471, 518, 406/478, 477, 494/495, 529, 506. Full text in the desk root, rulings/merge-queue-2026-10-09.md.

## Host crash 2026-10-09 13:35 UTC and recovery (current state)

The host hard-reset at about 13:35 UTC; every tmux session and agent process died; worktrees, runtime roots and the dashboard services survived. GitHub over ssh was down until the operator reloaded the passphrase-protected key into the systemd ssh-agent (/run/user/1000/ssh-agent.sock) at about 14:20 UTC; lanes held pushes until the desk note NOTE-M1-20261009T1420Z-push-works.

Relaunched 13:46-13:48 UTC with a crash-resume note (inbox/NOTE-M1-20261009T1345Z-host-crash.md in each root), each acknowledged by a RESUMED line:

- #485 ticket owner (desk lane), session z-singular-e371 pane %2, Sonnet 5.5 xhigh: head 8a590de1 green on cage tests; commit owner relaunched for the controls rerun and one just-ci; holds the push until GitHub is back; next merge slot.
- #528 ticket owner (desk lane), session z-singular-t528 pane %3, Sonnet 5.5 xhigh: slice 2; commit owner resumed from its three uncommitted files, auditor answering review s2-002 on aaaf012e.
- e437 owner, session z-singular-e437 pane %4: the #471 writer resumes slice 2c-ii from 27 uncommitted files on 0dc580c7.
- e521 owner, session z-singular-e521 pane %5: #358 slice 1 (PR 533) lint-leg repair; local commit 8410b0af unpushed.
- e498 owner, session z-singular-e498 pane %6: #529 planning only; #494 and #495 parked READY-TO-CODE; Q-001 (in-window rejection row) still with the operator.
- e371 owner, session z-singular-e371 pane %7: told to park #381 (waiting for #485's rebased push) and itself, wake = desk note.

Stayed down, parked by intent with RESUME.md and a wake condition: e301 (paused, wakes at Demo 1 checkpoint 9), e396 (#518, #519 READY-TO-CODE), e507 (wakes when #529 merges), e520 (#406, #491 READY-TO-CODE), e522 (#477, #493 READY-TO-CODE). The research seat and the project owner seat are not desk lanes and were not relaunched.

## Since the crash (14:00-14:45 UTC)

- Landed: #485 (PR 525, merge 75f0708f, 14:42 UTC), exact-head hosted CI green including the split Demo 1 jobs. The ticket owner closes its lane.
- Landed: #358 slice 1 of 3 (PR 533, merge f733a048, 15:36 UTC) after one returned slot (the rebased head missed the module #485 added). No slot open. Main is red once on 75f0708f on an intermittent R299-05 clause (same insert after the lock is released comes back partial; tree identical to the green PR head); e371 reproduces it and files a signed bug. #381 and #528 rebased onto 75f0708f; #471 waits for #528. #528 slice 2 accepted (24dcb9b8); its auditor is now Codex. e498 parked with its pane closed.
- #529 PLAN-REVIEWED (662663f9) and parked READY-TO-CODE; #494, #495, #529 all planned.
- After a host reset the operator must reload two secrets by hand: the ssh key (`SSH_AUTH_SOCK=/run/user/1000/ssh-agent.sock ssh-add ~/.ssh/ed25519`) and the gpg signing passphrase (`export GPG_TTY=$(tty); echo unlock | gpg --local-user 20B19354D7919C8C5810F95A55DFD2E86F982261 --clearsign >/dev/null`). Without the second, no lane can commit.
- Wiki Milestone-1 updated: commit 7de61e3, register sha256 a073ec562663f7ed.

## Paused for the night, 2026-10-09 19:45 UTC (operator)

Every lane is paused by order PAUSE-M1-20261009T1940Z (in each lane's inbox), each seat journaled PAUSED with wake = desk RELEASE, nothing is armed, no pane or worktree was killed. Main is 7d76efb0. Landed today: #505 (e3c9ab01), #485 (75f0708f), #358 slices 1 and 2 (f733a048, 7d76efb0), #534 (5fb1d754). No merge slot is open.

Resume tomorrow: the desk sends a RELEASE note to each live lane's inbox and a pointer to its pane (panes kept: e371 %7, t528 %3, e437 %4, e521 %5, e301 %49). State to resume from: #528 slices 1 to 3 done, PR 535 head 8fae2935 pushed with its CI repair, next slice per its RESUME; #381 run four repairing review 4-001 (PR 433 red acknowledged, EXPECTED-RED at 67d595e8); #471 writer mid 2c-ii with 15 uncommitted files named in its RESUME; #358 slice 3 next. Queue when released: #528 in its exclusive window when merge-ready, #381, #471, then #518 PR 1. Open with the operator: the liveness-rule proposal (drafts/factory-liveness-rule.md in the desk root) and the fix owner for llm-settings#99 (wait-channels misses what landed before it was armed).

## State at 18:10 UTC

- Rulings since 15:36: #494 merges alone and publishes the in-window rejection row as unmet until #495 flips it (operator, A-001); #534 (the refusal-controls story's 45 s registry window leaves 15 s for a fold build, too little on slow runners; test harness only) is commissioned under e371 as the conflict-free lane and takes the next merge slot ahead of #381 and #528, with one DEMO1.md sentence in its fence (desk, A-015, A-016); #358's tamper and withdraw pairs are signed by Alice, one difference per pair, Bob's case being slice 1's pair (desk, A-005, reported to the operator).
- Working: #528 (rebased onto 75f0708f, lint repair 713faf55 under Codex review), #381 (auditor repairs), #471 (slice 2c-ii), #358 slice 2 (RED repair under Codex review), #534 fix (plan reviewed, writer on Backend.hs).
- Parked: e301, e396, e498 (pane closed 15:18; relaunch on coding release), e507, e520, e522. No merge slot open.

## Snapshot 2026-10-09T12:37:40Z (supersedes the stages above where they differ)

- Landed: #505 (PR 523, e3c9ab01, 10:16 UTC). e507 parked until #529 merges; #506 waits.
- Working: #485 (desk-managed, rebased on e3c9ab01, second GLM audit passed, heading to hosted CI, next merge slot); #381 stacked on it; #528 (desk lane z-singular-t528, Sonnet ticket owner, slice 2 of 6); #471 (restoration, writer mid-slice); #358 (negative host, conflict-free third).
- Planned and parked READY-TO-CODE: #518 (two PRs), #519 (four PRs), #406/#478, #491, #477, #493 (five PRs); touch lists committed in each spec folder.
- Planning: #494 and #495 (e498, owner relaunched at Opus 5.5 high). Operator decision pending: how the suite shows the in-window rejection between #494 and #495.
- Merge queue: #485, #528 (exclusive window), #471, #518 PR 1, #518 PR 2, #477, #493, then the Lean surface #494, #495, #529, #519 Lean PRs, #506.
- Rulings today: staffing (Opus 5.5 high epic owners, Sonnet 5.5 xhigh ticket owners, Muse coders, GLM auditors; Codex only on the finished #505); planning quality and plan-ahead with touch lists; desk answers A-003 (public replay partition), A-004 (corpus row flip), 528 A-001 (singular links no application code), #532 placed under #498.
- Desk tools: watcher in the milestone skill, tailnet dashboard http://100.85.229.71:8460/ refreshed by a user timer.
