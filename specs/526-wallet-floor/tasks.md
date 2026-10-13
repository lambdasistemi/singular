# A write asks the wallet for what it costs: tasks

Story, requirements and limits are in spec.md; decisions and the gate are in
plan.md; the files this work may touch are in touch-list.md.

## Slice: wallet judged on the measured outlay

- [x] session-opening-applies-no-floor: opening a write session reads the
  provider and applies no wallet threshold.
- [x] wallet-shortfall-judgement: one pure judgement of a wallet's outputs
  against a required amount, with its refusal beside the outlay refusal.
- [x] booking-judges-the-wallet: insert and terminate refuse a wallet under the
  fold reserve before building and under the measured outlay before signing, in
  preview and in write alike.
- [x] empty-wallet-refused-before-building: insert, terminate and update refuse a
  wallet with no ada-only output, or a foreign `--fund-input`, before building, in
  preview and in write alike.
- [x] twenty-ada-two-outputs-goes-through: the story's wallet previews and
  writes.
- [x] underfunded-refusal-names-the-wallet: client-refusal, never
  node-unavailable, with held, required and shortfall equal in preview and write.
- [x] documentation-states-the-rule: the node documentation and the module
  descriptions say the floor is the conformance runner's and the wallet is judged
  on the measured outlay.
- [x] local-gate-green: the narrowed gate in plan.md passes on the final head.
