# Build sheet — #81 lone-Fork exclusion: remainder after capacity limit

Predecessor: `ticket-81/commit-owner` (this root), branch
`fix/fork-absence-insert-81`, RED commit **`b6d8c7e`** (parent `5bd7c79`).
Desk ruling: **A-001** (tracked local patch over v2.0.0 via onchain Nix
staging; ledger acceptance owed; no public fork; no upstream bump; no Lean
edit). Worktree is clean; everything below is committed except where noted.

## State at handoff

- `onchain/patches/mpf-v2.0.0-lone-fork-exclusion.patch` — the vendored fix
  (v2.1.0's arm body: reconstruct the walked prefix via
  `concat(nibbles(path, cursor, cursor+skip), push(prefix, nibble))`) plus the
  `reg_lone_fork_*` vectors appended to the package's own tests file.
  Patch sha256
  `bb522955089eb686c3a1629c4a24c11908e77b6838dd48d89541313619480091`.
- `onchain/flake.nix` — `merkle-patricia-forestry-patched` (`applyPatches`),
  `aikenPrelude` stages it, dev-shell `shellHook` stages it, new
  `mpf-lone-fork-regression` check derivation (runs the vendored package's own
  suite standalone), `vendored-mpf-digest` package.
- `onchain/patches/README.md` — provenance disclosure.
- `onchain/validators/lone_fork.tests.ak` — project-level discrimination
  vector (insert/including/occupied-key-direction control).
- **Offline state: RED.** `aiken-check` fails the vector on the patched build;
  it also fails on unpatched v2.0.0 (that direction is intended).

## The one open investigation (do this first)

The aiken v1.1.21 test-runner CEK evaluates the skip>0 lone-`Fork` exclusion
arm to something that contradicts byte-level transcription — in upstream
v2.1.0 AND in our patched v2.0.0. Refuted candidate values for what the CEK
computes (probed via `miss`/`has` against candidate roots, all under
`evidence/e2-v21-*.log`):

- `95a064ca…` (v2.0.0-arm value), `a188df72…` (`[0x01,0x0b]++mr`),
  `5ff20ad6…` (`[0x0b,0x0b,0x01]++mr`),
  `97712f1f…` (prefix/nibbles swapped),
  `525b5dbe…` (`[0x01]++mr`), `d2de8c96…` (multi-step-arm-with-empty-steps
  value). CEK primitives isolated fine: push-on-empty, concat, and the
  library's own skip=0 kumquat `miss` all PASS (e2-v21-k2.log, e2-v21-h.log).

Extraction harness sketch (next step): in a failing test, compute the arm's
value through `mpf.root(mpf.delete(mpf.from_root(including_candidate), key,
value, witness))` (delete returns `excluding(key, proof)` after its own
`expect including == root`), hex-encode it with pure bytearray ops and
`trace` it; the trace prints on failure. Then compare against the expected
`fbef6b6d…` preimage `0x01 0x0b 0x0b ++ mr`.

Decision rule (from A-001): the ledger is the acceptance authority; if the
offline engine still contradicts the ledger, keep both bodies of evidence and
report the discrepancy — do not conclude from the hand transcription (E4) nor
from a single engine.

## Devnet acceptance (A-001's four required items)

Use a **private shallow `TMPDIR` you allocate** — never `/tmp/cardano-e2e`.
Reuse the e2e harness the CS07 investigation used (conformance/devnet driver
in `offchain/`, blueprint via `nix build ./onchain#plutus-blueprint` after
this patch). Required, on the real packaged patched validator:

1. fold inserting absent C accepted; map shows C `active`; logical delta
   exactly `+1` of C's representative; read back from chain.
2. same fold with C present refused as `occupied-key` (coherent raw body).
3. **unpatched control**: revert `onchain/flake.nix`'s
   `merkle-patricia-forestry-patched` → `merkle-patricia-forestry` in the
   staging (one line), rebuild, and the C fold must reproduce the original
   bare `CekError` (retained signature: cs07-fork-finding.md §4). Revert the
   revert afterwards.
4. the vendored package's own `reg_lone_fork_*` vector — runs via
   `nix build .#checks.x86_64-linux.mpf-lone-fork-regression`; expected
   excluding `fbef6b6d…`, including `cd1f3928…`.

Then mechanical close-out:

- `cd onchain && just script-identity-regen` (regenerates
  `onchain/script-identity.json`; the state validator hash WILL move — that
  is the point) and `nix build .#script-identity`.
- GREEN commit: patch already in b6d8c7e; the GREEN commit carries
  script-identity.json (+ any ledger-evidence refs), message
  `GREEN(fork-81): …` referencing this sheet.
- Report YOUR measured validator hashes; integration/rebound is the epic's
  (A-001) — do not anticipate combined hashes.

## Retained evidence index (this root)

`evidence/e1-probe/`, `evidence/e4-aiken-sim/`, `evidence/probe-v20/`,
`evidence/probe-v21/`, `evidence/onchain-copy/` (throwaway aiken projects +
logs `e2-v20-fixed.log`, `e2-v21*.log`, `red-unpatched-vector.log`,
`zz-d-full.log`), `handoffs/fork-precondition-binding.md` (guard binding +
refinement boundaries: application-layer guards remain NAMED DEBT).

## Budget at handoff

~6 aiken builds (2 wasted on the swallowed-parser-error discovery), 2 conformance
runs, 3 ghci probe sessions, 1 devnet-less. No devnet spend yet. Journal is
append-only complete from START.
