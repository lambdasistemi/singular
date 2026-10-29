# Data for folding a batch of registry requests

Issue 746. Records the fold introduces or changes, their fields and their rules. Placement is in
[the modules model](modules-model.md).

## Records

| Record | Fields | Rules |
| --- | --- | --- |
| Policy holdings query | a policy | answers every live output that holds at least one asset of the policy, with its output reference; an incomplete page is a failure, never a shorter answer |
| Discovered request | output reference, request kind (registration or termination), key, approval name, the folder's take | taken from an output at the application's script that decodes as a request of this registry |
| Skipped holder | output reference, reason | reason is one of: held at a key address, held elsewhere than the application's script, a request of another registry, does not decode |
| Batch | ordered requests, left count, skipped holders | the requests are distinct by output reference and by key; the order is by the folder's take, largest first, ties by output reference |
| Fold receipt | folded requests with key and kind, skipped holders with reasons, left count, the transaction | every discovered request is folded, skipped or counted as left |
| Measurement receipt | scripts (state and request script hashes, reference outputs), network and protocol parameters (their digest and the fields that bound a batch), workload (registry size before, request shapes, payload sizes, kinds), per kind the largest accepted batch with memory, steps, bytes and fee in total and per request, and for the first refused size the limit that failed | every figure is read from the built transaction or the node's answer; the workload and parameters are part of the claim |

## State rules

- A key appears at most once in a batch; a request appears at most once.
- The folder's take of a registration is its held ADA above the deposit its holding must keep; of a termination, its whole
  ADA.
- A discovered set is never silently shorter than the chain: a provider failure while finding requests is unavailable.
- A measured limit is valid only for the workload and parameters the receipt names.
