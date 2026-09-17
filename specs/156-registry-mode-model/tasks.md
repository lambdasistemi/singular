# #156 — tasks

Two sequential slices in one PR (ruling A-001). Tasks are checked by the ticket
owner after each slice's audited candidate is accepted, never by an author.

## Slice A — `registry-mode-model` (author `glm`, auditor Opus `lean-auditor`)

Definitions first, so the model can be reasoned about; the open application
proved before naming.

- [ ] T156-01 — `State`, `Leaf` and the leaf codec (D1, C1, C2, C3).
- [ ] T156-02 — `Value`, `incarnation`, `assetScope`, `reuseIdentity`,
      `consumerPin` removed, proved absent from the **elaborated environment**,
      not by a source grep (D1b).
- [ ] T156-03 — the seven edges, their from→to transitions and their token
      deltas (D2); no free-form `update`.
- [ ] T156-04 — the eight-field configuration (D5) and admission by approval
      under the pinned application policy; the read needs none (D4).
- [ ] T156-05 — `Read` verified against the intermediate root at its position,
      leaf unchanged; `Read Active` and `Read Absent` refused (D3).
- [ ] T156-06 — the fold: atomicity, zero-request refusal, the summed-delta mint
      check, and every refused combination with its own distinct reason (D6).
- [ ] T156-07 — token custody and routing, including the absent token's value on
      consumption (D7, D-ADA).
- [ ] T156-08 — P1, L1, S1, S2, S3, O1, T1 proved sorry-free at their bound
      identities (I-P1 … I-T1).
- [ ] T156-09 — the four witness laws W1–W4 proved sorry-free (I-W1 … I-W4).
- [ ] T156-10 — edge inversions, one per edge, exposing guards and effects.
- [ ] T156-11 — the open application as the smallest instance; every promise
      instantiated at it (OA1). Proved before naming.
- [ ] T156-12 — naming as an instance: record UTxO holds the active token;
      `maintain` and `recover` leave the root equal; retirement completion is
      `updateTerminal`; approval policy per NM4; `deleteActive` never certified
      (NM1, NM2, NM4).
- [ ] T156-13 — the existing naming statements and recovery rows re-stated with
      meaning preserved (NM3, NM5).
- [ ] T156-14 — corpus generators emit rows from the new model; corpora and
      manifests regenerate byte-for-byte.
- [ ] T156-15 — `tools/check_model.py` opened to the new identities with its
      discipline intact.
- [ ] T156-16 — compiled axiom report clean, no `sorryAx`, every statements
      module gated.
- [ ] T156-17 — `docs/theorems.md`, `docs/model-ledger.md` and `docs/mutants.md`
      rewritten against the new model, speech restamped.
- [ ] T156-18 — the four #154 mutants each break their named law, each with a
      positive control, each classified statement-kill or row-kill, none from a
      compile failure (M1–M4).
- [ ] T156-19 — `docs/theorems.md` equals its manifest exactly, with the total
      derived rather than asserted (X1). The base tree ships 44 manifest
      declarations against 41 page rows.
- [ ] T156-20 — `tools/check_model.py` gains the page-against-manifest
      cross-check, seen to fail before it is trusted (X2), so the gap that
      survived v0.6.1 cannot recur once this ticket's gate is gone.
- [ ] T156-21 — the refused reads `Read Active` and `Read Absent` are in the
      refusal set with rows and controls, and R3 is stated as the complement of
      the R2 table rather than an enumeration (A-002 SPEC 1, 2).
- [ ] T156-22 — the absent token's custody datum carries the `insertAbsent`
      refund address; both exits pay there; the custody census holds (R-ADA,
      D-CUST). The control uses an inserter and a consumer that differ.
- [ ] T156-23 — naming's approval policy implements R-NM4 for all six edges,
      with the four refusal controls (A-002 SPEC 5).
- [ ] T156-24 — the retirement map for all 44 base generic declarations:
      carried, renamed to what, or retired why (R12).
- [ ] T156-25 — every statement quantifies over `Singular.Reachable` states,
      not arbitrary `State` values (A-002 SPEC 3).
- [ ] T156-26 — the `Singular.Oracle.*` observation surface, defined in terms of
      the real model rather than as an independent table, so the frozen oracle
      (gate leg A10) can evaluate the model at the ticket owner's inputs.

## Slice B — `#163 simulator` (author `muse`, auditor Opus `lean-simulations-auditor`)

Starts only after slice A's audit passes and its interface is frozen.

- [ ] T163-01 — the generic profile exposes the seven edges and the read, with
      the token movement shown per edge (B1).
- [ ] T163-02 — every illegal combination refused **by name**, matching the
      model's reason (B2).
- [ ] T163-03 — full replay agreement against the new corpora, with an
      executed/discovered denominator (B3).
- [ ] T163-04 — the naming profile: the Over witness minted by a folded read and
      freely burned (B4).
- [ ] T163-05 — `docs/simulation.md` describes the journeys and states the
      finite-model limits.
- [ ] T163-06 — `docs/LEAN-CLARITY.md` records what the new formal artifacts did
      and did not communicate to the transcriber (B7).
- [ ] T163-07 — the counts on the front page and in `docs/design.md` equal what
      actually replays (B5).
- [ ] T163-08 — browser checks replay against the new model.
- [ ] T163-09 — every changed page restamped; `just check-presentation` passes
      (B6).

## Gate-held, not a task

`nix develop --quiet -c just model` and `nix develop --quiet -c just ci` exit 0
are the gates' criteria, not checkboxes. Only the ticket gate, on the combined
tree, may claim the repository green — slice A is green on its own gate and red
on the simulator by construction, and is never pushed in that state.
