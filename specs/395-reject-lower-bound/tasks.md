# Reject lower bound: tasks

Read the [plan](plan.md) for the module rows. One commit per task, in order.

## Slice: reject at the tip

As a folder, I want the reject accepted by the node, and the rule held by a test.

- [ ] Reject lower bound test: on a view whose tip lags the host clock, the built
  reject's lower bound is at or before the tip slot. Committed failing on
  `22637d46`.
- [ ] Reject lower bound fix: `rejectValidity` takes the lower bound from the
  view's tip slot; the test passes; the upper bound stays after the lower bound.

## Slice: builder audit

As a maintainer, I want every builder's validity interval checked against the
same rule.

- [ ] Builder audit page: `builder-audit.md` with one row per builder, file and
  line, and its verdict, with its speech companion.
- [ ] Further violations: fixed here, each with its own test, or filed as a bug
  and linked from the audit page.

## Slice: evidence from CI

As a maintainer, I want CI to see what preprod sees.

- [ ] Release-PR failure verdict: whether job 111713723071 shares this cause,
  with the evidence, recorded in the audit page; a different cause filed.
- [ ] Sparse-block development network: one CI run with an active-slot
  coefficient below one, or a linked ticket when larger than a configuration
  change and one job.
