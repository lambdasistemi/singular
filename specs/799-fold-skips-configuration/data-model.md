# Data: the application description gains one question

Issue 799. Follows [the modules model](modules-model.md).

## Application description

| Field | Meaning | Validation |
| --- | --- | --- |
| is-configuration | for an output, whether the application recognises it as the configuration of a registry it holds | pure and total; no chain access; true for the configuration of any registry the application holds, not only the registry being folded |

## Invariants

- configuration-and-request-are-disjoint: no output is both named as configuration and decoded as a request.
- an output at a key address is never configuration: discovery's key-address check comes first, so such a holder keeps
  its skip.
- the skipped list and the pending list never contain an output named as configuration.

## Unchanged

The reasons a holder is skipped, the receipt fields (`folded`, `skipped`, `left`, `reconciled`) and the request and
pending records.
