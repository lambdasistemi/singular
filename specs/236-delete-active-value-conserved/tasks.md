# Tasks

## S1 — deleteActive conserves value and agrees

- [ ] T1 The builder proof fails on the base because the active mint is `-1` and no input carries the asset.
- [ ] T2 The builder spends that input. The same proof passes. Validators are unchanged.
- [ ] T3 A devnet sequence receipt shows `deleteActive` accepted and agreeing with the model. `witnessTerminal` stays unsupported.
- [ ] T4 `conformance/BOOK.md` is regenerated from that run. The unsupported `deleteActive` row is gone.
