# Plan and checks

Base: selected #528 `04746bfb9c0bec9a10b9ef86bfc3e121aa6ee709`, fast-forwarded
to merged main `c67489502d3cdd8b5230d5fc8aaecbc954198bdc`; identical source trees.

1. Publish the bounded contract as a draft PR; reproduce the defect by exercising
   the actual Environment helper, then retain those tests.
2. Extract the resource owner into a small run-support module. The pinned node
   dependency at `0e73121dc1df516b69d69bdd554b12bebd28d072` only accepts genesis
   and an action, and reads TMPDIR. Use bracketed restoration, exclusive fresh
   directory creation and an explicit owner; pass it from both executable roots.
3. Add deterministic cancellation, nested/overlap rejection and owner-reuse
   controls. Run focused compiled tests, the entire appendix and formatting/lint.
4. Commit a clean candidate, verify packaged entry-point devnet startup, publish
   candidate-bound receipts, then request parent audit and preserve the candidate.

| Claim | Existing executable command / hosted carrier |
| --- | --- |
| Harness lifetime | `cd conformance && nix run --quiet .#conformance-appendix-tests` (Conformance checks without a devnet) |
| Focused lifetime | same command with `--match Conformance.Support.Temporary` |
| Runner builds / starts node | `cd conformance && nix run --quiet .#conformance -- run register-active-key --receipts-dir ABSOLUTE_PATH` (Conformance live jobs) |
| Formatting and hints | `cd conformance && nix run --quiet .#format-check` and `nix run --quiet .#hlint-check` (Conformance format-check job) |
| Repository checks | `nix develop --quiet --no-write-lock-file -c just ci` (CI component checks) |

Baseline appendix: 639 examples, zero failures from conformance working directory.
A first invocation from repository root failed six relative-fixture checks; the
corrected working directory matches hosted CI. `nix run .#build-gate` is a wrong
invocation (the hosted build-only derivation has no executable); hosted uses
`nix build .#build-gate`. Local/static, devnet, hosted and acceptance claims differ.
