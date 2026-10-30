# Data for the 1.0 release from its installed artifacts

Issue 747. This page lists the records that change or are added and the rules each keeps. It follows
[the modules model](modules-model.md).

## Records

| Record | Fields | Rule |
| --- | --- | --- |
| Release table row (existing) | state contract hash, the Singular releases that carry it; and per applied state policy: application policy, application script, Singular releases, application releases | a hash lists releases oldest first; an empty list means not released yet; a release appears in a row only if its published on-chain archive was read |
| Serving answer (added) | the registry's observed release pair, one of: served by this release, served by a named earlier release, application release differs and a named application release serves it, unknown contract and no release named | exactly one case per observed registry; named releases come from the table and from nowhere else |
| Journey verdict (existing, extended) | step, chain observation, expected, outcome | every verdict is computed from the network's record of the chain; a verdict never reads a command's receipt as its observation |
| Decision row (added) | measurement, parameters it was taken under, gain, regression, unmeasured limit, source receipt and its hash | every figure is read from its receipt; a row without a source receipt is refused |
| Compatibility row (added) | earlier release, state contract hash, the release that serves registries of that contract (this one, an earlier one, or none) | computed from the release table; a release absent from the table is listed as unknown, never as served |

## State rules

- The table is complete up to the release being cut, or the page states which release it stops at; the compatibility
  page and the neutral reader read the same file.
- Guidance is a function of the table and the observation. The same observation yields the same text in every command.
- No journey step depends on a file left by another wallet; each wallet has directories and a home of its own.
- A write refused for guidance leaves the chain as it was: no transaction is built, signed or sent, shown by the
  network's record before and after, beside a passing control.
- A receipt refresh changes the receipt's recorded parameters and date together, or neither.
