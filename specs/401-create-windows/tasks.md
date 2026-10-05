# Registry windows at create: tasks

Read the [plan](plan.md) for the module rows. One commit per task, in order.

## Slice: windows at create

As a registry creator, I want to choose both windows and see them.

- [ ] Flag tests: parse refusals for non-positive and non-integer values, and a
  journey assertion that explicit windows are read back and the fold deadline
  follows the processing window. Committed failing.
- [ ] Flags and defaults: `--process-time` and `--retract-time` on `create`,
  defaults 600 000 and 300 000 ms, shown in the receipt and `inspect`.
- [ ] CI journeys use short windows: journeys, controls and the attach take
  choose them explicitly with at least three times measured fold preparation
  beyond the client guard; compute window waits from receipts/inspect, with
  defaults and existing preprod registries unchanged.
- [ ] Documentation: the defaults and that the windows are fixed for the life
  of a registry, with speech and narration updated.
