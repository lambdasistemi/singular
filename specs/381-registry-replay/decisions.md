# Decisions for rebuilding registry tries from history

As the epic owner, I want the choices this intake makes separated from the
rulings already in force. The intake was accepted on October 4. The edge
coverage and the cross-actor step were then ruled by the operator; the rest
are engineering choices accepted with the intake.

## Rulings in force

As a registry user, I get the operator's rulings of October 2 to 4 unchanged.

| Ruling | Consequence here |
| --- | --- |
| Demo 1 runs every actor against unverified Koios, with no node and no shared registry directory | Each actor rebuilds the trie from public history alone |
| Trie-state interface first; full public lineage as its first backend; caching later | One lineage backend, slow and correct; no cache in this ticket |
| `singular` is a Lockness terminal with the application role built in | The root check is the terminal's consistency check, not ledger verification |
| No plugins or hooks; generic history only | The provider serves asset history; the terminal interprets it |
| Public networks are read-only | No transaction, key or secret is touched; journeys run on the development network |

## Which edges the two-actor journey covers

As Alice and Bob, we operate the two edges the CLI books from public data alone:
`insert` books `insertActive` and `terminate` books `updateTerminal`
(`offchain/cli/src/Singular/CLI/Plan.hs:138,195`). `registry fold` refuses every
other edge by name (`CLI/FoldRules.hs:264-273`). The intake asked which edges
the acceptance must cover. The operator ruled on October 4: the CLI's two edges,
plus the existing reject and reclaim. The other five edges are outside the Koios
demonstration. There is no library-built seven-edge history and no CLI booking
for them.

The replay stays edge-generic. It applies whatever edge a request datum names,
through `walkEdge`, and claims no coverage for edges no test history contains.
The mixed-fold and root-check tests are unchanged. A mixed fold still needs a
test-only builder variant, because the connected fold applies every request and
reject rejects every one.

## Each key is changed only by its controller

As a key's controller, I alone update and terminate it. The CLI refuses anyone
else (`Plan.hs:96-103`), and the open-datum application requires the
controller's signature for insertion, update and termination
(`onchain/validators/open_datum.ak:44,54,58,213-216`). So the cross-actor step
is the fold. Alice folds the termination of a key Bob created, with the
membership proof from her own replay, and Bob folds Alice's likewise. Each
actor inspects the other's keys from their own replay. The journey keeps its
not-the-controller refusals. This is the operator-corrected acceptance wording
of October 4.

## Joining a registry from public data

The operator's October 6 definition supersedes the proposed identity-file join:
"demo-1 is Alice and Bob on separate terminals and directories, starting empty,
reading the web page and provider (Koios)". Neither actor is the creator. A third
creator-only fixture may make the development registry, but its creation files
are never shared with either user.

Joining by state token has since merged ([issue #501](https://github.com/lambdasistemi/singular/issues/501)),
and the managed state directory ([issue #485](https://github.com/lambdasistemi/singular/issues/485),
PR 525) removes the per-registry directory. Every command derives the seed, pins,
windows, tip and reference outputs from the state token, state datum and release, and
chooses where its own journal lives. The former proposal to import a creator's
`registry.json` and verify its fields stays withdrawn; this ticket ships no joining
command and no substitute joined directory.

On October 9 the epic owner added the rule for the tests: Bob starts with the state
token, his wallet and a Koios URL, and any assertion that reads a registry directory is
rewritten rather than kept, whether it is a foreign actor's directory, the creator's
directory or any state directory. The journey's assertions read command receipts,
`inspect` reads made with the state token, and access traces.

The registry page, generated from the chain, belongs to
[issue #503](https://github.com/lambdasistemi/singular/issues/503). The two journey rows
that read it stay pending on it, with their joining receipts attached. The complete
integrated journey ships in this pull request, stacked on PR 525.

## The directory keeps nothing the replay replaces

As a registry owner, I keep the identity and my own journal. Insertion envelopes
are carried publicly by their requests under #419.
The mirror file and the saved root commitment are retired with the mirror
adapter in the commands slice, and the slice receipt names every caller removed.
No cache survives. A directory written by an earlier release still holds those
files; they are not read. The lineage backend's accepted-fold call persists
nothing, because the next selection replays from history.

Rejected alternative: keeping the mirror as a cache checked against the replay.
The operator places caching in a later backend, and two trie sources in one
release would need a reconciliation rule no ticket specifies.

## Folding an insertion uses its public carried datum

The October 6 #419 ruling is implemented on main: a request carries the datum
its delivery writes, and a folder uses public inputs (`Singular.buildFold`).
The earlier hash-only/preimage-file limitation is superseded. #381 must execute
another actor's insertion fold without access to the booker's directory.

## Recovery is observed from public history

As a user whose process died after a fold was confirmed, my next command observes
that fold once from public history and never submits it again; after a rollback it
reads the restored public root. With the mirror and the saved root gone, the
receipt fields that reported their writes (`stateFollowed`, `mirrorRewound`,
`mirrorAdvanced`, and `applied` where it meant a mirror write) are removed, and the
recovery controls check the replayed root, a single journal entry and no second
submission instead. One conformance clause, inspect with the saved proof material
moved aside, loses its witness because inspect no longer reads that material; it is
published uncovered with that reason, by the epic owner's ruling of October 6.

## Mixed folds are evidenced by the chain

As a reviewer, I need a mixed fold's expected root to come from somewhere
other than the replay. The model composes per-request exits, and a reject
leaves the state unchanged (`lean/Singular/Model.lean:1068-1075`), but it has no
single transaction mixing the two. The test's oracle is the state validator
accepting the fold: on the development network, or under the ledger evaluator
the provider ticket brings, over the compiled validator. Building such a fold
needs a test-only builder variant; production builders are unchanged. No model
correspondence is claimed for mixed folds as one transaction.

## Failed transactions and named refusals land first

As a registry user, I need the replay to ignore a transaction that failed its
scripts. A provider lists every transaction that carried the state token, and a
transaction whose `isValid` flag is false spent only its collateral, whatever
its body inputs name. Read as a spend, it would look like a fork. The replay
leaves it out of the lineage, so the lineage and the trie are those of the same
history without it.

As a person reading a refusal, I need it to say which registry, which
transaction and what went wrong. The epic owner ruled on October 4 that the shared
`TrieFailure` type carries that payload, and that this ticket makes the change:
incomplete history names its reason, roots that part name both roots or the record
that cannot be read, and a wrong registry, a stale state or a missing proof name what
a person needs to act. An instance passes only what it knows. Existing commands keep
their refusal names, outcome classes and exit statuses.

Both changes land on main before the commands move onto the replay, so the provider
ticket builds on the payload-carrying type rather than rebasing across it.

## Sequencing and staffing

As this ticket's owner, I implement only against published code, and the base is PR 525.
The October 9 staffing ruling supersedes the October 7 roster: a Sonnet ticket owner, a
Muse source writer and a GLM auditor, no other seat, one writer at a time. The
[mandate](mandate.md) quotes the ruling. This ticket merges immediately after
[issue #485](https://github.com/lambdasistemi/singular/issues/485), in the slot the desk
grants, and is not rebased onto main before it. If the published contract does not fit
lineage reconstruction, that is a question, not a change to the provider ticket.
