# Vendored aiken dependency patches

Provenance disclosure for every patch applied to fetched aiken dependency
sources in `flake.nix`. A reviewer reads this file first.

## mpf-v2.0.0-lone-fork-exclusion.patch

- **Applies to:** `aiken-lang/merkle-patricia-forestry` **v2.0.0**
  (`fetchFromGitHub` rev `v2.0.0`, sha256
  `uHVQxA1dYDuPbH+pf6SkGNBF7nBlDXdULrPFkfUDjzU=`,
  `/nix/store/qvd74r6h60g63myf0a2yqm3kc9zqprlc-source`).
- **Provenance:** v2.0.0 plus exactly two named hunks —
  1. `lib/aiken/merkle-patricia-forestry.ak`: the `do_excluding` lone-`Fork`
     arm now reconstructs the walked common prefix
     (`concat(nibbles(path, cursor, cursor + skip), …)`), adopting the
     upstream v2.1.0 arm body. v2.0.0's arm never consulted `path`/`skip`,
     so exclusion proofs whose sole step is a root-level `Fork` with
     `skip > 0` computed a root with the common-prefix byte missing and were
     refused on chain (bare `CekError`, ticket #81, CS07).
  2. `lib/aiken/merkle-patricia-forestry.tests.ak`: appended the
     `reg_lone_fork_*` regression vectors (real CS07 witness bytes; excluding
     value `fbef6b6d9a253acf2ecf645fd62e663535b828595b8ea38ae2118038d4f9c5a7`,
     including value `cd1f3928377ab7e6d67e05a217d73c6e63dc796fcb90b752fb554ac3049defcf`).
- **Full patch sha256:**
  `2897c4cfda9af673f464ac2c62ddfea1c1777ce8d82e89d4efb0bbf5d3acaf69`
- **Applied by:** `onchain/flake.nix` (`mpfPatched`, `applyPatches` over the
  immutable fetch). The blueprint, `aiken-check`, and the standalone
  `mpf-lone-fork-regression` check all consume the same patched source.
- **Upstream status:** the arm fix corresponds to upstream v2.1.0's rewrite
  of the same arm. A plain v2.1.0 bump was rejected by the desk ruling
  (A-001): unproven for this shape and a much larger delta. Upstream's own
  suite has no lone-`Fork` / skip>0 `Fork` vector; this patch adds one.
- **Licence/origin:** unchanged (upstream MPL-2.0, github
  aiken-lang/merkle-patricia-forestry).
