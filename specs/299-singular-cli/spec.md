# Reusable Singular registry commands

Authority: issue #299, parent #301, operator Demo1 ruling and reusable-CLI correction dated 2026-09-28. Constitution 1.10.1 governs. Owner-defined scope is rung 0 with checks for the named invariants; this ticket does not assert full conformance completion. The proposed command surface is not working at the planning baseline.

As an operator, I create a registry, insert a selected key, inspect confirmed Active, terminate the same key and inspect confirmed Terminal through separate ordinary CLI processes, so I can continue after closing each process without booting another registry.

## Requirements and acceptance lines

| Requirement | Observable acceptance |
| --- | --- |
| R299-01 | Packaged `singular registry create/insert/terminate/inspect` and help run from an extracted release archive outside the checkout; no demo-only executable. |
| R299-02 | Public saved configuration binds network, registry/seed, existing open application, actual script/policy pins and deployment references. Authenticated local state is separate, non-secret and checked against fresh ledger commitment before mutation or leaf reporting. |
| R299-03 | Selected key parsing rejects malformed and oversized bytes. Writes reject partial external settings, mainnet, wallet/network/script mismatches and spent/wrong-wallet seed before submission. Selected seed remains reserved during funding/reference publication until consumed by boot. Public derived identity can be previewed without submitting. |
| R299-04 | Create/insert/terminate use accepted production builders with caller node, wallet, seed and key. Insert and terminate attach to saved state. Process exit cannot select a different identity or boot another registry. |
| R299-05 | Every submitted transaction and confirmation, including partial failures, survives in public receipts. Repeated create refuses existing state. Concurrent/stale commitment, unavailable node and timeout halt with attributable outcomes; no implicit repair, overwrite or resubmission. |
| R299-06 | Inspect needs no signing key, funding or submission. It queries fresh registry state, validates selected-key proof/state against observed commitment and reports mechanism, chain point and freshness. Active/Terminal evidence includes actual state datum/root and token/burn/custody observations with source labels. |
| R299-07 | Archive CI invokes five separate CLI processes on one persistent development node. Identity continuity and actual observations are asserted. Existing insert-active/update-terminal controls remain intact. Missing command/page and altered config/key/root/policy/observation/proof and stale-state controls reach their intended refusal boundary. |
| R299-08 | first-demo and archive DEMO1 instructions show supported commands, open-application limits, partial outcomes and recovery. Later ckeri/witness/Absent/naming/escrow work remains uncompleted; recording requires verified actual commands. |

## Invariants

All rows below are BLOCKING unless marked ADVISORY. Client safety refusals are not claimed to be model or ledger refusal reasons.

| Invariant | Required truth and failure witness |
| --- | --- |
| INV299-IDENTITY | Saved registry/network/seed/pins and selected key bind every write/read; tampering or identity substitution refuses before success or submission. |
| INV299-AUTHENTICATED | Local trie commitment agrees with freshly observed ledger commitment; altered state/proof or stale/concurrent root refuses. Local expected leaf is never a direct ledger datum. |
| INV299-WALLET-SEED | Caller wallet/network and actual unspent seed govern production builders; reserved seed survives preparatory transactions and boot consumes that exact seed. Wrong-wallet/spent seed or partial settings cannot submit. |
| INV299-INSERT | Unknown becomes Active under open approval, creates exactly the keyed active holding, preserves custody and non-root config, routes the deposit as specified; duplicate insertion refuses. |
| INV299-TERMINATE | Active becomes Terminal using its actual holding, burns the keyed active token, preserves custody and non-root config, returns owner deposit, mints no Terminal witness token; missing holding/unknown/repeated termination refuses. |
| INV299-READONLY | Inspect accepts no signing dependency and has no fund/submit effect; stale/unavailable reads cannot print confirmed status. |
| INV299-PARTIAL | Submitted txids, confirmations and known partial state are preserved on interruption/timeout; create never overwrites, retries never silently reboot/resubmit. |
| INV299-ARCHIVE | Packaged commands work across process boundaries on one persistent node, with same registry/key and runtime identities; omitted command/page or altered receipt is detected. |
| INV299-DOCS | ADVISORY: supported instructions and named gaps accurately describe the candidate and receipt layer; no preprod/release/full-M1/KERI claim is inferred. |

## Model binding and evidence limits

Planning code revision 6b0feb5ca15d716982d1f31cbae4503a76223915; complete Lean tree f1e6a0edcaf9edce7369fd42add8b3677ddabeb2; Model.lean blob19806f297bf9a998e795747e0f1601b5376ebbe1, last-change commit5a6e307c1caf1b4cdd6b2fae082d4b0c33c338f4; Statements.lean blobe40c40c0165fbf110902544126e7f76edef6c25e. Freeze declaration/statement digests from lean/theorem-debt.json in receipt bindings.

`Singular.step`, `refusal`, `applyEdge`, `txOf` and `Statements.insert_active_transaction_row` / `update_terminal_transaction_row` govern the two operations. Their full hypotheses/conclusions remain unchanged: reachable state, admitted application approval, adequate fee, keyed mint/holding effects, custody preservation, non-root config preservation, no fold-required signer, output/deposit obligations and relevant refusals. Wallet signatures for transaction funding are not invented fold authorization. `terminal_mint_only_by_read` excludes a termination witness mint. Open application demonstrates registry mechanics only.

Concrete MPF authenticated roots realize commitment checking; `rootOf` is abstract FNV and is not compared byte-for-byte to chain roots. The client's persistence, freshness, network/input guards and partial journal are representation/safety obligations, not new Lean operations. Declare the exact concrete-to-model mapping and any extra assumptions proportionally. Existing control receipts support their exercised cases only; CLI receipts establish development-ledger behavior, not preprod, indexing service or full conformance. Product claims must use the suite's description language; report a concrete expressiveness gap rather than author raw product assertions or editing Conformance by default.

Unresolved affected Lean/consumer ambiguity is an acceptance hold and a concrete user story to the operator. No validator/model changes, new application, KERI/AID, Absent activation, witnesses, naming/escrow, full indexer or M4 scope. Live writes, signing-key reads outside generated development wallets, publication and merge need separate authority.

## Existing decision affecting termination

Open issue #304 also affects this journey: `txOfExit` and `update_terminal_transaction_row` describe a destination output on a fold that delivers no token there. Whether that row is physical or logical remains the operator's decision. The termination transaction-output correspondence and affected acceptance are held pending that ruling; independent CLI/persistence/insert/packaging work may continue. Do not manufacture a ledger output or datum or alter the model. Existing deposit recipients and clear delivering-output inline-datum obligations remain binding.

Dispatch baseline is accepted #278 merge `09026002e78f5b1e4d09cbd93ca2e7e7e356e4f2`, tree-identical to planning source `6b0feb5`. No Lean source or statement binding changed.
