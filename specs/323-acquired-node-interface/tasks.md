# #323 tasks

The ticket owner stamps tasks at acceptance.

- [x] T323-01 (S1) Read interface, view and chain point (D1–D3, F1–F3) in `Singular.Registry.Provider`; signed-transaction write capability (D4, F6) (R1, R3; I2, I3, I5, I8).
- [x] T323-02 (S1) Node adapter over `withAcquired` and deterministic in-memory adapter (F4, F5) (R1, R6; I2, I3, I8).
- [x] T323-03 (S1) Every builder consumes a view; compile-forced consumers acquire one view per operation (F7) (R2, R7; I1, I7).
- [x] T323-04 (S1) Interleaving and P1/P2 race spec on the in-memory adapter, reached control included (R6; I4).
- [ ] T323-05 (S2) CLI commands on injected capabilities; `NodeMode`/`NodeSession` confined to composition; writes journal the view point (R4, R5, R8; I3).
- [ ] T323-06 (S2) CI source check over `offchain/cli` and `offchain/lib` with explicit allowlist and failing control (R4; I6).
- [ ] T323-07 (S2) DevNet CLI journey green through the node adapter; `docs/` backend configuration page (R5, R8, R9; I7).
