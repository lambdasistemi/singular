# Pairs, verdicts and readbacks

As a reviewer, I want every forbidden move tied to the script that must refuse it and to the accepting control that differs from it in one thing, so that a pass cannot come from a different failure.

## The pairs

Each row is one forbidden move and its accepting control. The command spellings are the ticket's own; the last column says where each pair is delivered. The model statements are those of the open-datum application model.

| Pair | Forbidden command | Refused by | Model statement | Accepting control | Delivered in |
|---|---|---|---|---|---|
| stranger-updates-the-key | `registry update --key alice-1 --wallet-skey bob.skey` | application spending contract | `update_requires_controller` | the controller's own update of that key | first slice |
| controller-rewrites-protected-fields | `registry update --key alice-1 --wallet-skey alice.skey --tamper controller\|deposit\|token\|address\|datum` | application spending contract | `update_preserves_custody` | the controller's update with no tamper | second slice |
| stranger-terminates-the-key | `registry terminate --key alice-1 --wallet-skey bob.skey` | application, at the termination booking | `bookTerminate_inversion` | the controller's own termination booking | second slice |
| controller-withdraws-outside-a-fold | `registry withdraw --key alice-1 --wallet-skey alice.skey` | application spending contract | `only_fold_releases` | the same release made inside the honest fold of the booked termination | second slice |
| stranger-registers-a-taken-key | `registry insert --key alice-1 --wallet-skey bob.skey` | registry state validator, at the fold | `duplicate_refused_by_registry` | the same insertion of a fresh key the registry never held, run from the same registry state | third slice, part one |
| owner-registers-a-taken-key-again | `registry insert --key alice-1 --wallet-skey alice.skey` | registry state validator, at the fold | `duplicate_refused_by_registry` | the same insertion of a fresh key the registry never held, run from the same registry state | third slice, part one |
| owner-revives-a-terminated-key | `registry insert --key alice-1 --wallet-skey alice.skey` | registry state validator | `resurrection_refused_by_registry` | the same insertion of a fresh key the registry never held, run from the same registry state | third slice, part one |
| stranger-revives-a-terminated-key | `registry insert --key alice-1 --wallet-skey bob.skey` | registry state validator | `resurrection_refused_by_registry` | the same insertion of a fresh key the registry never held, run from the same registry state | third slice, part one |
| short-fold-of-a-booked-termination | `registry fold --pay-short 1 --wallet-skey bob.skey` over the pending termination of `alice-2` | application, at the fold | `fold_settles_additively` | the honest fold of the same request | third slice, part one |

Each pair differs from its control in exactly one thing. The rewrite of a protected field and the release outside a fold are therefore signed by the controller, whose signature the application accepts. A stranger's signature is refused first (`update_requires_controller`), which would hide the rule under test and would leave no single mutant validator able to make the row fail; the stranger case is the pair `stranger-updates-the-key`.

A control runs from the same state as its forbidden command, with the same signer and the same booking and fold path. For the two taken-key pairs that state is the registry after `alice-1` became active. For the two revival pairs it is the registry after `alice-1` was inserted, folded, terminated and folded. A control that skipped that setup would differ in two things. The control's key is fresh: never used earlier in the run, and the part asserts that it is not, so freshness is checked and not assumed.

The last pair is one connected sequence over one request: the termination is booked and left unfolded (`registry terminate` without `--fold`, which stops at the pending request), the short fold is refused with the request still pending and the deposit held, and the honest fold of that same request then burns the token, leaves the key terminal and pays the controller in full. It stands for rows 11, 12 and 12b of the preprod demonstration.

An insertion refused at its fold leaves its booking pending; its owner reclaims it inside the retract window with the ordinary command.

## Reachability on the permanent contract

The permanent two-edge contract has merged (constitution 1.14.0): the single active model admits only registration (`insertActive`) and permanent termination (`updateTerminal`). Every pair uses only those two registry edges or an application spend, so all nine pairs are reachable on it, none drops, and the model statements above stand. The refusal of the five excluded edges belongs to that contract's own controls, not to a pair here. The host reads the expected script from the registry it opens, so no code depends on which contract the generated node was created with, and every pair runs on the permanent contract.

Rejection pairs: none exists in the ticket's table. Any that protected rejection creates enters as `pending #498/#529`.

## Verdicts

A host run ends in exactly one outcome per command.

| Outcome | Meaning | Counts as a refusal |
|---|---|---|
| refused-by-expected-script | the node's own verdict names the expected script among the scripts that failed | yes |
| refused-by-another-script | the node refused and names a different script | no |
| client-refusal | the host or its shared sources stopped before submitting | no |
| encoding-failure | the transaction could not be built or serialised | no |
| setup-failure | no node, no socket, no funds, a missing request or holding | no |
| accepted | the node took the transaction | no (it is the control's expected outcome) |

The expected script is a role (registry state validator, application spending contract, application at the fold) resolved to the script hash of the registry the command opened, never a literal typed into the check.

## Readbacks

After every refusal the host reads the registry state output, the key's holding and the wallet's outputs again. The pair's receipt carries both reads; the check passes only when the state root, the holding's output reference, value and datum, and the wallet's outputs are equal before and after.

## Mutants

For each refusing rule one mutant validator removes exactly that rule. The mutation is a source patch that changes only that rule, applied in a scratch copy of the checkout; the application's own identity manifest (`applications/open-datum/onchain/script-identity.json`), which the release check compares against, is then regenerated in that copy from the mutant's own build by the recipe the runner carries (the application project has no committed recipe; its shape is the registry's `script-identity-regen` over the application's own plutus blueprint), so the release identity check still runs and passes on the mutant archive.

Running a pair that the rule refuses against its mutant must make the forbidden check report failure, because the node accepted what the rule refuses. That is read from the host's receipt of the forbidden command (outcome success), not from the part's exit status: a move that consumes state leaves the part's own control stage nothing to run on, so the part may fail afterwards, and that later failure is evidence of the acceptance. Beside the pairs the rule refuses, a mutant runs one declared control pair that a different rule refuses, which must stay green on the mutant. A mutant that changes nothing must leave the forbidden check passing, which the command treats as its own failure.

Several pairs can be refused by the same rule, and one pair by two rules, so mutants are counted by the set of rules they remove: eight mutants cover thirteen pairs.

| Rule a mutant removes | Where | Pairs the mutant must flip |
|---|---|---|
| the controller must sign an update | application, update-controller-signature | stranger-updates-the-key |
| the continuation stays at the holding's address | application, update-escape | controller-tamper-address |
| the continuation keeps the holding's control | application, update-control | controller-tamper-controller, controller-tamper-datum, controller-tamper-deposit |
| a token continuation stays at the holding's address and keeps the holding's recorded control: both rules, removed together | application, update-escape and update-control, removed together | controller-tamper-token; expected side flips: controller-tamper-address, controller-tamper-controller, controller-tamper-datum, controller-tamper-deposit |
| a termination booking is the controller's: owner and controller signature | application, app-owner and app-controller-signature, removed together | stranger-terminates-the-key |
| a holding is released only inside a fold | application, release-no-fold | controller-withdraws-outside-a-fold |
| a fold pays the controller at least what is owed | application, release-additive | short-fold-of-a-booked-termination |
| an inserted key is not already in the registry, active or terminal | registry state validator, occupied-key refusal at the fold | stranger-registers-a-taken-key, owner-registers-a-taken-key-again, owner-revives-a-terminated-key, stranger-revives-a-terminated-key |

The rule that the continuation keeps at least the protected deposit in its value (`update-deposit`) is not in the table, because no pair is refused by it. The pair `controller-tamper-deposit` rewrites the deposit recorded in the continuation's datum and leaves the value untouched; the recorded control is compared before the lovelace bound, so `update-control` refuses it, and `update-deposit` would not fire on it even if it were reached. The pair that would exercise `update-deposit` (a continuation that keeps its datum but pays less lovelace than the deposit) is not built here; the rule is listed as uncovered, not counted as covered.

The rule that exactly one output carries the key's token (`update-token`) is not in the table either. The pair `controller-tamper-token` moves the token into one plain output at the controller's wallet address, so exactly one output carries it and the move is refused earlier: by `update-escape` (that output is not at the holding's address) and, with that rule removed, by `update-control` (a plain output records no control). Removing `update-token` alone, or `update-control` alone, leaves the pair refused; removing `update-escape` and `update-control` together flips it, which is why the table has the joint mutant. As far as the validator reads (a reading of the validator, not a node result), no transaction the node would otherwise accept isolates `update-token`: the token is a single unit, so more than one output cannot carry it, and none can carry it only if it is burned, which the minting policy does not allow in an update. The rule is listed as not reachable by any pair, not counted as covered.

The stranger who books a termination fails the owner check and the controller-signature check alike, so removing one of them alone changes nothing the node sees; the two are one mutant because they are one rule, not two differences. The first mutant brief pins the table from the failing rule names in the node's own trace and corrects any row in the same commit.

Every other pair staying green under a mutant is derived, not re-run. When the mutant of rule B flips pair P, that shows only rule B refuses P; with any other rule A removed and B intact, P is still refused. Across the whole mutant set, every pair's stay-green under every other mutant follows from its own mutant's flip. This needs every pair to have a mutant that flips it and each mutant to change only its named rule: the patch is the evidence, and the declared control pair catches a patch that disables more. For a mutant that removes several rules, the same reading holds with a set: a pair stays refused under another mutant when at least one rule that alone refuses it is still in place. For the token pair, the mutant that removes only `update-escape` leaves `update-control` in place, and the mutant that removes only `update-control` leaves `update-escape` in place, and each of those rules refuses the pair alone. It does not yet hold for the four registry pairs: until the registry state validator's mutant exists, their stay-green under the application mutants rests on the declared control pair alone. The mutant of the registry state validator needs a blueprint that the shared loader accepts; if no route exists inside the host's own files, the mutant check of the four registry pairs is named pending with a ticket, and no pair is credited for it.
