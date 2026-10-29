# Functions for creating registries on shared script publications

Issue 745. New and changed signatures only, as proposals the commit owner may rename to the Lean vocabulary before the
slice that creates them. Records are in [the data model](data-model.md).

| Function | Arguments | Result | Constraints and effects |
| --- | --- | --- | --- |
| classify a reference candidate | the expected script, the output the provider returned for its hash | live, spent, missing or wrong script, with the hash found | pure; the hash is computed from the carried script |
| plan the references of a creation | the session, the payer, the scripts the creation runs | each script's reference outcome and the publication of what is not live | reads only; submits nothing |
| render the reference outcomes | the outcomes | the receipt's `scripts` field | pure |
| total a leg | the measured transactions | fees, locked ADA, reference script bytes, transaction count | pure; fees and locked ADA are separate |
| read a transaction's measurement | a submitted transaction as the chain holds it | a measured transaction | one provider read per transaction |
