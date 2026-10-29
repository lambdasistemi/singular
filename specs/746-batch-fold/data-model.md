# Data for folding a batch of registry requests

Issue 746. Records the fold introduces or changes, their fields and their rules. Placement is in
[the modules model](modules-model.md).

## Records

| Record | Fields | Rules |
| --- | --- | --- |
| Policy holdings query | a policy | answers every live output that holds at least one asset of the policy, with its output reference; an incomplete page is a failure, never a shorter answer |
| Discovered request | output reference, request kind (registration or termination), key, approval name, the folder's take | taken from an output at the application's script that decodes as a request of this registry |
| Skipped holder | output reference, reason | reason is one of: held at a key address, a request of another registry, not accepted by the application's decode (an output held at any other script is of this kind), or unfoldable in the observed state (key already registered, termination of a key that is not live, key taken by an earlier request in the order, deposit below the holding minimum, processing window closed) |
| Batch | ordered requests, left count, skipped holders | the requests are distinct by output reference and by key; the order is by the folder's take, largest first, ties by output reference |
| Fold receipt | folded requests with key and kind, skipped holders with reasons, left count, the transaction | every discovered request is folded, skipped or counted as left |
| Measurement receipt | claim fields: scripts (state and request script hashes, reference outputs), the recorded parameter set (source, recording date, hash), the evaluator and its versions, the workload (registry size before, request shapes, datum sizes, kinds), and per kind the kept transactions of the largest accepted batch and of the next size, with evaluated memory, steps, bytes and fee in total and per request; run observations, kept apart: fresh captures, the development node's answers, ids and times | every claim figure is the evaluation of a kept transaction and can be reproduced byte for byte; a fresh capture varies slightly because transaction ids and addresses enter the script context, and is compared only on the largest size and the refusal of the next; the workload and parameters are part of the claim |

## State rules

- A key appears at most once in a batch; a request appears at most once.
- The folder's take of a registration is its held ADA above the deposit its holding must keep; of a termination, its whole
  ADA.
- A discovered set is never silently shorter than the chain: a provider failure while finding requests is unavailable.
- A measured limit is valid only for the workload and parameters the receipt names.
