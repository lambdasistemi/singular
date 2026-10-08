# Tasks

Tasks close only when source-bound evidence exists. Story, model binding,
requirements and limits are in spec.md; execution order and ownership in plan.md.

- [x] T001 Verify base, constitution/Lean binding and actual baseline; record failures.
  Base `1015f3a3` and Lean tree `16ee2d4a` verified; docs-check failed on the missing
  speech companion. This records a baseline failure, not a passing full gate.
- [x] T002 Reproduce current directory requirement and add meaningful resolver/identity controls.
  RED commit `81f8964e` executed 11 cases with 6 missing-behavior failures. The
  subsequent focused suite executed 121 cases with 0 failures, including parser and pure
  identity-partition controls. Connected behavior remains T007/T008 below.
- [x] T003 Implement managed state resolution and optional parser arguments across commands.
  Core implementation `f2750390`, with create-path repair `c201af6a`; the latest
  full local suite passed 1,100 examples with 0 failures and 11 pending
  (`green-cage-selection.log`, SHA-256 `1724276d49160fae9df0106999ff567378813beac47906da0ba20c0e3db53872`).
  Final consumer integration, gates and review remain below.
- [ ] T004 Bind create state after seed selection without weakening recovery or concurrency.
- [ ] T005 Preserve inspection/preview behavior and journal reconciliation under managed paths.
- [ ] T006 Update help, examples and production demo/recovery consumers to default managed state.
- [x] T007 Execute isolated fresh Bob inspect/book/fold/readback and creator-access negative control.
  Devnet journey r4 at `f4ccd575`, CLI build `3n6ffvxc`, executed the default-state
  leg without a directory argument: booking with Bob's key, folding with its
  relocated copy, linked readback and creator-access negative control.
  Retained log SHA-256 `4bc57e9230e0fe7a4d3c1ee6e7c900ab96ba6f40c019c56c70926a0c34883edd`.
  The separately identified body-tamper evidence repair is tracked under T009;
  this completed Bob leg does not certify the remaining consumer work or merge.
- [ ] T008 Execute managed-path interruption recovery and identity/lock separation controls.
- [ ] T009 Run focused and required gates; bind receipts, raw exits and candidate hashes.
- [ ] T010 Freeze candidate, obtain GLM independent review and resolve findings.
- [ ] T011 Integrate current main, pass exact-head hosted checks, merge and close #485 on full evidence.
