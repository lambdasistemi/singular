# Recovering a registry command

As an operator creating a registry, booking a registration, updating a holding
or terminating its key, you need an interrupted transaction to keep its identity
so the next write can reconcile it without sending it twice. The retained
commands are described in [the registry command guide](registry-commands.md).

The former reader has replacement: none, issue 744. Recovery is performed by the
next write using its journal and the public chain.

## The commands that create a registry and register keys

As Carol, Alice or Bob running one of the commands of
[create a registry and register keys on the proved design](registry-commands.md),
you are interrupted in the same ways as above and promised the same thing: the
transaction keeps its identity, the next write settles it, and nothing is sent a
second time.

Each transaction is journalled as `prepared` before it is sent, under the step
that names it: `publish-state-script`, `publish-application-script` and `create`
for open datum's first creation, `publish-scripts` and `create` for Singular's,
then `book`,
`fold`, `reclaim` and `cleanup`. The journal also records what the first output of
the transaction must hold once it is on the chain: a reference script for a
publication, the state token for a creation and for a fold, the approval token for
a booking, a payment to the refund address for a reclaim and a cleanup. A creation
is journalled under the application and the wallet, because the name of the
registry it makes is known only once its seed is chosen. The other commands are
journalled under the registry and the wallet.

Before it builds anything, the next write of the same wallet reads its journal
against the chain. The table shows what it does with an earlier transaction in each
case.

| what happened to the earlier transaction | what the next write does |
| --- | --- |
| the node took it and the answer was lost | finds the first output on the chain, records the transaction as observed once, names it under `reconciled` and goes on |
| the process was killed after the send | the same |
| it never reached the node | stops with status 15, names the transaction under `unresolved` with the case `unknown`, builds nothing, sends nothing, and leaves the journal as it was |

A transaction the chain does not show cannot be told from one the network has not
yet delivered, and these commands never declare it excluded: the next write keeps
naming it and stops. Wait for the network and run the command again; a transaction
that lands is reconciled. When it can never land, the way out is `--state-dir`
naming another state directory, which starts a fresh journal for that registry and
wallet, or for a creation, for that application and wallet; the old journal stays
as a record.

## What the checks show

The recovery controls run the commands of the proved design as separate
`singular` and `open-datum` processes against one generated development node
per partition. Each sending command is interrupted three ways: the node takes
its transaction but the answer is lost, the process is killed after sending,
and the command prepares a transaction without sending it. The checks read the
process receipts, managed journals and saved signed bodies. The node's own
`devnet probe` confirms the outputs used to reach each holding.

The root flake declares the four retained partitions. Discovery prints their
complete list for the workflow matrix; the census refuses empty discovery,
unknown parts, duplicate parts and missing parts. Each partition runs by key:

```sh
nix run --quiet .#cli-recovery-partitions
nix run --quiet .#cli-recovery-partition -- state-line
nix run --quiet .#cli-recovery-partition -- holding-update
nix run --quiet .#cli-recovery-partition -- holding-terminate
nix run --quiet .#cli-recovery-partition -- termination-fold
```

| Partition | Commands exercised |
|---|---|
| Registry creation and registration | Application and Singular registry creation, registration booking, reclaim, registration fold and cleanup |
| Holding update | A registered holding is updated by its controller |
| Termination booking | The controller books a registered holding's permanent termination |
| Termination fold | A second wallet folds a booked termination from chain data |

Each interrupted transaction keeps exactly one prepared identity and a saved
body whose hash matches its journal entry. A later write by the same wallet
observes an included transaction exactly once. While an unsent transaction
remains unresolved, the next write stops with that identity and case; its
journal does not move and it builds or sends nothing. No command automatically
resubmits the interrupted transaction.

Every partition retains its original receipts, journals and signed bodies
under their source-relative paths, with a manifest binding the candidate, run,
partition and file hashes. The workflow verifies those hashes and records from
both wallets before uploading each partition separately. The receipt guard
refuses more than 52428800 bytes and accepts that boundary.

The current line's history, rollback, two-request and cross-wallet recovery
scenarios have been retired with their old bootstrap. Their trie observations
are not evidence for the retained commands. The separate facade lifecycle
controls continue to exercise fatal failure, restart, cancellation and joined
cleanup on their generated node. These checks establish process interruption
and recovery over the exercised cases, not durability across a power loss.
