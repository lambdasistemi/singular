# Plan: the builders set the upper bound

Issue 334. Follows [the specification](spec.md).

## Approach

The builders that lack a bound take one from the same time conversion the booking builder uses, with the same horizon
limit, so each new bound is the one a person already gets on a booking. The recovery rule that already exists then applies
to them with no change of its own: a body with an upper bound can be excluded or declared dead once the tip passes it. The
census of builders is part of the work, because a builder reached only by one command is easy to miss.

## Slice

One slice and one pull request: the three builders, the recovery and creation controls extended to an update and a booking,
the regenerated receipts and goldens, and the pages.

| Part | Change |
| --- | --- |
| Builders | the update and the termination booking in the holding module; the creation path; any builder the census names |
| Recovery controls | the recovery partitions that show an unresolved booking or update now show it excluded; the dead-bundle case shows the next write proceeding |
| Receipts and goldens | creation cost receipts, transaction goldens and any retained measurement that includes these bodies |
| Pages | the residuals and the way-out limits removed |

## Consumers the gate names at intake

The command-line recovery partitions, the staged-bundle and external-signing journeys, the creation cost check, the golden
transaction tests of the open datum package and the off-chain suite, the bundle deadline check of the signing command, and the
pages that describe recovery and creation.

## Model position

Below, conditional on the search named in the specification.
