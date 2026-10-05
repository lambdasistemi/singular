# Registry windows at create: tasks

Read the [plan](plan.md) for the module rows. One commit per task, in order.

## Slice: windows at create

As a registry creator, I want to choose both windows and see them.

- [ ] Flag tests: parse refusals for non-positive and non-integer values, and a
  journey assertion that explicit windows are read back and the fold deadline
  follows the processing window. Committed failing.
- [ ] Flags and defaults: `--process-time` and `--retract-time` on `create`,
  defaults 600 000 and 300 000 ms, shown in the receipt and `inspect`.
- [ ] Callers keep their timing: journeys, controls and tests that relied on
  the old defaults pass them explicitly.
- [ ] Documentation: the defaults and that the windows are fixed for the life
  of a registry, with speech and narration updated.
