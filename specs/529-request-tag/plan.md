# Delivering authenticated requests

## Story and authority

As a registry user, I can submit an authenticated request, find it despite pollution at the request address, and use a lawful exit with the ruled payments. As a reviewer, I can distinguish a reviewed component from a completed lifecycle and see every failed or uncovered obligation.

The acceptance items below were re-read from [issue 529](https://github.com/lambdasistemi/singular/issues/529) on 18 October 2026. The constitution and the ruled Lean model are the behavioral authority. Singular's root model remains frozen at `4254a3073fe0457946eba0a68d974c999c930ebf`, with Lean 4.27.0. The open-datum consumer amendment is a later, model-first chunk; no root Lean or simulator-law change is authorized by this plan.

## Four chunks, each reviewed and pushed

The operator's 18 October cut replaces the earlier slice order. Each chunk has its own short story, acceptance mapping, exact fence, gate and audit checkpoints. Each reviewed chunk is pushed to the same branch, `integration/498-protected-rejection`. Paths below are the expected areas of work; a later chunk's intake census fixes its exact file list before its first code commit.

| Chunk | Acceptance items and limits | Paths expected to change |
|---|---|---|
| 1. Authenticated booking | The booking portion of the Lean/on-chain/library/CLI items: exact request contents and tags, registry binding, booked time and bounded interval, immutable economics, codecs, builder and explicit create values. Include the boot repair, deployment parser/router, compiled identity consumers, and declared hash-change controls already in flight. Keep the mint-refusal and real booking evidence, with unexercised adversarial and public rows explicit. Finish comparison fixups and review012, then push. Hosted Demo1 supplies journey evidence; it is no longer a condition on this push. | The frozen booking fence: registry policy and validators, shared library and builders, CLI/deployment code, application consumers and identities, naming mirrors, two journey scripts, release/count checks, root comparison, and `specs/529-request-tag/`. |
| 2. Minimum economic fold and settlement | Only folds spend the state. Registration burns both request tags, donates the registration cost, pays exactly the declared tip and delivers the singular tag with its carrier. Termination burns trie-ready and singular tags, donates held value minus tip and pays exactly the tip. Add the tag-indexed discovery and selection the fold needs: untagged and malformed pollution must not change its reads or verdicts. Retain the donation, balance and gross-tip obligations and the applicable adversarial controls. | `onchain/validators/state.ak`, `onchain/validators/request.ak`, `onchain/validators/witness.ak`, affected `onchain/lib/` modules; `offchain/lib/Singular/Registry/` selection, codecs and fold builder; matching tests, CLI/journeys, identity consumers and receipt-derived conformance rows. |
| 3. Other request exits | Shared authentication of this registry's referenced state, with no state spend; permissionless expiry after both windows, including summed refunds for shared addresses. A stranger must execute expiry on devnet and the owner receives the ruled refund; live requests and terminations cannot use registration expiry. Implement requester-signed retraction in `[s + W_p, s + W_p + W_r)`, returning the full held value with the fee funded from ordinary inputs and no state access. Untagged junk is spendable by a stranger to any destination, while a tagged request cannot use that path. Include the CLI, public rows and malformed/moved-tag/unpayable-refund controls or their demonstrated exits. | `onchain/validators/request.ak` and shared reference-state helpers in `onchain/lib/`; `offchain/lib/Singular/Registry/TxBuilder/{Reject,Retract}.hs` and affected observation/discovery code; CLI, devnet tests and journeys, identity consumers and receipt-derived conformance rows. |
| 4. Open-datum model, then consumers | Amend the consumer Lean model first: nonce-bearing registration names use Singular's ruled commitment. For termination, the controller releases the singular tag and locked deposit into the request, receiving nothing back; the fold sends held value minus tip to the treasury. Restate the affected statements and regenerate the corpus before accepting consumers. This covers the application integration portions of the issue, not a change to Singular's root law. | `applications/open-datum/lean/`, `applications/open-datum/corpus.json` and generated oracle bindings; then affected application on-chain/off-chain code, tests, CLI/journeys, identities and public evidence. |

Receipt-derived conformance rows, exact model/artifact bindings and the command-recovery obligations of the affected commands travel with their behavior's chunk. Publish uncovered rows; do not type a passing state or promote harness evidence to product acceptance. The adversarial items from issue529 require an actual mint refusal or demonstrated exit, not a blanket claim from a successful build.

If hosted checks for chunk1 are red, their repair is the first item of chunk2, with the problem and evidence recorded in that chunk's plan. It does not retroactively turn the failed check into a pass or hold the reviewed chunk1 push.

## Disagreements with the historical issue text

| Issue wording | Later ruling used by this plan |
|---|---|
| A separate minimum bond and a forfeit with an undecided destination | The ruled economics use the registration cost and declared tip; no separate bond/reclaim mechanism is introduced. The registration cost and the termination's held value minus tip go to the treasury under the specified exits. |
| Owner reclaim | Implement retraction, not bond reclaim: the requester signs and pays in the ruled window and may fund the fee from ordinary inputs. The request's held value is returned as the model requires. This belongs to chunk3. |
| Both insert and terminate mint an application approval beside the request tag | Registration has its ruled trie-ready and application tags. Termination takes the genuine singular tag and locked deposit from application custody into the request and has no registration application tag. Apply the current model and the operator's treasury ruling, not the older wording. |

## Shared ownership and intake

Issue495 owns the mismatch proof against the authenticated referenced root, remaining per-member batch rejection admission not covered here, and state-validator work beyond the minimum cut above. Issue529 owns the shared reference-state helper and expiry ground. A legacy fold is not an economic fold merely because it has been renamed.

Before a chunk's first code commit, perform one census of every validator/hash consumer: counts, title lists, source pins, goldens, identity manifests, declared-change records and journeys. Put every relevant hit in that chunk's fence at the start. A later-discovered mechanical consumer is an intake miss to repair within the chunk, not a new scope question. A semantic change, model conflict or change beyond the mechanical consequence remains a question. No expected result is weakened to make a check green.

The approved Sonnet commit owner writes implementation and the persistent Sol auditor independently inspects checkpoints without product execution. No extra implementation seats are authorized. For chunk4, the already-approved Codex gpt-6-astra high Lean writer works between Sonnet slices, one writer at a time, using the same persistent auditor. The custody decision formerly held as Q003 is settled by the operator's 17 October treasury ruling; its model amendment still precedes code acceptance.

## Verification and delivery

Every build, test and packaged control uses its exact command inside this wrapper:

```sh
systemd-run --user --scope --quiet -p MemoryMax=12G -p MemorySwapMax=0 -- timeout 900 COMMAND </dev/null
```

There is no aggregate execution budget. A single cap hit is recorded and follows its explicit ruling or becomes a question. Use the narrowest real changed-behavior checks; preserve RED-before-GREEN evidence and distinguish setup failure, refusal, acceptance, local receipts and hosted execution. Record the candidate/tree, command, exit, duration and evidence hash. Do not replay hosted job lists locally.

For chunk1, finish the in-flight comparison fixup and review-record corrections, obtain review012 approval, rebase once, inspect status and the log, run `just ci` once, then push and open the draft PR. Neither Demo1 nor the later economic fold holds this first push. The failed local archive attempt and the unexecuted deployment carrier remain explicit; hosted CI supplies their evidence. Later chunks repeat their own plan, audit and push cycle.

Only signed commits, with no attribution trailers, enter the pushed range. Use the repository PR template with model revision, implementation mapping and verification limits. The first draft title is `Protected rejection (1.0.0)`. Keep it draft and held for the 22 October review; this owner never merges. No child PRs or GitHub comments; inspect CI through `gh run list` and `gh run view`, not `gh pr checks`.
