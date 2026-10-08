# PR1 final-range audit: REVIEW-BLOCKED

Commission: NOTE-041, read and named in STATUS. Source verdict is BLOCKED. Final acceptance is separately pending hosted evidence. No earlier approval carries to this combination.

## Frozen binding and authority

- Range: `21f1d8560be008a8b2045e583fc384f10809260e..39575cd1be506876771377c457ad5b352cccaf0f`; final tree `c221493fe4f73bf0a75115fda084ba21739c7d54`.
- Lean tree `16ee2d4a4233130460b7e36daffbe6f2b8b9a8ef`; constitution 1.13, blob `79724aeb3dcdb44dbb7618eb98b11d9cec93ae85`.
- Gate14 SHA256 `36c61f61b9d1484ca3f9e1dea0758d536b94f5250c296a7ee404b84920ade5dc`, inheriting gate13 requirements and exact carriers. Draft PR supplied by parent: https://github.com/lambdasistemi/singular/pull/476.
- Same persistent mute auditor, clean detached checkout switched mechanically as explicitly permitted. Zero builds, tests, gates, controls, mutants, Lean, node or devnet executions; no author contact, delegation, tracked edits, rebase, push or GitHub action. Findings below are source deductions, not executed REDs.

NOTE-041, gate14, gate13, integration handoff, original author review-001, clean-handback, static-repair handoff, all nine integration-conflict records and the final full range-diff were read. Review covers the complete 26-commit range, its changed-path inventory, relevant source consumers, auto-merges and resolutions; it is not limited to the last author commit. Generated audio was not played or independently certified. No live hosted status was obtained.

## Blocking findings

### PR1-F1 — Bob's token-only fold is absent from the public description language

User story: Bob starts empty with the state token, folds Alice's public requests and inspects the resulting registry without Alice's files. Gate13 requirement5 and constitution VI:433–440 require the product assertion to be expressed, executed and rendered in the public suite language.

`conformance/lib/Conformance/Cli/Controls.hs:1719–1727` adds only the second actor's Inspect via `RunByToken reader target Inspect heldKey`. The public ordinary `Command` at :162 has no fold constructor. Existing `FoldUnevaluated` instructions are crafted validator controls, not this ordinary second-actor fold. The renderer :4001 onward renders RunByToken, but the story supplies no Bob fold instruction to render or judge. `tools/demo1_cli_journey.sh:1523–1587` asserts Bob's fold and no-Alice-file access in shell; this is not the missing public description-language clause. The deliberate-open classifier's source distinguishes successful fold plus the access failure from setup/other failures, but actual connected execution remains pending.

Affected claim is held. No invented replacement vocabulary or public pass is authorised.

### PR1-F2 — the token-only inspect clause remains bound to the saved-identity promise

User story: an outsider reads which identity promise the token-only second actor actually fulfilled. `specs/299-singular-cli/spec.md:26` still binds every write/read to saved registry/network/seed/pins and selected key. `Controls.hs:738–743` binds exactly that obligation and digest `344952d2e47e5daf254552a9c20e3e8fc094ddb0887865b067c46574f7eb1ab4`; `resolveObligation` :779–801 checks the exact specification row. The new token-only sentence :1721–1722 uses this same theorem binding. The spec file is unchanged in the reviewed range.

Exact digest agreement establishes the old row's identity, not semantic alignment with the new promise. Both author records disclose this mismatch. A-007b's selector retirement is preserved; this finding neither reinstates that promise nor invents a replacement row. Acceptance of the affected public identity claim remains held.

### PR1-F3 — the underfunded-create composition rejects its required absent journal, while its requirement omits a no-submission assertion

User story: the wallet cannot fund publication; create refuses before boot, writes no journal/pending file and leaves its seed unspent. The public sentence is `Controls.hs:1813–1817`.

The actual Backend UnderfundedCreate :1709–1774 starts a separate directory, snapshots it, records the create's submissions and journal counts, and previews the explicit same seed afterward. It checks the preview's success. These are real source checks, not observed connected results. It names the poor directory's journal in ProcessEvidence even when refusal properly leaves that journal absent.

The real verdict entrypoint `conformance/app-cli/Main.hs:93` admits receipts; Backend `holds` :757–769 does likewise. Admission `conformance/app-cli/Conformance/Cli/Admission.hs:457–505` unconditionally reads `peJournal`; :472–477 returns a problem when it is absent. Thus the commissioned correct no-journal refusal cannot be admitted by this path. Unlike the command journal-span reader, this process reader does not treat an absent journal as an empty span.

Separately, `Controls.hs:3222–3243` checks outcome, printed reason prefix, identical file snapshots, presence of a probe and admission problems, but does not apply `journalStill` or `nothingSubmitted` (:2496–2514). Process admission :508–538 establishes that retained journal submissions/bodies equal the receipt's records; it does not require those records to be empty. A consistently retained nonempty submission record is therefore not excluded by CreateUnderfunded's no-submission semantics. The source checker accepts such an admitted record if its other predicates hold. This is a predicate/consumer deduction, not a performed mutation or a claim that a live CLI submitted.

Seed admission :549–560 reads the retained probe and requires success; the backend explicitly requests the original seed. Those checks are present. The older unit doubles and compilation receipt do not prove the actual funding refusal, failed publication role or preservation. The absent-journal incompatibility and missing no-submission assertion block the evidence composition independently of that pending execution.

### PR1-F4 — carrier read-back turns a provider failure into an asserted absence and a completed read step

User story: after publishing a reference, a provider cannot answer its read-back. The user must see an unreadable provider, not a claim that the output is absent.

`offchain/cli/src/Singular/CLI/Create.hs:475–484` returns `LP.outputs ... (LP.AtTxIn i)` through readStep, then maps every `Left ReadFailure` to an empty list. :506–513 consequently reports Partial with “the reference output ... is not live”. A backend failure, released view or other read refusal supplies no successful absence fact. Provider `queryOutputs` returns these failures through ExceptT, not necessarily as exceptions. `Session.hs:705–719` times the normally returned Either, and `Trace.hs:334–335` maps its successful IO return to Done. A lower provider exchange event does not correct the false not-live conclusion or this enclosing Done.

The previous `SessionIO.outputsAt` used `requireFact` (:67–74), which throws the typed read failure before a successful read step can be reported. The new reference resolution elsewhere also preserves ReferenceUnreadable; this read-back is the inconsistent consumer. This is a regression against the bound #416 failure-attribution story (`specs/416-protocol-narration/spec.md:24–27,101–106`) and gate14's preservation mandate. It was explicitly left for assessment in conflict003. No model amendment or new failure ruling is inferred.

## Source coverage and limits

| Frozen requirement | Source assessment | Acceptance evidence |
|---|---|---|
| Token derives identity; selected state output really holds it | StateToken resolver checks actual selected MaryValue policy/name/quantity as well as address/datum; decoy-before-real controls include tokenless/wrong-policy/wrong-name outputs. Mint, supply, seed and four pins are checked. Registry JSON is not an identity fallback. | Current focused/runtime receipts pending. |
| Carrier integrity and identity refusal paths | Koios queries verify actual indexed/live outputs; reference admission computes local script hashes, rather than trusting supplied hash labels. Raw mint/input/output and unbound/unverified limits remain explicit. | Public provider availability and connected behavior not proved. F4 affects create read-back. |
| Provider first, lazy wallet, no hints | findReferences searches required roles through provider first; all-provider and empty-role paths avoid wallet discovery; needed missing roles use wallet, exact missing role/hash remains. No hint parser or hint fallback survives. | Current focused source-call and consumer controls pending. |
| Funding before boot, reused state carrier, no identity file | Create composes boot consumption/change/fees plus later publications before directory/pending/submission; reused-state path retained. Synthetic fixture/cost limits remain. | F3 blocks public evidence composition; actual small-wallet refusal/role/unspent seed pending. No universal closed-wallet funding claim. |
| Connected public Bob inspect/fold and deliberate Alice-file-open rejection | Token-only empty actor/journey source and precise control classification present. | F1/F2 block public claim/binding; actual hosted connected journey and real open control pending. |
| Selector retirement and mixed live obligations | A-007b history/reason retained, no last-receipt/state transfer. Retirement metadata survives absent/partial coverage and mixed live duties remain judged; discovered instruction extent controls retained. | Current combined retirement/#419 checks pending. R-ID remains separately unmet PR2 under A-013, not reopened here. |

#419 public fold inputs/buildFold, datum delivery, carrier refusal and history-withholding/admission consumers were checked at their changed integration boundaries; no new weakening was found there. #416 typed trace, command/run and recovery registrations and closed-stderr journey controls survive the merged source, subject to F4. #449/#470 recovery scripts use the new token while retaining their bounded scenarios; source preservation is not hosted behavior. Requested-token scope before validation denotes the request and does not itself establish resolved identity. Combined carrier/parameter read labeling and legacy pending-file precedence establish no extra success fact in this review; dedicated execution evidence is still owed. No clear Lean contradiction was established. Planning and synthetic cost fixtures do not extend Lean or confer connected/model-root fidelity.

## Supplied receipts, provenance and pending acceptance

Twelve planning Git blobs match the supplied manifest SHA256 `3ef5da3cfe1499c72ac464cd645d76f0986146430ceeb988bc2b07270614543b`. Original/rebased24 subject/order map matches its Git inventories, SHA256 `f5d8b69da7078d116fe606b9550e32817b9806050656a8697bbdab99c8a681a6`. Final full range-diff hash `29f8034fc214c92b41d0bdf46a5c44997e52c41f5e95f01609e2f2dd4010d920` and ignore-space/empty whitespace hashes match supplied bytes. All nine conflict-handoff hashes, original review hash `8d173191afdcb61e2a800f7d3e44e80337bbf6a37e38dee44e24d692c5903dde`, clean-handback `87f1f9d89ee05dc3b973501558442f55feb869c497cf677d41a087374d04f559` and static-repair `9a9cf143100b4c0e69ee6364ab1953a2798cb971b566f5c26c4c29824a40cd27` match. Lean/onchain-source/blueprint has no relative change; onchain-release DEMO1 is documentation. Historical reports/archives remain historical.

All four final-head r2 raw static logs were read and their actual producer exit files contain `0\n`, hash `9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa`. Exact bindings manifest hash `0590e988675073be448ce94c86c91ee0df848215126f60c6c29766d7480c2378` matches.

| Producer command/CWD | Raw log SHA256 | Supplied result |
|---|---|---|
| root: nix develop --quiet -c just lint | b0ab575efd72b899090a3f97826041ae94c35044b9abe875091888693c9b4d9b | exit0, static only |
| conformance: nix run --quiet .#hlint-check | bbca4c612591e292cf47c7014773b38797e523da6f788d9671b289c4eafebc37 | exit0, static only |
| conformance: nix run --quiet .#format-check | e45f33461e52db8fd5fa0a36b64c9f7fb8663e3d89c99e2a98ef35e44f50c2d2 | exit0, static only |
| offchain: nix run --quiet .#lint | 841b24cd7922ab3ca1196a3ca08be56c0d0cafa22b86b71565c79d00da0229be | exit0, static only |

The format raw log includes an ignored SQL-busy diagnostic; its retained producer exit is still0. Initial r1 failures remain disclosed in the parent record; no behavioral RED or waiver follows. Source repair restored the terminate receipt present in both original source and main, rather than inventing a new one; remaining final static changes are eta reductions, shell comment spacing and formatting.

Old author log hashes `7a92cd7e3c4e34ddd0358e23051e7447b1fe698fbb55d1d105ec9c7ba79e0d80` and `760c97554ab4ac1ce6477f5525952ffd7ce4a9592f12ad485f97ee61e48ef3e9` match full supplied logs: 39 examples/0, compiled controls and eight classification stand-ins. They remain bff/old working-tree evidence only; no integrated-head node run, actual Alice-file open or connected funding result follows.

Pending at this report: exact-head U-K/U-R/U-C and combined retirement/#419 selected tests; component build, CLI flags/controls and docs carriers; all required hosted jobs, conformance/book current extent, demo1 archive journey, real two-actor deliberate-open control, restored refusals with actual small-wallet result, five attach parts/aggregate, accepting/lost-answer/killed recovery and current development-shell checks. Missing receipts are pending, not behavioral REDs or passes. No full local campaign is authorised for this auditor. A source repair requires a fresh exact binding and review; the four source findings do not disappear when an unrelated CI job turns green.

Issue437 stays open. PR2 archives, accepted interfaces and deferred wallet/page/release/reference/action-identity work remain outside this review. Parent/epic retain integration and merge authority. This report requests no new seat or behavioural campaign and supplies no repair strategy or invented ruling.
