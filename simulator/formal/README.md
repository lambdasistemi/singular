# simulator/formal — frozen archived reference

This directory is a frozen archived reference, not active generated
source. It pins the pre-sixth-field-hook model, scenarios and theorem
debt exactly as they were when the simulator last shared them, and it
must not be edited to track canonical Lean.

- It is never built: no lakefile lists it, no derivation compiles it,
  and no check executes its scenario list.
- It is pinned, not synced: `../identity.json` records the sha256 of
  every file here, and `simulator/build.mjs --check` fails if any
  byte moves.
- It is consumed only as data: `gate.mjs` reads
  `formal/theorem-debt.json` for theorem reporting (names and debt,
  never scenario replay).
- Canonical Lean (`lean/`) plus the simulator mirrors
  (`core.mjs`, `actions.mjs`, `naming.mjs`, `lifecycle.mjs`) govern
  behavior. Where this frozen copy disagrees with canonical Lean
  (the sixth-field hook — no `consumerPin`/`consumerWithdraw` — and
  the empty-fold/nonempty-fold guards), canonical Lean wins and this
  copy stays as it was — its age is the point, not a defect to repair.
