# Q-001: dependency-boundary ruling — the defect is in the pinned Aiken MPF library (site 1)

Filed by: `ticket-81/commit-owner` per brief §2 and NOTE-016/NOTE-049
("if a vendored override is required, return the exact path/pin/provenance
change to root before changing that dependency boundary").

## Decision needed

Authorize (or reject / re-scope) crossing the external-dependency boundary for
`aiken-lang/merkle-patricia-forestry`, choosing one of the two override shapes
below. No file outside my fence has been touched; the worktree is clean at
`5bd7c79`.

## Established (evidence: handoffs/fork-precondition-binding.md, evidence/)

1. The off-chain proof-selection path (site 2) is correct: both the honest
   absence generator (`MPF.Proof.Exclusion`) and the builder's insert-then-prove
   path (`MPF.Proof.Insertion` via `Trie.Pure.getProofSteps`) emit the same
   canonical witness for C, and it folds (mts) to both the chain-accepted
   pre-root `fbef6b6d…` and post-root `cd1f3928…`.
2. The pinned consumer v2.0.0 is defective: its `do_excluding` lone-`Fork` arm
   (lib/aiken/merkle-patricia-forestry.ak lines 311-314) cannot input the
   common-prefix byte (it never reads `path`/`skip`; `bytearray.push` prepends).
   Byte-exact: it computes blake2b(`0x0b 0x0b` ++ mr) = `95a064ca…` instead of
   blake2b(`0x01 0x0b 0x0b` ++ mr) = `fbef6b6d…`. No off-chain witness encoding
   can compensate (Branch/Leaf steps derive their prefix from the prover's own
   path; the multi-step Fork arm is unreachable at a root-level divergence with
   an empty prover side). This reproduces the on-chain CekError offline.
3. Upstream v2.1.0 rewrote exactly this arm to concat
   `nibbles(path, cursor, cursor+skip)`, and the transcribed fix reproduces the
   true pre-root byte-exactly — but the real v2.1.0 library still fails the
   builder witness offline (`miss` and `has` both FAIL), including its public
   `miss`, while its own skip=0 vectors pass. The discrepancy (CEK vs validated
   transcription) is isolated to the skip>0 concat branch upstream added
   **without any test vector** — upstream's own suite has no lone-`Fork` and no
   skip>0 `Fork` case at all.
4. Toolchain limitation (binding for whoever verifies the override): offline
   aiken v1.1.21 verdicts on lone-Fork shapes are untrusted (swallowed parser
   errors on non-TTY; CEK-vs-transcription contradiction above). The definitive
   acceptance for any override is the devnet ledger evaluation — the same venue
   that retained the original refusal — plus the expected values in
   fork-precondition-binding.md (excluding = `fbef6b6d…`; including =
   `cd1f3928…`; occupied-key control: same fold with C present refused).

## The exact boundary change, per shape

Common: both shapes change the compiled cage/state script bytes, so
`onchain/script-identity.json` must be regenerated (`just script-identity-regen`)
and the PROVENANCE frozen-revision note updated; devnet bootstrap artifacts that
pin the old script hash must be rebuilt. Epic 18 retains consumer replay and the
#68/#81 coverage disposition.

### Shape A — pin bump to upstream v2.1.0

- `onchain/aiken.toml`: `name= "aiken-lang/merkle-patricia-forestry"`
  `version = "v2.0.0"` → `"v2.1.0"` (source github, unchanged).
- `onchain/aiken.lock`: regenerate (`aiken build` resolves; package cached at
  `~/.cache/aiken/packages/aiken-lang-merkle-patricia-forestry-v2.1.0.zip`,
  provenance github tag `v2.1.0`).
- Provenance: upstream `github.com/aiken-lang/merkle-patricia-forestry` tag
  `v2.1.0`. Local sources compared: nix-store
  `qvd74r6h60g63myf0a2yqm3kc9zqprlc-source` (v2.0.0) vs
  `m7yq5j280r5wgqknryrasymi3a5yrwkb-source` (v2.1.0); the v2.1.0 delta includes,
  besides the arm fix: `miss`/`has`/`insert_ffi`/`delete_ffi` additions,
  merkle_2/merkle_4 inlining refactor (semantics-preserving), `bytearray.at`
  swap in helpers. Larger review surface; carries the unresolved item 3 above.

### Shape B — minimal vendored fork of v2.0.0

- Fork of v2.0.0 with ONLY the lone-`Fork` arm replaced by the skip>0 fix
  (the upstream v2.1.0 arm body: concat
  `nibbles(path, cursor, cursor+skip)` ++ `push(neighbor.prefix, neighbor.nibble)`),
  pinned to a lambdasistemi fork repo+tag with a recorded sha256
  (provenance: v2.0.0 + one disclosed hunk; fork URL/tag to be created on
  approval — no existing fork is assumed).
- Same aiken.toml/aiken.lock/script-identity/PROVENANCE consequences as Shape A.
- Smallest possible review surface; keeps every other code path byte-identical
  to the audited v2.0.0.

## Recommendation

Shape B (minimal vendored override), with the repair slice REQUIRED to include:
(i) a new lone-Fork/skip>0 regression vector in the vendored package's own
tests, built from the retained witness bytes with expected excluding value
`fbef6b6d…` and including value `cd1f3928…`; (ii) the occupied-key control;
(iii) final acceptance via devnet ledger evaluation, not aiken-test-runner
verdicts alone (toolchain finding). If the desk prefers upstream alignment,
Shape A is acceptable only with the same (i)-(iii), because item 3 shows the
bump is unproven for this shape.

## Not asked, not authorized by this question

No model/Lean edit (none is needed — the transition is unambiguous); no proof
shape switch; no exclusion of key C; no dependency refresh beyond the override;
no consumer replay or coverage marking (epic 18's).
