# NOTE-038 admission histories + orphan discriminator — result receipt

Seat `%993`, worktree `/code/singular-e18-blaster` (`feat/blaster-compiled-invariants`).
Scope: `blaster/abstract/` only (4 new files, 2 doc corrections, recipe wiring).
Stop-uncommitted: everything left uncommitted for consolidated owner/root review.
No merge/push/release, no model/schema/register/C5/migration/ledger work. `%994` independent.

## Authorities and identities (verified this turn)
- Root review receipt: `/tmp/projects/singular/milestone-1/handoffs/a006-root-general-correspondence-review.json`,
  SHA256 `14f99046e82e12e70911083562762455a7ff0ed09178b67c1f42759a2125096f` (verified byte-identical).
- Accepted model authority `13231f58833b8feb57f4b0f9b1117bfcfba0c07d`: `lean/` tree clean
  (`git status --porcelain -- lean/` empty; recipe provenances it every run). Not altered.
- Proved general layer retained byte-identical, NOT rerun/rewritten: `Corr.lean` 765 lines,
  SHA256 `e677e457fd3392a5d9b81bfb8703069e1411a5ac62899d9d1a5bc7e5bb5daf7f`
  (matches root receipt frozen copy); both directions, frame, mutant, six bridges stand as
  recorded in `handoffs/note035-correspondence-result.md`. Root's `/tmp/singular-root-a006-corr-KeijoX`
  package was NOT rebuilt here; root's first missing-dependency failure (exit 1, lakefile omitted
  roots) is retained from their receipt as setup-only/no-credit, distinct from their corrected
  nine-job `RootCorr` (exit 0) and nine-job `RootWitness` (exit 0) builds.
- New files: `Histories.lean` 394 lines (`22a943717f24cfdbf84cdf68af93c81d84f8f729ec2e8570ce14f70347dd5cc5`),
  `OrphanControl.lean` 170 lines (`c61da8d1b9937208dc316eb041896f7f2cca7ae2a048709a8f4297a03afeb7b3`),
  `OrphanMutant.lean` 55 lines (`45618520f66e296b21445e5288a142634a6b77c6a6caa7172c0400a54ff46ea2`),
  `OrphanMutantGate.lean` 28 lines (`df8dc94fca33352977abdd22dd94be47344a86a7b05f4ec16f83d9bad83fd028`).
- Doc corrections: `AdmitTrace.lean` (`c798722a41cff88fd53e038cbb972f86d009cd0facb93ebc8cee47bfb909b35c`),
  `RejectedFoldGate.lean` (commentary only; all fixtures, executions, and
  `R-custody-unassociated` byte-preserved in behavior).

## Three unreachability dispositions (claims removed, evidence preserved)
Root `RootWitness` (unchanged `reachable_inv`) proves `not Reachable` for each exact state:
each has representative supply 1 for key 42 with no `Active` entry; every accepted reachable
state is `WellFormed`. The refutations are retained as diagnostic evidence (root receipt
`findings.notReachable`, `impossibilityReason`).
1. `RejectedFoldGate.sZNBase`: the insert-then-delete incarnation/scope legitimacy commentary is
   REMOVED (was the only admitted-history claim). Fixture, zero-net computation, and refusal
   shape preserved as finite diagnostic. Claimed positive replaced by `Histories.reachZN`/`fullZN`.
2. `RejectedFoldGate.sCBase`: `used`-patching noted, no admitted-history credit claimed; finite
   funded-custody execution preserved as diagnostic. NOTE-036 funded positive replaced by
   `Histories.reachCU`/`fullCU` (release-admitted held update 41, funding-covered custody).
3. `AdmitTrace.sRel`: module doc corrected — the four legs stay as action-kind evidence
   (outsider/create/release accept the shapes, incl. held-carrying Case-T), but the seeded
   `sRel` legs constitute no admitted history. `reachable_inv` not weakened, model untouched,
   prestates not patched into validity.
The older `R-custody-unassociated` (selected held binding replaced) is retained untouched and
is NOT substituted for the new discriminator below.

## Admitted histories + candidate commutation (all green, axiom-clean)
Local batch scalars mirror the frozen gate context (`tipH 500`, `[5000, 6000)` + `2000`/`1000`,
all-true evidence); every timing/funding outcome below re-verifies them. No patched `used`,
no inserted application, no seeded registry, no fabricated representative. Funding/custody
observe ONLY history-admitted request ids.
- Mixed (`reachMX`, no axioms; `fullMX` via `dirA_top`): `initial` → createInsert 31 →
  outsider 32; candidate `[31-processed, 32-rejected]` gives logical `[+1 rep42]`, removed
  `[31, 32]`; conservation `1600 == 500 + 1100` (funding 600+1000, refund 500, change 1100).
- Zero-net (`reachZN`, no axioms; `fullZN` via `dirA_top`): `initial` → createInsert 21 →
  fold to application 101 → release 101 for delete 22 → createInsert 23 (scope `[1]` for the
  post-delete incarnation); candidate `[22-delete, 23-insert]` gives `[-1, +1]` rep42 with
  `netSumsZero true`, removed `[22, 23]`; conservation `1200 == 0 + 1200` (no refund legs).
- Retirement custody (`reachCU`, no axioms; `fullCU` via `dirA_top`): `initial` → createInsert 40 →
  fold to application 106 → release 106 for held update 41; candidate `[41-rejected]` with
  custody `{41, rep0, 6100}` unspent and funding 1000 covers it (NOTE-036 funded positive);
  removed `[41]`, refund `{85, 500}`, custody `[41]` preserved; conservation `1000 == 500 + 500`.
- Full-relation exhibits inherit `dirA_top` footprints (`propext`, `Classical.choice`,
  `Quot.sound`; disclosed, consistent with Corr). Reachability chains and step equations
  (`rfl`) depend on no axioms. Generic `Delete` stays generic; no naming semantics claimed.

## Exact funded/orphan pair + mutation discrimination
Selected rejected 8 (outsider-admitted from `initial`: `reachO8`, no axioms) plus distinct
unselected unspent custody 99 (`{99, rep99-key99, 6200}`, `custodySpent []`); funding differs
by ONLY fund99's presence.
- Positive (funding `[fund8o, fund99]`): accepts — removed `[8]`, logical `[]`, refund
  `{77, 500}`; relates (`fullOP` via `dirA_top`).
- Negative (funding `[fund8o]`): returns EXACTLY `custody-unassociated` (`#guard_msgs`-asserted);
  `noRelOrphanNeg` proves `¬FullCorr` for ANY claimed outputs (no axioms; association failure
  is output-independent).
- Premise necessity (equivalent negative, all by computation): `orphanOtherHolds` shows every
  non-association `FullCorr` component holds on the orphan-negative state (contract, nonempty,
  count, three nodups, used-membership, unspent-custody) — association is the sole discriminator.
- Guard necessity (behavioral mutation): `OrphanMutant.lean` redefines only the inner fold with
  the association guard erased (all else identical); the exact negative ACCEPTS there, so
  `OrphanMutantGate.lean` asserting `custody-unassociated` observes `UNEXPECTED-OK` and fails
  (red). No caller Boolean, grep, missing import, or unrelated rejection involved.

## Complete commands, raw outputs, true exits
- `./run-candidate.sh` → exit 0, 9 jobs (`RejectedFoldGate` + `Corr` + `AdmitTrace` +
  `Histories` + `OrphanControl` green; includes corrected docs, new histories, orphan control).
- `./run-candidate.sh --orphan-mutant` → exit 0 with `mutant-module=0 positive=0 kill-gate=1`
  and `UNEXPECTED-OK` observed (guard-erasure kill on the custody-unassociated assertion).
- `./run-candidate.sh --mutant` → exit 0 unchanged (retention kill on `some [8, 7]`; route
  preserved byte-for-behavior through the recipe `elif` repair).
- Root package commands were NOT re-executed here (see retained receipt above).

## Remaining debt + explicit non-agreement (NOTE-037 kept)
Actual Aiken bounds, both implementation layers, KERI instantiation, authentic producer
custody, and separate retirement completion remain open. Preserving unspent custody in A006
(including the orphan discriminator) is NOT agreement with the current producer and does not
close the retirement-completion bridge (NOTE-037 dependency recorded in the NOTE-035 handoff);
Grok/E17 owns that repair under NOTE-092. Quantified/whole-proof obligations stay open;
candidate-internal and unadopted throughout.
