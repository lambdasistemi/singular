# t87 — Blaster compiled-invariant driver (#87, M1 blocker)

**Role:** bounded implementation driver. Parent: epic 18 owner, pane %914.
**Seat:** Muse (`muse --approve`). **Runtime root:** this directory.
**Worktree:** `/code/singular-e18-blaster` — **yours alone**, created for this slice.
**Branch:** `feat/blaster-compiled-invariants`, base `5bd7c79dd64fd9c7ec872f1c20ab2f5e075366ad`.

You perform bounded implementation. **You do not make semantics or applicability rulings** — those
are mine. If a statement seems wrong, file a question; do not adjust it.

## Read in full before writing anything

1. `../handoffs/87-frozen-invariants-slice-1.md` — **the frozen statements. Implement these
   verbatim.** I verified them from source at the base commit.
2. `/tmp/projects/singular/milestone-1/handoffs/blaster-m1-blocker.md` — the whole commission,
   including the 2026-09-12 parallel-authorization section at the end.
3. `../handoffs/87-compiled-invariant-preimplementation-record.md` — inventory, toolchain, fences.
4. Issue https://github.com/lambdasistemi/singular/issues/87

Load skills: **`aiken-blaster-verification`**, **`code-the-design`**, and the Lean LSP tooling —
work the Lean side through its language server rather than editing blind and rebuilding to find out.

## Owned paths — writes confined to these, in your worktree only

- `blaster/` — the new verification subtree: import/execution path, inventory, controls, evidence.
- `blaster/`-local build and fixture support (its own lakefile, flake input wiring **local to this
  subtree**, extraction scripts, generated artifact directory).

**Forbidden, absolutely:** any file owned by the active #70b or #80c work; the shared conformance
receipt schema; root CI and release config; product validators (`onchain/`, `naming-onchain/`
sources); upstream MPFS. Required shared integration lands later as a **separate serial slice under
#80** — do not do it here, and do not wait for it either.

## First executable deliverable

A **repository-owned, reproducible** Blaster import and execution path for the **actual compiled**
Aiken artifacts, covering **both** `onchain/` and `naming-onchain/`:

1. **Artifact extraction.** Build both partitions; extract each validator's `compiledCode` by
   **explicit title**. Blueprints are build products and absent from the tree — enumerate titles
   from the actual build, never from expectation. **Fail loudly** on a missing, renamed or
   duplicated title. A helper that picks "the first validator" is the defect the skill names.
2. **Explicit identity records.** Commit, clean tree, **actual** compiler and dependency versions
   as reported by the build (`aiken.toml`'s `v1.1.16` is prose — verify it), blueprint and
   compiled-byte digests, exact titles, Plutus version, applied parameters, script identities, and
   the **named, justified `BuiltinSemanticsVariant`** (V3 post-Conway → `defaultFunSemanticsVariantE`).
   Never default it. **Two of three identity fields is `COULD-NOT-EVALUATE`.**
3. **Full title/applicability inventory** across both partitions, versioned, enumerated from an
   explicit list you own — **not a directory walk**. Untracked means uncovered. A declared artifact
   missing from what got assembled goes **RED**, not a warning.
4. **First controls:** I-1 ownerless authority and I-2 supported fold, both directions of the `↔`.

## What you will see, and must report honestly

**I-1 is expected to come back REFUTED against today's artifact.** Epic 17 has not landed the
ownerless repair; `state.ak`'s `End` still calls `validateOwnership`. That REFUTED is a **correct
RED witness of a known defect** — not a harness failure, and not something to work around. Record
it plainly.

## Outcomes — exactly three

`ESTABLISHED` / `REFUTED` / `COULD-NOT-EVALUATE`. The last is **always RED**: missing identity,
unsupported builtin, opaque error, timeout, solver `unknown`, skipped or unreachable assertion.
`NO-COUNTEREXAMPLE-FOUND` is `COULD-NOT-EVALUATE` in disguise.

Keep a **refused builtin dispatch** and a **validator-logic rejection** as distinct findings —
never one bare "errored" line. Name the refused builtin. If a run is bounded by an earlier dispatch
failure, say so and claim nothing about the unreached branch.

Disposition is separate: `SMT-VALID (no proof term)` for `#blaster` discharge — **never
`KERNEL-PROVED`**. Finite CEK runs are `TESTED` and the quantified obligation **stays debt**.

## Prior art

`/code/cardano-mpfs-onchain-blaster` `c26017e` has a working bridge — `#import_uplc … PlutusV3
single_cbor_hex`, `#prep_uplc`, 358 lines of properties. **Inspect it as a structural reference.**
Its results are **not inheritable**: it names no `BuiltinSemanticsVariant` anywhere, so every
record it produced is `COULD-NOT-EVALUATE`. It is upstream MPFS — **read-only**.

## Terminal conditions

- `COMPLETE` when the import/execution path runs reproducibly and slice-1 controls report their
  three-way outcomes with full identity — **or** at capacity, with a handoff, as your peers have.
- `BLOCKED Q-NNN` for any statement, applicability or semantics question. **A toolchain obstacle is
  named blocking debt** — never a waiver, never grounds to substitute model-only evidence, finite
  examples for quantified claims, or skipped builtins.
- This snapshot is **not definitive evidence**. Definitive runs consume epic 17's repaired artifact.
  Build and validate instrumentation now; **never present old-schema or bounded instrumental
  results as completed #87**, and do not wait idly for #77 to implement the harness.
- No merge, no push to `main`, no release, no preprod deploy, no external write.
- You are not alone in the codebase; do not revert edits made by others.

Report through `status-event` in this root's `STATUS.md`.
