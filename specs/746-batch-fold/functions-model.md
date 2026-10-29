# Functions for folding a batch of registry requests

Issue 746. New and changed signatures only, as proposals the commit owner may rename to the Lean vocabulary before the
slice that creates them. Records are in [the data model](data-model.md).

| Function | Arguments | Result | Constraints and effects |
| --- | --- | --- | --- |
| a session query of a policy's holdings | the session, a policy | its outputs, or a read failure | one provider query path; complete or failed |
| discover pending requests | the session, the application record, the registry identity, the registry's replayed keys | discovered requests and skipped holders, or a refusal | one policy query; no submission; a read failure is a refusal |
| order by the folder's take | discovered requests | the same requests, ordered | pure; deterministic |
| fold the largest batch that builds | the session, the state script, the application record, the registry identity, the ordered requests, the payer, an optional limit | a transaction, the folded and left requests, or a refusal | builds with the existing builder; the probes it makes are counted; only a capacity refusal counts as not fitting; the boundary is shown by a fitting prefix and a refused next one |
| fold the named batch | the session, the state script, the application record, the registry identity, the named requests, the payer | a transaction or a refusal | refuses another registry's request, a repeated request, a duplicate key, a batch that cannot be built |
| measure the largest accepted batch | the packaged executables, a development network, a workload | a measurement receipt | submits to the network; reads every figure from the built transaction and the node's answer |
| render the fold receipt | the folded, skipped and left sets | human text or JSON | pure |
