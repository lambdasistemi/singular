# Data model

Fields, relationships, validation and state invariants of the new or changed data. Signatures are in the [functions model](functions-model.md). Output ceiling: 6 KB.

## Selection data (registry library)

| name | fields | validation |
|---|---|---|
| pending request | output reference; the decoded request or the reason it does not decode; the application step's verdict, asked through the application value (the settlement inputs, or `application-datum-unreadable`, or `application-required` with the application's executable named); the assets the output holds under the registry's application policy; the request's deadline (its submission time plus the registry's processing time) | every output at the request address is one pending request |
| live facts | per key: the leaf (unknown, absent, active or terminal; the two admitted edges leave no absent leaf, but the model names it `not-booked` for a termination); per key: whether a live output holds the key's one active token | read from the registry state and the live outputs before the decision; the state they describe is the one the fold spends |
| exclusion | a reason name; its source, `model-refusal` or `selection-policy`; a detail text | a reason belongs to exactly one source (see below) |
| selected request | output reference; the request; its edge kind; its deadline | passed all seven checks |
| selection | the selected requests in ledger input order; the excluded requests, each with its exclusion, in ledger input order; the capacity bound used | every pending request is in exactly one of the two lists; the selected keys are pairwise distinct; the selected count is at most the bound |
| capacity bound | the number of requests (1 in pull request 1, 9 in pull request 2); a provenance text | provenance of 1: the journal binds one transition until pull request 2; provenance of 9 names the operator estimate, preprod's execution budget of 14 million memory units, trie-proof verification as the binding limit, and that it is unmeasured, owner #530 |

Reason names by source:

| source | names |
|---|---|
| model-refusal | `edge-inadmissible`, `no-approval`, `approval-mismatch`, `key-exists`, `token-missing`, `key-unknown`, `not-booked`, `terminal-immutable` |
| selection-policy | `undecodable`, `window-closed`, `application-datum-unreadable`, `application-required`, `key-in-batch`, `capacity` |

State invariants: the verdict of a request with the same live facts, clock, bound and request is the same whatever other requests are pending on other keys; a selected batch is a batch the model's `foldBatch` accepts from the same state.

## Journal data (command line, pull request 2)

| name | fields | validation |
|---|---|---|
| fold transition | the request's output reference; key; edge; the expected leaf after; the root before; the root after | the first root before is the state's root; each root after is the next root before; the last root after is the new state's root |
| journal line (prepared, for a fold) | the existing line fields; an ordered list of fold transitions, non-empty | a line holding only the earlier scalar key, edge and root fields reads as the list of the one transition they describe |
| expectation (Session) | a second constructor carrying the list of fold transitions, beside the one-key constructor | non-empty for a fold |

At a fold's rolled-back line the restored public root is the first transition's root before.

## Receipt data (command line)

| name | fields |
|---|---|
| settled request | request; key; edge; owner; settlement; the request's own deadline. Settlement is the delivered output with the application datum it carries, or the released holding with the deposit paid back |
| excluded request | request; reason; source |
| fold receipt | settled requests in order; excluded requests in order; the transaction id; the folder; the root before and after; the validity bound and the post-build decision (they follow the earliest deadline among the settled requests); the capacity bound with its provenance |

The earlier single-request fields (`request`, `key`, `edge`, `liveOutput`, `envelope`, `released`, `deposit`) describe the one settled request of a fold of one. In pull request 1 they stay at the top level of the receipt, unchanged, and the lists (`settled`, `excluded`, the capacity bound with its provenance) are added beside them, so that no existing reader changes while main stays green; the lists repeat the settled request in the shape of the table above. In pull request 2 the readers move to the lists and the top-level duplicates are removed in the same change. Readers of the receipt are listed in the [plan](plan.md).

## Pull request 3 at `e7b55ac9`

| name | fields | validation |
|---|---|---|
| settled entry | request; key; edge; owner; kind (insertion or termination); the datum an insertion delivers or the holding a termination releases; the delivery read back; the request's own deadline | one per settled request, in ledger input order |
| journal line scalars (a fold) | key, expectation and edge of the first transition; root before of the first; root after of the last | they agree with the list; a line whose scalars disagree with its list is not observed |

A fold's prepared line always carries the list, one transition for a fold of one. Roots between transitions come from walking the trie once per prefix of the selection.
