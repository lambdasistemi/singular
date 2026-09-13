# Q-001 — frozen `BuiltinSemanticsVariant` E is not implemented by the pinned toolchain

**Status:** OPEN (filed 2026-09-12). **Blocks:** executing slice-1 controls with full
identity (variant field unnameable as frozen). Does **not** block: extraction, inventory,
identity scaffolding with the variant marked unresolved, import scaffolding with an explicit
variant parameter.

## Finding

The frozen slice-1 identity triple prescribes, for Plutus V3 post-Conway:

> `defaultFunSemanticsVariantE`, named and justified, never defaulted.

The pinned `PlutusCoreBlaster` (`17cee18a2058790bca36282d82c19146587fb2d1`) implements
exactly **three** variants. Verified from source at that rev on 2026-09-12:

- `PlutusCore/Default/Basic.lean`, lines 47–50: `BuiltinSemanticsVariant` has only
  `defaultFunSemanticsVariantA | B | C`. No D, no E exists at this pin.
- Same file, lines 55–60 (`PlutusVersion.toSemanticsVariant`): PlutusV3 in **any** era
  maps to `defaultFunSemanticsVariantC`. The file's own table (lines 14–24) states
  post-Conway V3 → C.
- `PlutusCore/UPLC/CekMachine.lean` at the pin: `cekExecuteProgram =
  cekExecuteProgramWithSemanticVariant default`, and the `Inhabited` default is C
  (`Default/Basic.lean` line 52–53). The bare convenience entry therefore **silently
  runs variant C** — the exact silent-default behavior the skill forbids relying on.
  `versionToSemanticsVariant` maps every UPLC version to C (marked `TOCHECK` upstream).

So `defaultFunSemanticsVariantE` **cannot be named in Lean code elaborated against the
pinned toolchain** — it does not exist there. This is a statement/identity question, not
a code bug: I will not substitute C for E unilaterally, since the frozen record prescribes
E and the substitution changes a frozen identity expectation.

## Second mechanism fact (bounds the question)

`Lean-blaster` at the pinned rev (`01240b37e3d89dd7c5de13400327b93ba069ecea`)
contains **no** `BuiltinSemanticsVariant` concept at all (every "variant" hit is
"invariant" prose or `Nat` semantics tests). The `#blaster` SMT-discharge interface takes
no variant parameter. The variant binds **explicit CEK execution**
(`cekExecuteProgramWithSemanticVariant`) — and, by an unconfirmed mechanism, whatever Z3
axiomatization `#blaster` assumes for compiled builtins. Whether a `#blaster` discharge
over an imported program assumes a particular variant is **unconfirmed**; I do not claim
SMT-VALID discharges are variant-free in meaning, only that the interface takes no variant.

## Options (owner to rule; option C needs the operator)

- **A. Re-pin** `PlutusCoreBlaster` to a rev that models D/E (if one exists upstream),
  re-verify the skill's V3-post-Conway → E table against that source, and amend the pin.
- **B. Rule C-at-this-pin** as the bound variant for V3: identity records name
  `defaultFunSemanticsVariantC` explicitly (never via `default`/`Inhabited`), with the
  documented limitation that post-Conway D/E builtin refinements are unmodeled at this
  pin and quantified claims stay bounded accordingly.
- **C. Amend the frozen E prescription** itself — moves a frozen identity expectation, so
  under NOTE-001 this needs an **operator** ruling through a concrete user story, not an
  owner ruling.

**Recommendation:** B for instrumentation now (explicit-C parameter, auditable limitation),
with the owner checking whether a newer pin models E (A) in parallel. No bare/default
variant elaborated in the meantime.

## Evidence pointers

- `/tmp/DefaultBasic.lean` — full `PlutusCore/Default/Basic.lean` at the pin (fetched
  2026-09-12; 2064 bytes).
- `/tmp/CekMachine.lean` — `PlutusCore/UPLC/CekMachine.lean` at the pin (258 lines).
- `/tmp/PCBScriptEnc.lean`, `/tmp/PCBUtils.lean` — `#import_uplc` syntax, `isSuccessful
  := isHaltState` / `isUnsuccessful := isErrorState`.
- `CardanoLedgerApiBlaster` pin `577e3eb03b5be09354cfdb1c0d0c12e9e16541a0` confirmed to
  **exist** (GitHub API, commit 2026-04-27, docs readme) — build/field compatibility still
  unconfirmed (blocking debt for definitive runs, not part of this question).
