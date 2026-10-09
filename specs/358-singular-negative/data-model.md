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
| stranger-registers-a-taken-key | `registry insert --key alice-1 --wallet-skey bob.skey` | registry state validator, at the fold | `duplicate_refused_by_registry` | the same insertion of a key the registry never held | third slice |
| owner-registers-a-taken-key-again | `registry insert --key alice-1 --wallet-skey alice.skey` | registry state validator, at the fold | `duplicate_refused_by_registry` | the same insertion of a key the registry never held | third slice |
| owner-revives-a-terminated-key | `registry insert --key alice-1 --wallet-skey alice.skey` | registry state validator | `resurrection_refused_by_registry` | the same insertion of a key the registry never held | third slice |
| stranger-revives-a-terminated-key | `registry insert --key alice-1 --wallet-skey bob.skey` | registry state validator | `resurrection_refused_by_registry` | the same insertion of a key the registry never held | third slice |
| short-fold-of-a-booked-termination | `registry fold --pay-short 1 --wallet-skey bob.skey` over the pending termination of `alice-2` | application, at the fold | `fold_settles_additively` | the honest fold of the same request | third slice |

Each pair differs from its control in exactly one thing. The rewrite of a protected field and the release outside a fold are therefore signed by the controller, whose signature the application accepts. A stranger's signature is refused first (`update_requires_controller`), which would hide the rule under test and would leave no single mutant validator able to make the row fail; the stranger case is the pair `stranger-updates-the-key`.

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

For each pair one mutant validator removes exactly the rule that refuses it. Running the pair against the mutant must make the forbidden check report failure because the node accepted what the rule refuses, while every other pair on the same mutant is unchanged. A mutant that changes nothing must leave the row green, which the check treats as its own failure.
