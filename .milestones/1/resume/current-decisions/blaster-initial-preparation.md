# #87 — pre-implementation record (compiled-invariant validation, M1 blocker)

Required by handoffs/blaster-m1-blocker.md before implementation. Facts established by inspection
on 2026-09-12; every claim below is a starting condition, **not** a result.

**Current result: REQUIRED / NOT YET ESTABLISHED.** No Blaster run is claimed.

## 1. Issue and ownership

- Issue: https://github.com/lambdasistemi/singular/issues/87 (OPEN), parent #18.
- Strict gate integration lands in #80 as a **separate per-obligation compiled-invariant debt
  category** — not folded into the existing 192-theorem denominator.
- Epic 18 owns inventory, the executable verification artifact, and gate integration.
- Epic 17 supplies the repaired ownerless validator artifacts and owns implementation defects
  through its existing serial writer. **No second validator writer, no extra auditor.**

## 2. Affected inventory — starting scope

Validator sources in `/code/singular-e18-cg/onchain/validators/`: `cage.ak`, `request.ak`,
`shared.ak`, `staking.ak`, `state.ak`, `types.ak` (`*.props.ak`, `*.tests.ak`, `cage_vectors.ak`
are test material, not M1 titles).

**The blueprint is absent from the tree** — `plutus.json` is a build product. Validator *titles*
therefore cannot be enumerated from source and must come from an actual build. Recording this now
because "the titles we expect" is not an inventory, and a helper that picks the first title is the
defect the skill names explicitly.

Applicable invariants derive from the full accepted Lean inventory (192 declarations, no
exclusions). Applicability is **unclassified as of today**, and unclassified rows are debt.

## 3. Toolchain availability

| Component | State |
|---|---|
| `Lean-blaster` | present, `/code/Lean-blaster`, `/code/Lean-blaster-nix` |
| `PlutusCoreBlaster` | present; `issue-28`, `issue-28-u1-candidate`, `issue-28-u1-pinned` (`17cee18`) |
| `CardanoLedgerApiBlaster` | reachable through the prior-art flake; **not independently confirmed** |
| Singular blueprint | **absent** — must be built |

### Prior art, and why its results cannot be inherited

`/code/cardano-mpfs-onchain-blaster` carries a working UPLC property bridge (`c26017e`):
`Scripts.lean` does `#import_uplc … PlutusV3 single_cbor_hex` on three titles and applies them with
`#prep_uplc`; `Properties.lean` is 358 lines of claims. It is a **sound structural reference** for
the import-and-apply pattern and should be read as such.

It is **not** inheritable evidence: `grep` for `SemanticsVariant`/`SemanticVariant` across that
whole bridge returns **nothing**. Under the skill's rule — *"a record that names no variant is not
weak evidence, it is COULD-NOT-EVALUATE, full stop"* — every result it produced is
`COULD-NOT-EVALUATE` for our purposes. Two of three identity fields is a green run describing
something nobody verified.

It also sits in the upstream MPFS repository, which this epic must not modify. **Read-only.**

## 4. Identity triple — what we can and cannot state today

- **Commit** — available (clean tree required at build time).
- **Toolchain** — `onchain/aiken.toml` *documents* `compiler = "v1.1.16"`, `plutus = "v3"`. That is
  prose. The skill records a real incident of a project documenting `1.1.21` while CI ran `1.1.23`,
  invisible in the blueprint. **Treat the documented pin as unverified** until a build reports its
  own version, and check it mechanically against the lock rather than by reading.
- **`BuiltinSemanticsVariant`** — Plutus **V3**; for a post-Conway target the variant is
  `defaultFunSemanticsVariantE`. It must be **named and justified explicitly for the target ledger**,
  never defaulted. Until named, every record is `COULD-NOT-EVALUATE`.

## 5. First executable slice

Per the commission: **ownerless authority + supported-fold obligations.**

This slice is **not the denominator** — the denominator is the full applicable M1 inventory, and
the slice must not be reported as coverage of it.

Sequencing: inventory and toolchain/runner preparation proceed **now**, alongside the current
repairs. **Definitive compiled evidence is bound to epic 17's repaired ownerless artifact** and
cannot be produced against the six-field owner-bearing state. Anything re-run must be re-run
whenever source, parameters, toolchain or semantics change.

## 6. Worker ownership

No seat is free: `t70b-generic-rows-finish` (GLM, %981) is finishing the #70 packaging;
`t80c-release-gate` (Muse, %917) is repairing the four PR-86 boundary defects. A #87 seat opens
when one of those reaches a terminal state — dispatching a third now would contend for the same
shared conformance files, and the commission requires those to be touched **serially**.

## 7. Terminal conditions

- Every assertion reports exactly one of `ESTABLISHED`, `REFUTED`, `COULD-NOT-EVALUATE`.
- `COULD-NOT-EVALUATE` is **always RED** and blocks acceptance: missing identity, unsupported
  builtin, opaque error, timeout, solver `unknown`, skipped or unreachable assertion.
  `NO-COUNTEREXAMPLE-FOUND` is `COULD-NOT-EVALUATE` in disguise.
- A refused **builtin dispatch** and a **validator-logic** rejection are different findings and are
  never collapsed into one "errored" line. A run bounded by an earlier dispatch failure claims
  nothing about the unreached branch.
- Disposition is recorded separately: `KERNEL-PROVED` / `SMT-VALID (no proof term)` / `TESTED` /
  `UNPROVED`. A `#blaster`-discharged theorem is **`SMT-VALID`, never `KERNEL-PROVED`**. Finite CEK
  executions are `TESTED`, and the quantified obligation stays debt.
- Discrimination is proven by **mutating source and rebuilding through the production compiler**,
  showing the mutated bytes reached the evaluator, retaining the `REFUTED` result, then restoring
  and re-verifying the baseline. A control that survives removal of what it certifies is decorative
  — that exact defect was just found in PR 86 and must not recur here.
- Enumeration comes from a **versioned inventory**, never a directory walk: untracked means
  uncovered, and a missing declared artifact goes RED rather than warning.
- **A toolchain obstacle is named blocking debt** — never a waiver, and never grounds to substitute
  model-only evidence, finite examples for quantified claims, or skipped builtins.

## 8. Fences

No Scalus. No upstream MPFS modification. No indexer. No preprod deploy. No release-line change.
No second validator writer, no extra auditor. #77's frozen gate and retained evidence stay intact.
PR 86's rejected boundary evidence is preserved and labelled, not deleted. Existing coverage debt
is preserved in full. Ordinary independent docs publication keeps its existing policy.
