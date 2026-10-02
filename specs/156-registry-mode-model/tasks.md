# #156 — tasks

Two sequential slices in one PR (ruling operator answer (A-001)). Tasks are checked by the ticket
owner after each slice's audited candidate is accepted, never by an author.

## Slice A — `registry-mode-model` (author `glm`, auditor Opus `lean-auditor`)

Definitions first, so the model can be reasoned about; the open application
proved before naming.

- [ ] state-leaf-leaf-codec — `State`, `Leaf` and the leaf codec (singular-leaf-singular-state, singular-encodestate-singular-decodestate, any-byte-string-that-not-one-three, leaf-byte-string-from-naming-era-decoded).
- [ ] value-incarnation-assetscope-reuseidentity-consumerpin-removed-proved — `Value`, `incarnation`, `assetScope`, `reuseIdentity`,
      `consumerPin` removed, proved absent from the **elaborated environment**,
      not by a source grep (absence-old-vocabulary).
- [ ] seven-edges-their-from-transitions-their-token — the seven edges, their from→to transitions and their token
      deltas (singular-edge-singular-delta); no free-form `update`.
- [ ] eight-field-configuration-admission-by-approval-under — the eight-field configuration (state-datum-its-fields-enumerated-exactly-eight) and admission by approval
      under the pinned application policy; the read needs none (singular-admits-config-applicationpolicy).
- [ ] read-verified-against-intermediate-root-at-its — `Read` verified against the intermediate root at its position,
      leaf unchanged; `Read Active` and `Read Absent` refused (singular-read-root-threading).
- [ ] fold-atomicity-zero-request-refusal-summed-delta — the fold: atomicity, zero-request refusal, the summed-delta mint
      check, and every refused combination with its own distinct reason (singular-step-refusal-reasons).
- [ ] token-custody-routing-including-absent-token-s — token custody and routing, including the absent token's value on
      consumption (fold-minting-absent-token-it-completes-absent, retired-custody-value-proposal).
- [ ] proved-sorry-free-at-their-bound-identities — tree-change-requires-approval, request-spent-once-in-order, terminal-attestation-sound, terminal-attestation-permanent, supply-matches-leaf-state, booking-requires-untaken-key, terminal-key-cannot-change proved sorry-free at their bound
      identities (I-tree-change-requires-approval … I-terminal-key-cannot-change).
- [ ] four-witness-laws-proved-sorry-free-i — the four witness laws active-witness-unique–witness-kinds-exclude proved sorry-free (I-active-witness-unique … I-witness-kinds-exclude).
- [ ] edge-inversions-one-per-edge-exposing-guards — edge inversions, one per edge, exposing guards and effects.
- [ ] open-application-as-smallest-instance-promise-instantiated — the open application as the smallest instance; every promise
      instantiated at it (open-application-law-instances). Proved before naming.
- [ ] naming-as-instance-record-utxo-holds-active — naming as an instance: record UTxO holds the active token;
      `maintain` and `recover` leave the root equal; retirement completion is
      `updateTerminal`; approval policy per naming-approvals-bind-request; `deleteActive` never certified
      (record-binds-active-registration, local-record-update-preserves-registry, naming-approvals-bind-request).
- [ ] existing-naming-statements-recovery-rows-re-stated — the existing naming statements and recovery rows re-stated with
      meaning preserved (retirement-removes-active-witness, recovery-preserves-record-rules).
- [ ] corpus-generators-emit-rows-from-new-model — corpus generators emit rows from the new model; corpora and
      manifests regenerate byte-for-byte.
- [ ] tools-check-model-py-opened-new-identities — `tools/check_model.py` opened to the new identities with its
      discipline intact.
- [ ] compiled-axiom-report-clean-no-sorryax-statements — compiled axiom report clean, no `sorryAx`, every statements
      module gated.
- [ ] theorems-md-model-ledger-md-mutants-md — `docs/theorems.md`, `docs/model-ledger.md` and `docs/mutants.md`
      rewritten against the new model, speech restamped.
- [ ] four-mutants-break-their-named-law-positive — the four #154 mutants each break their named law, each with a
      positive control, each classified statement-kill or row-kill, none from a
      compile failure (mint-second-active-token-for-key–leave-absent-token-outstanding-on-updateactive).
- [ ] theorems-md-equals-its-manifest-exactly-total — `docs/theorems.md` equals its manifest exactly, with the total
      derived rather than asserted (X1). The base tree ships 44 manifest
      declarations against 41 page rows.
- [ ] tools-check-model-py-gains-page-against — `tools/check_model.py` gains the page-against-manifest
      cross-check, seen to fail before it is trusted (X2), so the gap that
      survived v0.6.1 cannot recur once this ticket's gate is gone.
- [ ] refused-reads-read-active-read-absent-in — the refused reads `Read Active` and `Read Absent` are in the
      refusal set with rows and controls, and refused-combinations-as-complement is stated as the complement of
      the seven-edges-interface table rather than an enumeration (operator answer (A-002) SPEC 1, 2).
- [ ] absent-token-s-custody-datum-carries-insertabsent — the absent token's custody datum carries the `insertAbsent`
      refund address; both exits pay there; the custody census holds (custody-lovelace-refund,
      absent-custody-datum). The control uses an inserter and a consumer that differ.
- [ ] naming-s-approval-policy-implements-r-for — naming's approval policy implements naming-approval-rules for all six edges,
      with the four refusal controls (operator answer (A-002) SPEC 5).
- [ ] retirement-map-for-base-generic-declarations-carried — the retirement map for all 44 base generic declarations:
      carried, renamed to what, or retired why (retirement-map-for-generic-statements).
- [ ] statement-quantifies-over-singular-reachable-states-not — every statement quantifies over `Singular.Reachable` states,
      not arbitrary `State` values (operator answer (A-002) SPEC 3).
- [ ] singular-oracle-observation-surface-defined-in-terms — the `Singular.Oracle.*` observation surface, defined in terms of
      the real model rather than as an independent table, so the frozen oracle
      (gate leg A10) can evaluate the model at the ticket owner's inputs.

## Slice B — `#163 simulator` (author `muse`, auditor Opus `lean-simulations-auditor`)

Starts only after slice A's audit passes and its interface is frozen.

- [ ] generic-profile-exposes-seven-edges-read-token — the generic profile exposes the seven edges and the read, with
      the token movement shown per edge (B1).
- [ ] illegal-combination-refused-by-name-matching-model — every illegal combination refused **by name**, matching the
      model's reason (B2).
- [ ] full-replay-agreement-against-new-corpora-executed — full replay agreement against the new corpora, with an
      executed/discovered denominator (B3).
- [ ] naming-profile-over-witness-minted-by-folded — the naming profile: the Over witness minted by a folded read and
      freely burned (B4).
- [ ] simulation-md-describes-journeys-states-finite-model — `docs/simulation.md` describes the journeys and states the
      finite-model limits.
- [ ] lean-clarity-md-records-what-new-formal — `docs/LEAN-CLARITY.md` records what the new formal artifacts did
      and did not communicate to the transcriber (B7).
- [ ] counts-on-front-page-in-design-md — the counts on the front page and in `docs/design.md` equal what
      actually replays (B5).
- [ ] browser-checks-replay-against-new-model — browser checks replay against the new model.
- [ ] changed-page-restamped-just-check-presentation-passes — every changed page restamped; `just check-presentation` passes
      (B6).

## Gate-held, not a task

`nix develop --quiet -c just model` and `nix develop --quiet -c just ci` exit 0
are the gates' criteria, not checkboxes. Only the ticket gate, on the combined
tree, may claim the repository green — slice A is green on its own gate and red
on the simulator by construction, and is never pushed in that state.

## Forward repair after merge

- [x] keep-registry-rename-rewrite-extent-aligned-its — keep the registry rename rewrite extent aligned with its final
      residual gate for tracked Lean and HTML files; permanent controls prove
      both extensions are rewritten and both remain detectable when a residual
      is seeded.
