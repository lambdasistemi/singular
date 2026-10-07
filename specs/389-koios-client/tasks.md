# Live Koios client: remaining delivery tasks

Base: main `32bba1adc232fb3da5e84ea52e51ab95f670e8f1` (2026-10-07).
Execute serially, as requested by the operator. The transport and provider
composition are already merged; this list completes the existing acceptance
story in [spec.md](spec.md), without adding interface types or recovery work.

The behavioral authority is constitution 1.13.0 and the Lean model at this base.
These tasks preserve the model's transitions; they expose evidence from the
existing provider. Public preprod operations are read-only. Successful local
previews do not substitute for the required public smoke.

## Public commands and their evidence (US1)

- [x] T001 [US1] Include the acquired session's evidence in create-preview receipts in both public-address and local-key modes in `offchain/cli/src/Singular/CLI/Create.hs`.
- [ ] T002 [US1] Extend the existing public and local-key preview checks in `tools/demo1_cli_journey.sh` to require Unbound sessions and nonempty Unverified facts.
- [ ] T003 [US1] Run current-main public inspect and all four previews; record commands, URL, schema revision, per-call timings, receipts and insert phases in `specs/389-koios-client/live-smoke.md`. Preserve refusals as refusals; update/terminate require a real existing holding.

## Bounded failures and shared decoding (US2)

- [x] T004 [US2] Verify the existing fake-server and recorded-decoder checks in `offchain/test/Singular/Provider/` on the final candidate, retaining bounded retry, pagination and redaction controls.

## Delivery

- [x] T005 Reconcile `specs/389-koios-client/plan.md` with the final remaining scope and evidence; regenerate its required documentation companions if changed.
- [ ] T006 Record the exact model mapping, live smoke and limits in the PR using `.github/pull_request_template.md`; run `just ci` and the affected packaged journey on the final candidate.
- [ ] T007 Merge after required hosted checks pass and close #389 only when its public-smoke acceptance is satisfied; record completion in the runtime `STATUS.md`.

T001 evidence: the public create preview succeeds with its actual Unbound
scope and Unverified fact; the same receipt predicate fails on main before
the repair. T003 is partially recorded in [live-smoke.md](live-smoke.md),
with the unsuccessful forms explicitly unfulfilled.

Dependencies: T001 → T002 → T003 → T004 → T005 → T006 → T007.
No parallel worker execution. A missing public holding blocks successful
update/terminate smoke, not the independent receipt repair; do not create one
by submitting a transaction under this ticket's read-only authority.
