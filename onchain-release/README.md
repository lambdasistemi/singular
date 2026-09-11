# Singular on-chain release — how to use this archive

You need none of the repository to use this archive. Everything below
runs from this directory alone. The only external requirement is
[Nix](https://nixos.org) for the runnable parts (the identity
verification also runs without it, with just `jq`).

## What the archive carries

| path | contents |
|---|---|
| `onchain/` | the imported MPFS cage partition: Aiken validators, its own `flake.nix`/`flake.lock`, and `plutus.json` — the **compiled** blueprint |
| `naming-onchain/` | Singular's own naming partition: the same shape, with its compiled `plutus.json` |
| `onchain/script-identity.json`, `naming-onchain/script-identity.json` | the **pinned unapplied identities**: every validator's compiled hash and parameter count, plus the compiler string |
| `offchain/` | the runnable journey and the row runners (`offchain/journey/`), their library, and the vendored fixtures module (`offchain/naming/src/Naming/Wire/Vectors.hs`) |
| `fixtures/` | the contract fixtures — the vendored v0.2.0 wire vectors — with their provenance (`fixtures/README.md`) |
| `RELEASE.md` | what this release is and is not — read it before relying on any of this |
| `verify-identities.sh` | the identity check of this archive, needing only `bash` and `jq` |
| `SHA256SUMS` | the checksum manifest of every file in this archive |

The pinned identities are the *unapplied* hashes — the stable,
reviewable identity of each validator. The identities a concrete
instance carries on chain are *applied* (parameterised) hashes,
derived from the pins at run time; the journey asserts that derivation
on every run.

## 1. Verify the archive

From the directory you extracted this archive into (the release's
`SHA256SUMS`, published next to the archive file, covers the archive
itself):

```sh
sha256sum --check SHA256SUMS
```

## 2. Verify the identities from this artifact

The hashes CI enforces, checked against the compiled blueprints this
archive carries — not against any repository:

```sh
bash verify-identities.sh
```

With Nix, you can instead run the exact checks CI runs:

```sh
nix build ./onchain#script-identity --no-link
nix flake check ./naming-onchain
```

## 3. The contract fixtures

The four vendored v0.2.0 wire vectors and their provenance are in
`fixtures/`. The codec suite that checks the naming datum encoding
against them runs with:

```sh
nix develop ./offchain --quiet --command bash offchain/naming/run-suite.sh
```

## 4. The runnable journey and the row runners

Each runner boots a real devnet node (spawned locally, node-to-client)
and executes against it. Build the two compiled blueprints from this
archive's own flakes, then run the runners from `offchain/` (they read
the pinned identity manifests from `../onchain/` and
`../naming-onchain/` by default):

```sh
mpfs="$(nix build --no-link --print-out-paths ./onchain#plutus-blueprint)"
naming="$(nix build --no-link --print-out-paths ./naming-onchain#plutus-blueprint)"

# the bounded MPFS cage journey (boot, request, apply, read back),
# printing the pinned and applied identities it verifies
(cd offchain && MPFS_BLUEPRINT="$mpfs" nix run .#journey)

# LI01 — the canonical initialization row
(cd offchain && MPFS_BLUEPRINT="$mpfs" nix run .#li01)

# LI02–LI08 — the seven initialization refusals
(cd offchain && MPFS_BLUEPRINT="$mpfs" NAMING_BLUEPRINT="$naming" nix run .#li-refusals)

# LM01–LM04, WR01, LC01–LC06 — the maintenance and cancellation rows
(cd offchain && NAMING_BLUEPRINT="$naming" nix run .#naming-rows)
```

Every runner exits non-zero on any mismatch; a zero exit is the run's
claim. What each step does is documented in `offchain/journey/README.md`.

## Scope and limits

Read `RELEASE.md`: this is an epic-scoped release; recovery and
retirement belong to epic 17; and the row evidence is finite fixture
execution on a devnet — not a statement about arbitrary transactions.
