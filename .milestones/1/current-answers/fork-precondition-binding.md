# The failing C fold bound to the whole abstract `foldOne .insert` precondition

Worker: `ticket-81/commit-owner` (GLM commit owner, brief POINTER-1789235296-72449).
This is the §1 deliverable required by the brief: every bare "yes" in
`epic-18/handoffs/fork-abstract-binding.md` is replaced by an evidence binding or
an explicitly stated refinement boundary. No guard is reported satisfied because
a fixture failed to exercise it.

## The abstract contract (frozen)

`lean/Singular/Model.lean:168-181`, the `.insert` branch of `foldOne`, guards in
order, plus the success clause:

| # | Lean guard (line) | refusal reason |
|---|---|---|
| 0 | `requireSome (s.requests.find? (·.id == i.request))` (169) | `request-unavailable` |
| 1 | `r.authenticatedOrigin` (170) | `unauthenticated-request` |
| 2 | `insertNative s r && r.token.any (recognized s)` (174) | `insert-binding` |
| 3 | `e.value.isSome → throw` (175) | `occupied-key` |
| 4 | `r.proposal.scope.contains e.incarnation` (176) | `approval-scope` |
| 5 | `r.proposal.initial.representative == representative s e.key` (177) | `representative-identity` |
| 6 | `i.output == some r.proposal.initial && fresh s i.outputId` (178) | `certified-output` |
| ✓ | success: `value := some .active`, application UTxO, `logical := [{ asset := representative s e.key, quantity := 1 }]` | — |

Nothing in the transition mentions a proof encoding. Absence is
`e.value.isSome` on the modelled state. The Merkle witness is a representation
refinement of this transition; the refinement must preserve it for every
reachable key shape, including C.

## The concrete case (all evidence regenerated or re-read 2026-09-12)

Pre-state `{A, B}` (keys `cs07-fork-A`/`cs07-fork-B1294`, values `va`/`vb`),
root `fbef6b6d9a253acf2ecf645fd62e663535b828595b8ea38ae2118038d4f9c5a7`
(cage trie = mirror DB = chain root; folds 1–2 accepted by the same validator,
which recomputes each output root itself). Action: insert absent key
`cs07-fork-C11` with value `vc`. Retained refusal: bare `CekError` at
`insert()`'s `expect excluding(key, proof) == self.root`
(`epic-18/t81-fork-investigation/handoffs/cs07-fork-finding.md` §4).

## Guard-by-guard binding

### 0. Request exists and is live — BOUND (satisfied by execution)

Concrete enforcement site on the exercised path:
`onchain/validators/state.ak:95-110` — the fold consumes a request UTxO whose
inline `RequestDatum` names `requestToken` (must equal the cage tokenId),
`requestKey`, `requestValue`, `requestOwner`, `tip` (`expect tip == stateTip`,
line 103), and `submitted_at` (`expect in_phase1(...)`, line 110). The C fold's
transaction evaluated past all of these — the recorded CekError fires later,
inside `mpf.insert` (line 112). Execution past a guard is the strongest
available evidence that the guard held. **Satisfied for this fold.**

### 1. `authenticatedOrigin` — REFINEMENT BOUNDARY (not exercisable by this fixture)

The generic MPFS cage fixture has no notion of request origin
authentication: nothing in `state.ak` or the request datum corresponds to
`r.authenticatedOrigin`. The exercised fixture certifies only the substrate
guards above. **Not satisfied-by-evidence; retained as coverage debt at the
Singular application layer** (owner: epic 17/18 product layer, not this slice).
This does not weaken the absent-key obligation: the model demands the same
outcome for an authenticated request, and the fixture's generic insert is the
substrate behaviour every such request refines.

### 2. `insertNative` + `recognized` token — PARTIALLY BOUND; rest is boundary

Exercised concretely: `r.operation == .insert` (the redeemer action
`Update [Insert value]` reached `mpf.insert`, state.ak:112) and the request's
token/identity binding (`requestToken == tokenId`, request UTxO at the request
address). Not exercisable by the generic fixture: `proposalNative`'s proposal
binding (`held.isNone`, `destination == requestAddress`, `token == insertAsset`),
and `recognized`'s application-policy acceptance. **The application-token half
is retained as coverage debt** (same owner as guard 1). The substrate half is
satisfied by execution.

### 3. Absence (`e.value.isSome → occupied-key`) — BOUND; THE FAILING ROW

The on-chain encoding of absence is exactly `excluding(key, proof) == root`
(`insert()`, pinned `aiken-lang/merkle-patricia-forestry` v2.0.0): a valid
exclusion witness exists iff the key is absent, and `state.ak`'s
output-root check (line 196, `expect (mpf.root(expectedNewRoot) == newRoot)?`)
recomputes the post-root from the same witness, so a forged "absence" cannot
pass. Binding evidence, all from execution:

- **Producer witness (evidence/e1-probe, exit 0):** the builder's own trie
  produces ONE canonical witness for C —
  `Fork{jump=[1], our=2, neighborNibble=11, neighborPrefix=[11], neighborRoot=651694f5…}`,
  CBOR `9fd87a9f01d8799f0b410b5820651694f…ff` — identical whether generated as
  the honest absence proof (mts `MPF.Proof.Exclusion`, pre-state `{A,B}`) or by
  the builder's insert-then-prove path (`Trie.Pure.getProofSteps`, post-state
  `{A,B,C}`). The off-chain emits the true absence witness.
- **Producer folds:** the witness folds (mts) to the pre-root `fbef6b6d…`
  (absence) and to the committed post-root `cd1f3928377ab7e6d67e05a217d73c6e63dc796fcb90b752fb554ac3049defcf`
  (inclusion) — `absence-verifies-mts: True`, `producer-fold-vs-committed-root: True`.
- **Consumer refusals:** on chain — CekError (retained); offline with the real
  pinned library (evidence/e2-v20-fixed.log, PTY-captured) —
  `e2_insert_accepts_builder_witness_and_yields_builder_post_root` FAIL,
  `e2_including_reproduces_builder_post_root` FAIL,
  `e2_control_leaf_witness_verifies` PASS (the instrument discriminates).

**The abstract transition (C absent → accepted, `+1` of C's representative,
C `active`) cannot be realized by the concrete layer for this key shape.** The
model is unambiguous (A-005); this is an implementation/refinement defect.

### 4. Approval scope — REFINEMENT BOUNDARY (debt, as guard 1)

`r.proposal.scope.contains e.incarnation` has no counterpart in the generic
cage fixture. Retained as coverage debt at the application layer.

### 5. Representative identity — REFINEMENT BOUNDARY (debt, as guard 1)

`representative s e.key` has no counterpart in the generic cage fixture.
Retained as coverage debt at the application layer.

### 6. Certified output / fresh id — PARTIALLY BOUND; rest is boundary

Exercised concretely: state.ak:196 — the output datum's root must equal the
validator's own `mpf`-recomputation, and the output must keep the state script's
address and value conservation (state.ak:198-201). This is the substrate of
"certified output". Not exercisable: `fresh s i.outputId` (application-layer
freshness). **Freshness retained as coverage debt.**

## Occupied-key discrimination (control required by the brief)

`insert()` refuses a present key by construction: for a present key no valid
exclusion witness exists (the walk reaches the key's leaf, so
`excluding` cannot re-derive the root without the key's own slot being empty —
`e2_control_has_fails_against_pre_root` in evidence/probe-v20 exercises the
pre-state direction and E1's control shows no absence proof is constructible
for C against the post-state `{A,B,C}`: `post-state-absence-proof: NONE`).
The surviving discriminating control for the repaired layer: the same fold
with C present must be refused as `occupied-key` at the same venue (ledger).
Epic 18 owns the ledger replay; this slice's controls are specified in
questions/Q-001.

## Site of the defect (§2 result — see questions/Q-001)

- The off-chain proof-selection path is **not** the defect: it emits the
  canonical honest absence witness (E1, byte-identical across both generators).
- The pinned external consumer is: under the pinned `aiken-lang/merkle-patricia-forestry`
  **v2.0.0**, `do_excluding`'s lone-`Fork` arm (`lib/aiken/merkle-patricia-forestry.ak`
  lines 311-314) computes `combine(push(neighbor.prefix, neighbor.nibble), neighbor.root)`
  = blake2b(`0x0b 0x0b` ++ mr) = `95a064ca…` where the chain root is
  blake2b(`0x01 0x0b 0x0b` ++ mr) = `fbef6b6d…` (evidence/e4-aiken-sim, validated
  against the on-chain-accepted fold-2 root: `validate-fold2-accepted-root: True`).
  `bytearray.push` prepends (stdlib `push(#[2,3], 1) == #[1,2,3]`), so the arm —
  which never consults `path`/`skip` — cannot input the common-prefix byte `0x01`.
  No witness encoding can repair this from the off-chain side: `nibbles` are
  taken from the prover's own path, `push` cannot append, and the multi-step arm
  is unreachable at a root-level divergence with an empty prover side.
- Upstream **v2.1.0** rewrote exactly this arm (concat of
  `nibbles(path, cursor, cursor+skip)`); the transcription reproduces the true
  pre-root byte-exactly. Upstream's own suite, however, contains no lone-`Fork`
  and no skip>0 `Fork` vector, and the real v2.1.0 library still fails the
  builder witness offline (evidence/e2-v21*.log) for a reason not yet isolated
  (see the toolchain finding below). A pin bump is therefore **not yet proven
  sufficient**; the end-to-end verdict for any override must come from the
  devnet ledger evaluation.

## Toolchain findings (aiken v1.1.21, per `verification`/`invariants`)

1. Parser errors and some failure reports are printed only on a TTY; piped runs
   exit 1 with no output (source of the earlier "silent crash" misreadings —
   all aiken runs are now PTY-captured under `evidence/*.log`).
2. Offline `miss`/`has`/`insert` verdicts on lone-`Fork` skip>0 witnesses
   contradict validated byte-level transcription in both v2.0.0 and v2.1.0
   (evidence/e2-v21-split.log, e2-v21-i.log vs evidence/e4-aiken-sim output).
   Offline aiken must not be the sole arbiter for this shape; the ledger
   evaluation is.

## Evidence index (all under this runtime root)

- `evidence/e1-probe/Main.hs` — producer probe (command inside header).
- `evidence/e4-aiken-sim/Main.hs` — validated transcription (command inside header).
- `evidence/probe-v20/`, `evidence/probe-v21/`, `evidence/onchain-copy/` —
  throwaway aiken projects (no repo files touched).
- `evidence/e2-v20-fixed.log`, `evidence/e2-v21.log`, `evidence/e2-v21-split.log`,
  `evidence/e2-v21-h.log`, `evidence/e2-v21-i.log`, `evidence/zz-d-full.log`,
  `evidence/e2-v20-warm-1..5.log` (the flaky cold-build artifacts, retained).
- Re-read inputs: `epic-18/t81-fork-investigation/handoffs/cs07-fork-finding.md`,
  `epic-18/handoffs/fork-abstract-binding.md`, `epic-18/answers/A-005…`.
