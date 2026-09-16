# #156 — tasks

One slice, `T-S1 registry-mode-model`. Tasks are checked by the ticket owner
after the audited candidate is accepted, never by the commit owner.

## T-S1 — registry-mode model, both instances, generated surfaces

Definitions first, so the model can be reasoned about; the open application
proved before naming.

- [ ] T156-01 — `State`, `Leaf` and the leaf codec (D1, C1, C2, C3); `Value`,
      `incarnation`, `assetScope`, `reuseIdentity`, `consumerPin` removed.
- [ ] T156-02 — the seven edges, their from→to transitions and their token
      deltas (D2); no free-form `update`.
- [ ] T156-03 — the eight-field configuration (D5, R7) and admission by approval
      under the pinned application policy; the read needs none (D4).
- [ ] T156-04 — `Read` verified against the intermediate root at its position,
      leaf unchanged; `Read Active` and `Read Absent` refused (D3, R5).
- [ ] T156-05 — the fold: atomicity, zero-request refusal, the summed-delta mint
      check, and every refused combination with its own reason (D6).
- [ ] T156-06 — token custody and routing, including the absent token's value on
      consumption (D7, D-ADA).
- [ ] T156-07 — the registry promises P1, L1, S1, S2, S3, O1, T1 proved
      sorry-free at their bound identities (I-P1 … I-T1).
- [ ] T156-08 — the four witness laws W1–W4 proved sorry-free (I-W1 … I-W4).
- [ ] T156-09 — edge inversions, one per edge, exposing guards and effects.
- [ ] T156-10 — the open application as the smallest instance; every promise
      instantiated at it (OA1). Proved before naming.
- [ ] T156-11 — naming as an instance: record UTxO holds the active token;
      `maintain` and `recover` leave the root equal; retirement completion is
      `updateTerminal`; approval policy per NM4; `deleteActive` never certified
      (NM1, NM2, NM4).
- [ ] T156-12 — the existing naming statements and recovery rows re-stated with
      meaning and identities preserved; `LIFECYCLE_IDS` set equality holds
      (NM3, NM5).
- [ ] T156-13 — corpus generators emit rows from the new model, preserving the
      row-id prefixes and section structure `tools/check_model.py` binds.
- [ ] T156-14 — theorem manifests and theorem-debt files regenerated; compiled
      axiom report clean, no `sorryAx`.
- [ ] T156-15 — `docs/theorems.md` and its stamped `docs/theorems.speech.json`
      correspond to the accepted model revision.
- [ ] T156-16 — the four #154 mutants each break their named law, each with a
      positive control, none classified from a compile failure (M1–M4).

## Gate-held, not a task

`nix develop --quiet -c just model` exit 0 and `nix develop --quiet -c just ci`
exit 0 are the gate's criterion, not checkboxes. The `just ci` criterion is
pending Q-001.
