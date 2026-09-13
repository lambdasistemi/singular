# NOTE-126 — R2 must distinguish the request from naming custody

Read and acknowledge at the next safe boundary. This supplies bounded evidence for the current R2 repair; keep the existing worker order and do not restart a worker or repeat a campaign merely for this note.

Root investigated whether rejected processing could return a retirement representative. The actual naming layout matters: `application.retire` sends the representative to the distinct `retirement_custody_hash`, and that custody validator requires every held non-ADA asset to be burned exactly. A request-shaped output assumed to hold the NFT directly at the generic request script is not evidence of a reachable named-retirement escape.

Root executed the copied current draft state, request and consumer handlers on the same synthetic transaction context per case, plus the actual naming custody handler where applicable. There are five root controls; all five pass, within 24 total executed tests (12 unit, 12 property):

- A nonempty expired Insert is consumed by `Modify([Rejected])` / `Contribute` with the exact consumer invoked, unchanged state root and an input-minus-tip refund. All three handlers accept.
- An Update-shaped request assumed to hold a representative directly at the generic request address can return that NFT with its refund under those three handlers. This is a generic conditional observation, not the actual naming custody layout or a proven naming exploit.
- Removing the consumer withdrawal refuses at the exact state hook predicate.
- With a separate custody input and the actual naming layout of separate request and representative custody, the three generic/consumer handlers accept the refund context, but the actual custody handler refuses the no-burn token return at `held_burned_exactly_once`. All four observe the same transaction context.
- A custody-only exact-burn positive accepts. This controls the preceding refusal; it does not execute the representative mint policy or prove permanent Over.

Receipt and exact source hashes: `/tmp/projects/singular/milestone-1/handoffs/rejected-retirement-custody-root-control.json`. Retained miniature project, source copies and raw outputs: `/tmp/singular-root-rejected-custody-Jdn75Y`. The application custody destination is frozen separately in `handoffs/rejected-custody-root-application.ak`. The initial dependency-staging failure and a read-only-copy setup error are retained without execution credit; successful runs are separately retained. No product file was edited.

These are current draft validator-context checks with balanced ADA/token values, not real ledger submission, actual compiled script-hash binding, an authentic naming history, final producer acceptance or permission to migrate E18. The request/root fixture values are synthetic; do not promote their reachability. The exact final producer tuple and existing full evidence remain required.

Use this distinction in the executable R2 relation: map the real request together with any separate custody/application inputs that establish its abstract held representative; do not infer abstract custody solely from one RequestDatum, and do not infer a naming escape from omission of its required custody purpose. Preserve root NOTE-125's same-request pre/post identity, current per-owner refund floors, consumer permission, mixed/all-rejected effects and no-replay requirements. The independently accepted register repair does not discharge these semantic debts. No new model change, ledger-evidence feature, ghost-only discharge, broad test campaign or new seat is authorized.
