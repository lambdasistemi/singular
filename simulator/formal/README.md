# simulator/formal — the Lean the page ships, mirrored

The page is a transcription of the Lean model, so a reader who has only the
published simulator must be able to read the thing it was transcribed from.
This directory is that copy: every Lean source under `lean/` and every generated
theorem manifest, byte for byte.

It is a **mirror**, not an archive. A stale copy here would put a reader in
front of a model that is not the one the page implements, and would do it
silently, so the mirror is enforced rather than maintained by habit:

- `node simulator/mirror-check.mjs` compares this directory with `lean/` in both
  directions and fails on a differing file, a missing file, or an extra one. It
  runs inside `just simulator`, so it runs in CI.
- `../identity.json` additionally records the sha256 of every file here, and
  `simulator/build.mjs --check` fails if any byte moves without the identity
  being regenerated.

Nothing here is compiled: no lakefile lists it and no derivation builds it.
`gate.mjs` reads `theorem-debt.json` as data for the statement table. The
authority is `lean/`; this is the copy that travels with the page.
