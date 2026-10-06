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

As Bob, I need a registry directory before any command will run, and today only
`create` makes one. The saved identity, `registry.json`, is documented as public:
network, pins and the deployment record, with no key
(`offchain/cli/src/Singular/CLI/Registry.hs:11-15`). Its reference outputs sit
at the creator's wallet and are not in the state token's history.

Proposed: a read-only joining path takes the published identity record and the
blueprint the actor brings. It checks the record against public data before
writing anything: the create transaction found through the state token's
history spends the seed, mints `assetName(seed)` and carries the pins; every
reference output is live and holds the script whose hash the record names. It
then writes a fresh directory holding that identity and an empty journal.
A creator's mirror, journal and envelopes are never needed.

Rejected alternative: deriving the identity from the seed and blueprint alone,
then scanning the creator's address for reference outputs. Those outputs are
ordinary wallet outputs the creator may spend, so the scan cannot be complete.

## The directory keeps nothing the replay replaces

As a registry owner, I keep the identity, my own journal and my own envelopes.
The mirror file and the saved root commitment are retired with the mirror
adapter in the commands slice, and the slice receipt names every caller removed.
No cache survives. A directory written by an earlier release still holds those
files; they are not read. The lineage backend's accepted-fold call persists
nothing, because the next selection replays from history.

Rejected alternative: keeping the mirror as a cache checked against the replay.
The operator places caching in a later backend, and two trie sources in one
release would need a reconciliation rule no ticket specifies.

## Folding an insertion needs the booker's preimage today

This is a limit, not a decision. An insertion's request carries only the hash of
the datum it delivers, and today a fold that delivers a datum needs the booker's
preimage file (`offchain/cli/src/Singular/CLI/Preimage.hs:9-14`), so only the
booker can fold it. The operator contradicted that as a design on October 6: it
would make every application invent an off-chain service. The design is open in
[issue 419](https://github.com/lambdasistemi/singular/issues/419). No control asserts
the cross-actor refusal as correct behaviour; the existing unit test checks only
today's refusal. A termination fold needs no preimage and runs across actors.

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

As this ticket's owner, I implement only against published code. Both slices that
consume history start when the provider ticket's provider switch slice is
pushed, since `Session.history` arrives with it. A preparation slice builds
the pure replay and its chain oracles first, against nothing unpublished.
The epic owner forwards each as an inbox note. If the published contract does not
fit lineage reconstruction, that is a question, not a change to the provider ticket.

After acceptance of the intake head, this window runs one commit owner and one
mute persistent auditor, in its own detached audit worktree, with the models the
operator names. Until October 4 these were Claude claude-opus-5-5 and Codex
gpt-6.1-sol; from October 5, Codex gpt-6.1-sol and Grok grok-4.7. No gate authors or
draft seats are authorised. Merge readiness is the auditor's approval of every
checkpoint and exact-head CI green; the epic owner merges.
