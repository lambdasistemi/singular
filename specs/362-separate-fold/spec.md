# Booking and folding as separate commands

As a requester, I book an insertion or a termination with my own wallet. The receipt names my pending request and the time by which it must be folded.

As the registry's folder, I fold that pending request with my own wallet, in a separate command.

As a requester whose request nobody folded in time, I take my request back. Once its windows have closed, anyone can clear it.

Each of these is an ordinary `singular` command. Each signs with the wallet given to it and journals its own transactions.

## Why one command was not enough

`singular registry insert` and `singular registry terminate` used to book and then fold in the same process. A fold failure left the requester's command `partial`, with a live booking and a fold they never meant to run. On preprod that fold expired before it reached the node (`OutsideValidityIntervalUTxO`, #363). The two-player demonstration (#359) needs a termination booked and left pending, then a short fold refused, and then an honest fold by someone else.

## What the commands do

| Command | Who runs it | What it does |
|---|---|---|
| `registry insert`, `registry terminate` | the requester | Book only. The receipt names the pending request, the booking, and the fold deadline as a time, plus a slot when the node can convert it. For an insertion it also names the envelope; for a termination, the live output the fold will release. Nothing is folded, and the registry root does not move. |
| `registry fold` | the folder | Folds the one pending request with the folder's wallet. It can be named with `--request`. Insertions deliver the key's token with its envelope; terminations release the live output and pay the deposit back. |
| `insert --fold`, `terminate --fold` | either | The explicit combined form: book, then run exactly the same fold. |
| `registry reclaim` | the requester | Retracts the caller's own pending request inside its retract window. Before that window, and after it, the command refuses, saying when the window opens or that it has closed. |
| `registry reject` | anyone | Clears pending requests that are past both their processing and retract windows. Each owner gets back the request's value, less the folder's tip, in the designated refund output. |

## Refusals before anything is signed

Every refusal names its reason. The node is never asked to judge something the client already knows is wrong.

- **Fold:**
  - nothing is pending;
  - the named request is not pending;
  - more than one request is pending, named in full;
  - the envelope for an insertion is missing, or does not hash to what the request names;
  - the request's edge is not supported;
  - the funding output is not the wallet's;
  - the outlay is past `--max-outlay`;
  - too little of the processing window remains;
  - the built transaction could be included at or after the deadline.
- **Reclaim:**
  - the caller does not own the request;
  - the request is not pending;
  - the time is outside the retract window.
- **Reject:**
  - nothing is pending;
  - a pending request is still inside one of its windows.

## Guarantees

- A booking-only command submits exactly one transaction and never moves the mirror, the root or the saved state.
- There is one fold routine. `registry fold` and the combined form both run it.
- An insertion's fold delivers exactly the envelope whose hash the request names. A missing or altered envelope is refused before any build.
- A fold spends exactly the request it names, or the single pending one. Any other request input is refused before signing.
- **Deadline guard.** A fold is never signed if it could land at or after the request's deadline, which is the request's submission time plus the registry's processing time.
  - A fast guard refuses when less than thirty seconds remain on the host clock.
  - After the transaction is built and before it is signed, its validity upper bound is read from the body and checked again. The bound is exclusive. When the node converts the deadline to a slot, the bound must be at or before that slot. Otherwise the bound's own time must be at or before the deadline.
  - A bound that cannot be converted is refused unsigned.
- Booking, fold, reclaim and reject each sign with the wallet given to that command.
- **Reject:**
  - It judges the windows on the node's own view, the tip slot against each converted deadline, never on the host clock.
  - A deadline the node cannot convert counts as still open.
  - Every amount on its receipt equals what the node reads before and after.
- **Reclaim:** judges its window the same way.
- The next ordinary command reconciles a fold interrupted after submission, whichever wallet and command ran it.

## Limits

- **One request per fold.** A fold takes one pending request. A second pending request is refused by name. A fold of several requests in one transaction is a separate change.
- **Shared registry directory.** The folder finds an insertion's envelope only when it shares the requester's registry directory. A folder elsewhere would need `fold --envelope FILE`, which is a separate change.
- **Post-build check on the development network.** That network cannot build a fold near its deadline at all, because the library's fallback times fall past the node's conversion horizon (#370). There, the journey shows the fast guard's refusal. The post-build check is proved by unit tests over a built bound with a controlled clock and converter.
- **Converted-deadline equality.** On the development network the deadline lies beyond the node's conversion horizon, so its slot is reported as unavailable. That the built bound equals the converted deadline is still to be shown, on the authorized preprod run. No run has shown it yet, and CI does not claim it.
- **Preparation speed.** It is not solved here. This change reports and enforces the deadline. The persistent indexer (epic #371) is what addresses preparation time.
- **Refund shape.** A reject builds the refund only as the whole owed amount in the designated output. The model also admits a split refund that the chain refuses (#361). A green reject is this shape on this chain.
- **Early rejects on chain.** The chain admits a reject in every window. Refusing an early reject is the client's policy.
- **Interrupted reject.** No control covers a reject interrupted after the node accepted it.
- **Attach take coverage.** The demonstration's attach take covers 5 of its 32 approved cases by design. Its reclaim step can fail intermittently on the development network (#370).
