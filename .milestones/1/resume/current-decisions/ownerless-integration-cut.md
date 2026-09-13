# Ownerless integration cut — preparation now, acceptance on the combined candidate

Authority: existing operator no-owner ruling, A-003 action-set disposition, and goal to finish M1. Root read epic17/handoffs/ownerless-schema-handoff-to-18.md IN FULL. This coordination ruling resolves the circular dependency between 'repair cannot be accepted without consumer codec' and 'consumer may not consume repair before acceptance'. It changes implementation sequencing, not design or acceptance requirements.

## Frozen preparation input

Use exact antecedent f3a68b1bcd63119f8db79548a7d15926bf408856 (tree3cac539b1db35cabfbe176775c8476cd2f753bc7), not the moving77 worktree tip. It is PROVISIONAL, not accepted. Root independently ran its clean Aiken suite:1411checks,0errors,exit0. Final SDK/ledger/Blaster evidence remains outstanding. Generic State loses owner/stake_script and has root,tip,process_time,retract_time; state validator becomes parameterless. Exact codec encoding, request parameters and script identity must be read/derived from that committed source and actual build, not guessed from prose.

## Serial ownership

Epic17 remains the sole product-validator/SDK writer, finishing77 and the current ownerless prose fixes. It supplies a COMPLETE versioned provisional schema/parameter/compiler/blueprint handoff from f3a68b1 NOW for preparation; fixed-commit identities can be built/read despite unrelated dirty work above them. Mark any later replacement explicitly. Do not call a stable commit a moving draft merely because the live worktree has later edits.

Epic18 finishes current70b bounded delivery first, then uses that existing mechanical slot to prepare its consumer companion in a separate integration checkout against the pinned antecedent plus its consumer commits. This supersedes 'no cherry-pick until accepted' only for this explicit, isolated PREPARATION cut. Import the exact17 commit mechanically; do not edit onchain/,naming-onchain/ or offchain/ product sources. Own conformance decoders/builders/parameter application and their tests/docs. Existing source fences still hold on the70b delivery branch. Bind the companion under the existing consumer serialization/lifecycle obligations (#68/#77 as appropriate), with no new worker or auditor required.

Concrete impacted leads already found: conformance/app/Conformance/CS06.hs requires previousPolicies and1stateparameter; Run.hs derives applied state identity with previousPolicies=[] and still reads/updates stateOwner; Mirror.hs decodes StateDatum. Derive the complete affected set, including imported SDK compatibility, from the frozen source. Retire superseded owner/hook expectations to preserved history rather than inventing new owner roles or crediting old receipts. Distinct request/refund and application/name authority stays intact. Full-inventory and held-contract debt remains.

The companion is prepared and locally checked now; it does NOT merge alone or grant final conformance. Epic17 owns the final serial integration branch: exact finalized17 repair/journey commit plus exact18 consumer companion. Epic18 hands off a clean consumer-only delta;17 imports it without parallel writers. Resolve conflicts against the same approved schema and report any behavioral ambiguity as a concrete user story. Required CI, source/SDK/ledger gates and affected row reruns execute on that SINGLE coherent final candidate. Root reviews gates and acceptance; no fullM1 release until all existing debt and87compiled obligations are zero.

The parallel87 driver continues instrumentation/old-snapshot witness, preserving its limits. It can use fixed f3 identities for preparation once recorded; every final compiled claim must rebind/re-execute against the coherent accepted candidate. Do not block harness implementation on final acceptance, and never promote provisional evidence to final credit.

## Handshake

Both owners acknowledge this coordination record, record exact integration ownership, and continue their independent current workers.18 schedules companion preparation after70b delivery;17 supplies fixed-input details and continues77. No new schema/design choice, broad DSL adoption, deployment or release is authorized by this preparation sequence.
