# Reject lower bound: tasks

Read the [plan](plan.md) for the module rows. One commit per task, in order.

## Slice: reject at the tip

As a folder, I want the reject accepted by the node, and the rule held by a test.

- [x] Reject lower bound test: on a view whose tip lags the host clock, the built
  reject's lower bound is at or before the tip slot. Committed failing on
  `22637d46`.
- [x] Reject lower bound fix: `rejectValidity` takes the lower bound from the
  view's tip slot; the test passes; the upper bound stays after the lower bound.

## Slice: builder audit

As a maintainer, I want every builder's validity interval checked against the
same rule.

- [x] Builder audit page: `builder-audit.md` with one row per builder, file and
  line, and its verdict, with its speech companion.
- [x] Further violations: fixed here, each with its own test, or filed as a bug
  and linked from the audit page.

## Slice: evidence from CI

As a maintainer, I want CI to see what preprod sees.

- [x] Release-PR failure verdict: whether job 111713723071 shares this cause,
  with the evidence, recorded in the audit page; a different cause filed.
- [x] Sparse-block development network:
  [the sparse-block reject check (#403)](https://github.com/lambdasistemi/singular/issues/403)
  tracks the larger repair
  after the attempted job exceeded its 60-minute limit. The sparse job and
  genesis variant are removed here; ledger acceptance remains unverified.
