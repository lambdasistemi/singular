# Plan: separate booking, fold, reclaim and reject

## Model binding

The Lean model is unchanged. The code carries the `lean/` tree last changed by `53ad27ff` (#344, which added the batch questions and changed no law). The transitions used here are the model's as they stand:

- a booking;
- a fold of one request, which the model states equals a single step (`fold_batch_of_one_is_step`);
- an owner's retract in its window;
- a reject (#320).

The processing and retract windows follow `requestPhase`. On chain, the fold's window check is `interval.is_entirely_before` with an exclusive upper bound. That is why the client compares the built bound with the deadline slot as "at most".

This change decides which process and which wallet performs each transition. It does not change the transitions.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Combined form | Keep it only when asked for: `--fold` on insert and terminate. It runs the same fold routine. | The controls and the conformance harness drive one process per insertion. One flag moves them without changing any published row. |
| Where the fold gets an insertion's envelope | A preimage store in the registry directory, keyed by the envelope hash, written before the booking is signed and verified against the request before the fold is built. | The request carries only the hash. The envelope itself travels only in the booking's redeemer, which a node query cannot read. |
| How many requests a fold takes | Exactly one, optionally named. | The fold's journal line binds one key and one root pair. Reconciliation, rollback and replay depend on that. |
| Deadline | Time is the authority. The slot is reported only when the node converts it, and is never estimated. | Beyond the node's conversion horizon a slot cannot be computed. An estimate would be a guess presented as a fact. |
| Deadline guard | A fast refusal on the host clock with a thirty-second margin, which is at least the library's longest fallback width. Then a check of the built bound before signing: at most the converted deadline slot, or, when there is none, the bound's own converted time at or before the deadline. An unconvertible bound is refused. | The guard alone cannot prove the bound. Preparation can outlast the margin, and the library computes its fallback from a later clock. |
| Searching for the bound's start time | Use only times the node converts. Never step past its horizon, and never infer an ordering from a failed conversion. | Otherwise a fold the library bounded inside the horizon is refused at random, or a time is invented. |
| Reject windows | Judge them on the reject's own view, the tip slot against the converted retract deadline. An unconvertible deadline counts as still open. | Host-clock skew would let a reject take a request that is still inside its window. |
| Reject refund evidence | Bind the receipt's money to node reads: the request's locked value before, and the designated refund output after. Also bind each saved body to its claimed id and to the journal's hash. | A receipt checked only against itself proves nothing about the money. |
| Reclaim window | Judged as the reject's is, reusing the same reading. | One rule for one question. |

## Slices

Each slice is one change, reviewed at each step by an independent auditor, and pushed in its own pull request.

| Slice | Change | Pull request |
|---|---|---|
| Booking and fold | `insert` and `terminate` book only; `registry fold`; `--fold`; the preimage store; the deadline guard and the built-bound check; the journey, controls, docs and harness moved | #367 |
| Reject | `registry reject` clears requests past both windows, with refunds bound to node reads | #374 |
| Reclaim | `registry reclaim` returns the requester's own request inside its retract window | follows |
| Cross-wallet recovery | a control: a fold by another wallet, interrupted, is reconciled by the requester's next write | follows |

## Verification

These are the continuous-integration jobs, run on the exact head of each pull request:

- `cd offchain && nix run --quiet .#cage-tests`: the parser rows and the pure decisions (deadline margin, built-bound check, bound search, preimage, fold target, reject and reclaim windows, refund shape).
- `nix run --quiet .#demo1-cli-check`: the Demo 1 journey from the release archive. It runs booking, then a fold by another wallet, then inspection, for insertion and termination; an update; the fast guard's refusal; reject; and reclaim.
- `nix run --quiet .#demo1-cli-controls`, `nix run --quiet .#demo1-cli-attach`, `nix run --quiet .#cli-recovery-controls`: the controls through the combined form.
- `nix run --quiet .#cli-flags-check`: documented flags equal `--help`.
- `nix develop --quiet -c just ci`: lint, format and the documentation checks.
