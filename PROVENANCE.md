# Provenance — imported MPFS on-chain source (`onchain/`, `offchain/`)

`onchain/` and `offchain/` are a byte-exact copy of committed files from
another repository. They were **not** written for Singular, and as of this
commit they have **not been compiled, built, or tested here** in any form.

## Source

| field | value |
|---|---|
| upstream repository | `cardano-foundation/cardano-mpfs-onchain` |
| frozen revision | `34a5bfbb8cca2cb1911b7060d0e61db28ba21e83` |
| revision type | `commit` (verified with `git cat-file -t`) |
| transfer method | `git archive <revision>` — git objects only |

Every byte comes from git objects at that revision. The upstream working tree
was never read, so no uncommitted upstream modification and no generated
output could enter this import.

## Mapping

| rule | source at frozen revision | destination |
|---|---|---|
| R1 | `validators/**` | `onchain/validators/**` |
| R2 | `aiken.toml` | `onchain/aiken.toml` |
| R3 | `aiken.lock` | `onchain/aiken.lock` |
| R4 | `flake.nix` | `onchain/flake.nix` |
| R5 | `flake.lock` | `onchain/flake.lock` |
| R6 | `justfile` | `onchain/justfile` |
| R7 | `haskell/**` | `offchain/**` (leading `haskell/` removed) |

R4, R5 and R6 are upstream **root** files. They are placed under `onchain/`
because that is the destination receiving the root build and configuration
surface, but their applicability at the source revision spans both imported
trees: `flake.nix` imports `./haskell/nix/{project,checks,apps}.nix`, and the
`justfile` drives both `aiken` and `cabal`. This is recorded, not repaired.

## Dependency locks — preserved byte-for-byte

| file | upstream location | blob at frozen revision | sha256 |
|---|---|---|---|
| `onchain/aiken.lock` | `aiken.lock` | `feaf6f3bc081397f94073d36f1ad50194e53c77e` | `191e2eab3d864e27b9d8bd117789aa112649de25b31e09315c81deb05beb3d15` |
| `onchain/flake.lock` | `flake.lock` (repository root) | `db24d83fbe9c12f22aa672eae38b91d5c9814f62` | `0cf7990fe569b3aed5f0aa3e2d5b44a14329cdaed54528ed823a8da307fa8e5b` |
| `offchain/cabal.project` | `haskell/cabal.project` | `c92c42904257b536289c6e191891b8efa357e0ff` | `0507fb3f196aadfabbd5c51f92aaef7c8a39c64dce8619523f0bd5816fe2fab7` |

`offchain/cabal.project` is a **pin file, not a lock**: it fixes an
`index-state` and `--sha256`-pinned `source-repository-package` entries. No
`cabal.project.freeze` exists at the frozen revision, and **none was
invented** — `offchain/` carries no lock file of its own by design.

No lock was regenerated, bumped, or upgraded.

## Excluded, and why

| excluded upstream path | committed files at frozen rev | reason |
|---|---|---|
| `cardano-mpfs-onchain/` | 9 | legacy second Haskell package: absent from `haskell/cabal.project` (`packages: .`), unreferenced by `flake.nix` and `justfile` at the frozen revision |
| `.github/` | 2 | repository-control (CI). Importing it could also trigger compilation, which this import forbids |
| `.gitignore` | 1 | repository-control |
| `.envrc` | 1 | repository-control / direnv dev-environment |
| `.specify/` | 13 | repository-control (spec-kit) |
| `specs/` | 21 | repository-control (spec-kit feature specs) |
| `README.md`, `mkdocs.yml`, `docs/` | 1, 1, 10 | upstream documentation surface; neither validator source nor required build configuration |
| `lean/`, `spec/` | 7, 1 | upstream Lean specification surface; Singular owns its own Lean surface |

The frozen revision has **123 committed files**: 56 imported by rules R1-R7 and
67 excluded by the rows above (9+2+1+1+13+21+1+1+10+7+1). Every committed file
at that revision is therefore accounted for as either imported or explicitly
excluded.

Excluded by construction: every uncommitted modification and untracked path in
the upstream working tree, because only git objects at the frozen revision were
read.

## Licenses

- `offchain/LICENSE` is upstream `haskell/LICENSE`, copied byte-for-byte.
- The upstream repository root carries **no** `LICENSE` blob at the frozen
  revision, so none was invented here. The Aiken side's license declaration
  travels in `onchain/aiken.toml` (`license = "Apache-2.0"`), copied
  byte-for-byte.

## Devnet fixtures

`offchain/e2e-test/genesis/**`, including `delegate-keys/*.kes.skey`,
`*.vrf.skey` and `*.opcert`, are upstream-committed **public devnet test
fixtures** from a public repository. They are not production credentials and
carry no secret-bearing production configuration. They were transferred as
opaque bytes and never opened, parsed, or reused.

## What this import does NOT claim

- **Nothing was compiled, built, or tested.** No `aiken`, `cabal`, `nix`,
  `just` or `lake` invocation is part of this import, and CI was not run
  against it during the copy.
- File identity does not imply that this code builds here, works here, or
  integrates with Singular.
- The copied build and run instructions (`onchain/justfile`,
  `onchain/flake.nix`) are **copied references, explicitly unexecuted**.

## Inherited relative paths broken by relocation — recorded, not repaired

Repairing these is later, separately commissioned work.

| # | file | path as written | after relocation |
|---|---|---|---|
| 1 | `onchain/flake.nix` (`plutus-blueprint`, `aiken-check`) | `src = pkgs.lib.cleanSource ./.` | now spans `onchain/` only, no longer both imported trees |
| 2 | `onchain/flake.nix` | `import ./haskell/nix/project.nix` | missing; the file is at `offchain/nix/project.nix` |
| 3 | `onchain/flake.nix` | `import ./haskell/nix/checks.nix` | missing; the file is at `offchain/nix/checks.nix` |
| 4 | `onchain/flake.nix` | `import ./haskell/nix/apps.nix` | missing; the file is at `offchain/nix/apps.nix` |
| 5 | `offchain/nix/checks.nix` | `${../../validators/cage_vectors.ak}` | resolves outside the import; the file is at `onchain/validators/cage_vectors.ak` |
| 6 | `onchain/justfile` | `cd haskell && cabal build` | `onchain/haskell` does not exist; the package is at `offchain/` |
| 7 | `onchain/justfile` | `cd haskell && MPFS_BLUEPRINT=../plutus.json cabal test` | both halves break; the blueprint would build inside `onchain/` |
| 8 | `onchain/justfile` | `nix build`, `nix develop`, `nix build .#test-vectors` | address `onchain/flake.nix`, whose own imports are broken per 2–4 |

Verified intact after relocation: `offchain/nix/project.nix` (`src = ./..`),
`offchain/nix/checks.nix` source roots, `offchain/cabal.project`
(`packages: .`), `offchain/cardano-mpfs-cage.cabal` source dirs and
`license-file`, the Aiken module imports in `onchain/validators/*.ak`,
`onchain/justfile`'s `validators/cage_vectors.ak` references, and the
`genesis/` sibling-filename group. The `MPFS_BLUEPRINT` environment
indirection is location-agnostic; only its documented value breaks.

## Verification performed

A file-identity gate re-derives the expected extent from
`git ls-tree -r <frozen revision>` through the mapping rules above — not from a
manifest — and compares every destination file's `git hash-object` and mode
against the upstream blob, rejecting missing files, extra files, symlinked
paths and symlinked parent directories. Result: **56 of 56 identical, 0
missing, 0 extra, 0 mismatched**, all three lock rows matching.

The gate is a file-identity check. It says nothing about behavior.

## Inventory — `onchain/` (17 files)

| destination | upstream source | blob at frozen revision | mode |
|---|---|---|---|
| `onchain/validators/cage.ak` | `validators/cage.ak` | `66fbcc305df8762241e5ad1e8aaa63963c2014a2` | 100644 |
| `onchain/validators/cage.props.ak` | `validators/cage.props.ak` | `5f447fa3813f96d2d1e6b2140be15598e83dbd89` | 100644 |
| `onchain/validators/cage.tests.ak` | `validators/cage.tests.ak` | `c662775bcae70e7229f64ed012339dd1cce60585` | 100644 |
| `onchain/validators/cage_vectors.ak` | `validators/cage_vectors.ak` | `eb63576971408d063b7f0c38ea10252486e42eb6` | 100644 |
| `onchain/validators/lib.ak` | `validators/lib.ak` | `8eae49354ed674ee78de7aec5fd6ff17b934d767` | 100644 |
| `onchain/validators/lib.props.ak` | `validators/lib.props.ak` | `202bb0bdd832d9caab3962be00eeda0354a424a1` | 100644 |
| `onchain/validators/lib.tests.ak` | `validators/lib.tests.ak` | `617bcc596cc511ac57c8ecdbd5583579400a7ba8` | 100644 |
| `onchain/validators/request.ak` | `validators/request.ak` | `062c19faea5c59587266f7902683db26d6dfbc3d` | 100644 |
| `onchain/validators/shared.ak` | `validators/shared.ak` | `c2cf987dbc817f65fa1e3b1c5087ffc936ad00dd` | 100644 |
| `onchain/validators/staking.ak` | `validators/staking.ak` | `e5d91430605e7964e03780fe396bc3b7d4bb6b80` | 100644 |
| `onchain/validators/state.ak` | `validators/state.ak` | `30f01e4aeaae4c249cfe6bec09a345fb9bf7818e` | 100644 |
| `onchain/validators/types.ak` | `validators/types.ak` | `f293a2170ce7c0cdbb2e5f63784a71ea18bf15ae` | 100644 |
| `onchain/aiken.toml` | `aiken.toml` | `e03ff2e39e8cf55d056900049a3f645df5ca16cd` | 100644 |
| `onchain/aiken.lock` | `aiken.lock` | `feaf6f3bc081397f94073d36f1ad50194e53c77e` | 100644 |
| `onchain/flake.nix` | `flake.nix` | `5a18dfd528f0b8c7f8d3acf8c1c819346ba26471` | 100644 |
| `onchain/flake.lock` | `flake.lock` | `db24d83fbe9c12f22aa672eae38b91d5c9814f62` | 100644 |
| `onchain/justfile` | `justfile` | `530c57bc9bc40fe592465c364b0a31df005f529d` | 100644 |

## Inventory — `offchain/` (39 files)

| destination | upstream source | blob at frozen revision | mode |
|---|---|---|---|
| `offchain/LICENSE` | `haskell/LICENSE` | `2fa718d4f28786195f366a66e6becc73690f4d90` | 100644 |
| `offchain/app/test-vectors/Main.hs` | `haskell/app/test-vectors/Main.hs` | `bc2f603e39850b67cfe5bb3434a77836ef56b0d7` | 100644 |
| `offchain/cabal.project` | `haskell/cabal.project` | `c92c42904257b536289c6e191891b8efa357e0ff` | 100644 |
| `offchain/cardano-mpfs-cage.cabal` | `haskell/cardano-mpfs-cage.cabal` | `082a039d5d1466b4ef899e1753b03292a81eab42` | 100644 |
| `offchain/e2e-test/Cardano/MPFS/Cage/E2E/CageSpec.hs` | `haskell/e2e-test/Cardano/MPFS/Cage/E2E/CageSpec.hs` | `850946d536550ce0726b79fdb24718826d3a43d7` | 100644 |
| `offchain/e2e-test/genesis/alonzo-genesis.json` | `haskell/e2e-test/genesis/alonzo-genesis.json` | `0a6d69f884ca5131d75411607792a6db65276de6` | 100644 |
| `offchain/e2e-test/genesis/byron-genesis.json` | `haskell/e2e-test/genesis/byron-genesis.json` | `69ac8f38757e8dc82310b37a1287be7a4fe7b069` | 100644 |
| `offchain/e2e-test/genesis/conway-genesis.json` | `haskell/e2e-test/genesis/conway-genesis.json` | `595040f63395bdac31d37f9fb79822d529de4de5` | 100644 |
| `offchain/e2e-test/genesis/delegate-keys/delegate1.kes.skey` | `haskell/e2e-test/genesis/delegate-keys/delegate1.kes.skey` | `8106c3940fb1b3d00545b3d72f2a4f1e95fe0a62` | 100755 |
| `offchain/e2e-test/genesis/delegate-keys/delegate1.opcert` | `haskell/e2e-test/genesis/delegate-keys/delegate1.opcert` | `5d31cc4809dcdf35f04e6722627ebfc6a3f42d69` | 100644 |
| `offchain/e2e-test/genesis/delegate-keys/delegate1.vrf.skey` | `haskell/e2e-test/genesis/delegate-keys/delegate1.vrf.skey` | `41099c3b23055edf23589e385d9a8a9d2c43a463` | 100755 |
| `offchain/e2e-test/genesis/dijkstra-genesis.json` | `haskell/e2e-test/genesis/dijkstra-genesis.json` | `dbe6ec7d81a78bdd712fd10b2dc2da139b14dcad` | 100644 |
| `offchain/e2e-test/genesis/node-config.json` | `haskell/e2e-test/genesis/node-config.json` | `702ba0a4bab30e30df2e0e318fa42999ca8f5960` | 100644 |
| `offchain/e2e-test/genesis/shelley-genesis.json` | `haskell/e2e-test/genesis/shelley-genesis.json` | `626c8b8b4d0853d14e2eaf3c8cfdd31822660bb4` | 100644 |
| `offchain/e2e-test/genesis/topology.json` | `haskell/e2e-test/genesis/topology.json` | `dd46b411d7e44c0d7b8f7bdb621d75b43a41126f` | 100644 |
| `offchain/e2e-test/main.hs` | `haskell/e2e-test/main.hs` | `3119b9a1aa14f36ca7df38193e98c8ea2d12200c` | 100644 |
| `offchain/lib/Cardano/MPFS/Cage/AssetName.hs` | `haskell/lib/Cardano/MPFS/Cage/AssetName.hs` | `20957f8ba9eedc76b67894dc7ae30a4da3d81418` | 100644 |
| `offchain/lib/Cardano/MPFS/Cage/Blueprint.hs` | `haskell/lib/Cardano/MPFS/Cage/Blueprint.hs` | `162dae0e6d5fa1ec0dd41f81bece107b69321721` | 100644 |
| `offchain/lib/Cardano/MPFS/Cage/Config.hs` | `haskell/lib/Cardano/MPFS/Cage/Config.hs` | `337e339bb330b54e8aed936b5c807cde507ce6e3` | 100644 |
| `offchain/lib/Cardano/MPFS/Cage/Ledger.hs` | `haskell/lib/Cardano/MPFS/Cage/Ledger.hs` | `3ea4372b5be4df3d6c0321984c746194eddd52e5` | 100644 |
| `offchain/lib/Cardano/MPFS/Cage/Proof.hs` | `haskell/lib/Cardano/MPFS/Cage/Proof.hs` | `cd976b6b7c1ffd97f7edba80cc3c190e70793b7a` | 100644 |
| `offchain/lib/Cardano/MPFS/Cage/Provider.hs` | `haskell/lib/Cardano/MPFS/Cage/Provider.hs` | `0d80015f9c4e246aafea999cadd29c02fa7a1606` | 100644 |
| `offchain/lib/Cardano/MPFS/Cage/Trie.hs` | `haskell/lib/Cardano/MPFS/Cage/Trie.hs` | `a81c90124127b2891ddd80300eb887d53ad0440a` | 100644 |
| `offchain/lib/Cardano/MPFS/Cage/Trie/Pure.hs` | `haskell/lib/Cardano/MPFS/Cage/Trie/Pure.hs` | `ad98b8dd04dacebdb5013aa0c8488cbcf2c28d4f` | 100644 |
| `offchain/lib/Cardano/MPFS/Cage/Trie/PureManager.hs` | `haskell/lib/Cardano/MPFS/Cage/Trie/PureManager.hs` | `e9d1794a9a3fe2d44d80b09fe0b85e9b61736ec8` | 100644 |
| `offchain/lib/Cardano/MPFS/Cage/TxBuilder/Boot.hs` | `haskell/lib/Cardano/MPFS/Cage/TxBuilder/Boot.hs` | `315e0f13ac33ec2aa562f099805206c2757ac515` | 100644 |
| `offchain/lib/Cardano/MPFS/Cage/TxBuilder/End.hs` | `haskell/lib/Cardano/MPFS/Cage/TxBuilder/End.hs` | `2f9be45cf1491319fa25463f770869cb7225f3a6` | 100644 |
| `offchain/lib/Cardano/MPFS/Cage/TxBuilder/Internal.hs` | `haskell/lib/Cardano/MPFS/Cage/TxBuilder/Internal.hs` | `49ed9f66f0d4b2b0515ad13e212621b2a7f81b58` | 100644 |
| `offchain/lib/Cardano/MPFS/Cage/TxBuilder/Reject.hs` | `haskell/lib/Cardano/MPFS/Cage/TxBuilder/Reject.hs` | `3867a3d05f915406f0a67112eac2476fc4e7db3e` | 100644 |
| `offchain/lib/Cardano/MPFS/Cage/TxBuilder/Request.hs` | `haskell/lib/Cardano/MPFS/Cage/TxBuilder/Request.hs` | `85f20e43ea6ba0af40e2796638ef8cdeaf355465` | 100644 |
| `offchain/lib/Cardano/MPFS/Cage/TxBuilder/Retract.hs` | `haskell/lib/Cardano/MPFS/Cage/TxBuilder/Retract.hs` | `cce93446143e99d25e7f8348a4f954467037b296` | 100644 |
| `offchain/lib/Cardano/MPFS/Cage/TxBuilder/Sweep.hs` | `haskell/lib/Cardano/MPFS/Cage/TxBuilder/Sweep.hs` | `aba71a16f7f78efc347a6c611114d393a7cc1402` | 100644 |
| `offchain/lib/Cardano/MPFS/Cage/TxBuilder/Update.hs` | `haskell/lib/Cardano/MPFS/Cage/TxBuilder/Update.hs` | `8acccdbf94fb53763500eadb1d5f27008a67cd1c` | 100644 |
| `offchain/lib/Cardano/MPFS/Cage/Types.hs` | `haskell/lib/Cardano/MPFS/Cage/Types.hs` | `3dc50023abf5ff4f793954d9fcb85790a9d839fd` | 100644 |
| `offchain/nix/apps.nix` | `haskell/nix/apps.nix` | `95191e7b3fc6ab665a185aaf896afef5839e26b8` | 100644 |
| `offchain/nix/checks.nix` | `haskell/nix/checks.nix` | `01f4538977527fee5d51c04533daeca8dea7564a` | 100644 |
| `offchain/nix/project.nix` | `haskell/nix/project.nix` | `a67ab07989ab8c6d1fa97a296b6345ad5762cf05` | 100644 |
| `offchain/test/Cardano/MPFS/Cage/TypesSpec.hs` | `haskell/test/Cardano/MPFS/Cage/TypesSpec.hs` | `ce610af59afda86d5f3bf3acecb08697ef8d2b86` | 100644 |
| `offchain/test/Main.hs` | `haskell/test/Main.hs` | `8e11a21bb148ee318873ec2d8aebc653fc58c7dc` | 100644 |


## Authorized local divergence — issue #79 (imported-validator repair)

The import above stays byte-exact at the frozen revision
`34a5bfbb8cca2cb1911b7060d0e61db28ba21e83`. On top of it, this
repository carries exactly one authorized local divergence, owned by
epic 17 under A-002 and required by the repository constitution
(Principle I: imported code carries the same obligation as our own
code; Lean `lean/Singular/Model.lean` is the behavioral authority).

### What diverged, and why

Two behaviors of the imported validators contradicted Singular's Lean
model:

- Defect 1: `onchain/validators/state.ak` ran `validateOwnership`
  before dispatching any redeemer, so every `Modify` (every fold)
  required the registry owner. Lean's `.fold` requires only
  `nativeSpend`, net mint equality and the mint witnesses — no owner.
  Repair: the `Modify` path no longer requires the owner; `End` keeps
  `validateOwnership`. Every structural, mint, proof and request check
  on the `Modify` path is retained.
- Defect 2: `onchain/validators/request.ak`'s `validateRetract` never
  inspected the request operation, so an `Update` (retirement) request
  was retractable. Lean's `.withdraw` throws `withdraw-insert-only`
  for non-insert requests. Repair: retraction requires
  `requestValue is Insert(_)`; the request-owner signature, the
  phase-2 window and the state-token binding are retained.

Only `onchain/validators/state.ak` and
`onchain/validators/request.ak` differ from the import baseline.
`onchain/validators/shared.ak` (home of `validateOwnership`) is
unchanged, as are all locks and pins (`onchain/aiken.lock`,
`onchain/flake.lock`, `offchain/cabal.project`) and every other
imported file.

### The patch (the gate, not just a document)

`onchain/REPAIR.patch` applies to the import commit
`34d7abec6ee4830e17a725fa84239af46c3ee206` (this history, offline)
and yields exactly the working tree under `onchain/validators/`. The
slice gate reconstructs baseline + patch and rejects any unlisted
drift, and separately names any changed imported file the patch does
not cover.

### Script identities (derived, reviewed, propagated)

`onchain/script-identity.json` still records the upstream source
revision `34a5bfbb8cca2cb1911b7060d0e61db28ba21e83` and was
regenerated from the actual pinned compilation
(`just script-identity-regen` recipe — never hand-edited). Review of
the resulting bytes: exactly the two repaired validators moved, the
staking script is untouched, the compiler string is unchanged:

| validator | before | after | why |
|---|---|---|---|
| `state.state.*` | `64d1afbfe585b496a325ecacf2600210ff773368010bbab96e5cf1ce` | `d42860fa972c8a325daae773adc372795c48cf365d0a72b137c749d3` | ownership gate moved from top-level `spend` into the `End` branch |
| `request.request.*` | `6b5ce70130332cee6fb016866d2a03c497d313e5df62a22e12af3e5f` | `8970c2865b1a6218b6baed938e8f5474514ba4db7e531fbc597b912c` | added the `Insert`-only operation check to `validateRetract` |
| `staking.staking.*` | `4ab26c95029067185f709d140300cccb15b0b20bbd62a7e9aa2e2e10` | unchanged | out of scope |

Builders consume the compiled blueprint at run time
(`MPFS_BLUEPRINT`), so they pick up the repaired identities without
baked hashes; the row runners assert the pinned unapplied identities
against the build on every run. Documents that quoted observed
identities (`docs/consumer-conformance.md` CA04, the LI01 rows in
`offchain/naming-correspondence.md`) were updated to the values this
repair produces (applied `state.state`:
`ce7615f6ba4de80dfa9b9c6aef680666472ba4ed7e640ff55aad7c6e`,
derived from unapplied `d42860fa…` with `previousPolicies=[]`).

### Known stale prose (not repaired in this slice)

`onchain/validators/types.ak` still documents the old owner-moderated
architecture ("The `owner` field determines who can perform `Modify`
and `End` operations"). It is byte-identical to the import baseline
and outside this slice's owned paths; the behavior is repaired, the
prose is not. Forwarded to the parent as a docs follow-up.
