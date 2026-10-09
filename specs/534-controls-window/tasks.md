# Refusal controls window: tasks

Story, requirements, the window choice and its measured cost are in spec.md.

## Slice: widen the controls registry window

- [x] widen-controls-registry-window: one definition of the throwaway registry
  windows (120 000 and 15 000 milliseconds) used by every create and preview call
  and by the readback.
- [x] window-red-green-under-load: the slowed-client run of the check script is
  `partial` on the base and `success` after the change, receipts naming the
  commit and tree.
- [x] controls-job-passes-locally: `nix run --quiet .#demo1-cli-controls` passes
  on the final head with the base's clause counts.
- [x] local-gate-green: format check, lint, the conformance unit suite and
  `just ci` pass on the final head.
