#!/usr/bin/env bash
#
# Rename the registry: MPFS is a different product (#96).
#
# Turns any origin/main checkout into the renamed tree. Idempotent: every
# step skips work that is already done, so after another PR lands the
# recovery is:
#
#   git fetch origin
#   git checkout chore/rename-registry
#   git reset --hard origin/main
#   ./tools/rename-registry.sh
#   # rebuild, amend/force-push with lease (see PR body)
#
# Never resolve a rename conflict by hand; reset and re-run instead.
#
# What it does, in order:
#   1. git mv every tracked path under offchain/{lib,e2e-test,test}/Cardano/MPFS/Cage
#      to Singular/Registry (same tail), discovered with git ls-files, so a
#      module added by another PR moves too.
#   2. Cardano.MPFS.Cage -> Singular.Registry (dotted and slash form) and
#      cardano-mpfs-cage -> singular-registry (incl. the cabal file itself,
#      which is git mv-ed to singular-registry.cabal).
#   3. MPFS_BLUEPRINT -> REGISTRY_BLUEPRINT, MPFS_SCRIPT_IDENTITY ->
#      REGISTRY_SCRIPT_IDENTITY. No alias, no fallback.
#   4. git mv .github/workflows/mpfs.yml registry.yml; name: Registry; job and
#      step names saying MPFS cage / MPFS journey become registry; mpfs.yml
#      references become registry.yml.
#   5. onchain/aiken.toml name -> singular/registry,
#      naming-onchain/aiken.toml name -> singular/naming-app; rebuild both
#      script-identity derivations (a rename must not move a hash) and diff
#      both script-identity.json manifests against origin/main (must be empty).
#   6. Prose: remaining whole-word MPFS product mentions become registry.
#      Untouched: PROVENANCE.md, docs/prior-art.md (+ its bound speech
#      companion docs/prior-art.speech.json, which cannot be edited without
#      its page), CHANGELOG.md, site/, .docs-source/, frozen evidence logs,
#      and the upstream cardano-mpfs-onchain #100/#101 citations in
#      conformance/app/Conformance/Run.hs and conformance/rows.json.
#      MPF trie identifiers (MPF.*, mkMPFHash, merkle-patricia-forestry,
#      MPFStandalone*, cage_vectors.ak, Cage/CageConfig/cage-*) stay.
#   6b. Identifier sweep (offchain/journey and conformance only): local
#      Haskell identifiers that still carry the product name (mpfsPath,
#      mpfsBp, mpfsBlueprint, mpfs as a variable or record field, any
#      Mpfs* binder) become their registry* equivalents. Exact-identifier
#      matches only: MPFStandalone*, mpfCodecs, MPFHash and haskell-mts
#      imports (the trie, not the product) cannot match.
#   7. Final gate: git grep -iw mpfs (with the exclusions above) may only
#      leave hits sitting on the two upstream citation lines. Allowed files
#      are derived from that same grep, never a hand list.
#
# `--gate-only` runs just step 7 against the current tree: for re-checking
# an already-renamed tree without re-running the renames (this is also how
# tools/rename-registry.test.sh exercises the gate in isolation).
#
# Deliberate gate deviation: the brief's gate command does not exclude
# docs/prior-art.speech.json, but that file is the curated narration bound
# to the excluded docs/prior-art.md page hash. Renaming one without the
# other corrupts the narration binding that check_presentation enforces, so
# the script excludes the pair and reports the companion as a known residual.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# Tracked files the rewrite may touch. Frozen history, provenance, prior art
# and frozen evidence are never rewritten. Shell and Python files are
# scanned like every other text kind (#108): a tracked *.sh kept
# export MPFS_BLUEPRINT because the kinds list missed it. The rename tool
# and its test are excluded: they must keep naming the product they rename,
# and are exempt from the gate for the same reason.
scan_files() {
  git ls-files -z \
    -- '*.hs' '*.cabal' 'cabal.project' '*/cabal.project' '*.nix' '*.md' \
       '*.json' '*.ak' '*.yml' '*.yaml' '*.toml' '*justfile' '*.sh' '*.py' \
    ':!PROVENANCE.md' ':!docs/prior-art.md' ':!docs/prior-art.speech.json' \
    ':!CHANGELOG.md' ':!site' ':!.docs-source' \
    ':!conformance/coverage/evaluation/evidence' \
    ':!tools/rename-registry.sh' ':!tools/rename-registry.test.sh'
}

step1_move_modules() {
  echo "step 1: move module files"
  for prefix in offchain/lib offchain/e2e-test offchain/test; do
    old_prefix="$prefix/Cardano/MPFS/Cage"
    new_prefix="$prefix/Singular/Registry"
    while IFS= read -r -d '' file; do
      new="${file/$old_prefix/$new_prefix}"
      [ "$new" != "$file" ] || continue
      if [ ! -e "$file" ]; then
        continue # already moved by an earlier run
      fi
      if [ -e "$new" ]; then
        echo "error: both $file and $new exist; refusing to guess" >&2
        exit 1
      fi
      mkdir -p "$(dirname "$new")"
      git mv "$file" "$new"
      echo "  mv $file -> $new"
    done < <(git ls-files -z -- "$old_prefix" || true)
  done
  # Drop emptied source dirs (best effort; git does not track dirs).
  rmdir -p offchain/lib/Cardano/MPFS/Cage offchain/e2e-test/Cardano/MPFS/Cage \
    offchain/test/Cardano/MPFS/Cage 2>/dev/null || true
}

step2_modules_and_package() {
  echo "step 2: module and package names"
  if [ -e offchain/cardano-mpfs-cage.cabal ] && [ ! -e offchain/singular-registry.cabal ]; then
    git mv offchain/cardano-mpfs-cage.cabal offchain/singular-registry.cabal
    echo "  mv offchain/cardano-mpfs-cage.cabal -> offchain/singular-registry.cabal"
  fi
  scan_files | xargs -0 -r sed -i \
    -e 's/Cardano\.MPFS\.Cage/Singular.Registry/g' \
    -e 's|Cardano/MPFS/Cage|Singular/Registry|g' \
    -e 's/cardano-mpfs-cage/singular-registry/g'
}

step3_env_vars() {
  echo "step 3: environment variables"
  scan_files | xargs -0 -r sed -i \
    -e 's/MPFS_BLUEPRINT/REGISTRY_BLUEPRINT/g' \
    -e 's/MPFS_SCRIPT_IDENTITY/REGISTRY_SCRIPT_IDENTITY/g'
}

step4_workflow() {
  echo "step 4: CI workflow"
  if [ -e .github/workflows/mpfs.yml ] && [ ! -e .github/workflows/registry.yml ]; then
    git mv .github/workflows/mpfs.yml .github/workflows/registry.yml
    echo "  mv .github/workflows/mpfs.yml -> .github/workflows/registry.yml"
  fi
  wf=""
  if [ -e .github/workflows/registry.yml ]; then
    wf=.github/workflows/registry.yml
  elif [ -e .github/workflows/mpfs.yml ]; then
    wf=.github/workflows/mpfs.yml
  fi
  if [ -n "$wf" ]; then
    sed -i -e 's/^name: MPFS$/name: Registry/' \
           -e 's/^# MPFS cross-tree gates/# Registry cross-tree gates/' \
           -e 's/# MPFS blueprint (each built here/# Registry blueprint (each built here/' \
      "$wf"
  fi
  # Every remaining mpfs.yml file reference points at the renamed workflow.
  scan_files | xargs -0 -r sed -i -e 's/mpfs\.yml/registry.yml/g'
}

step5_aiken_and_identities() {
  echo "step 5: Aiken project names and script identities"
  git rev-parse --verify --quiet origin/main >/dev/null \
    || { echo "error: origin/main is required for the identity diff" >&2; exit 1; }
  sed -i -e 's/^name = "hal\/mpf"$/name = "singular\/registry"/' onchain/aiken.toml
  sed -i -e 's/^name = "singular\/naming-onchain"$/name = "singular\/naming-app"/' \
    naming-onchain/aiken.toml
  grep -q '^name = "singular/registry"$' onchain/aiken.toml \
    || { echo "error: onchain/aiken.toml name not set" >&2; exit 1; }
  grep -q '^name = "singular/naming-app"$' naming-onchain/aiken.toml \
    || { echo "error: naming-onchain/aiken.toml name not set" >&2; exit 1; }
  # The repository's own derivations: a moved hash fails the build.
  nix build ./onchain#script-identity ./naming-onchain#script-identity
  echo "  script-identity derivations build: hashes unmoved"
  # The committed manifests must be byte-identical to origin/main.
  diff <(git show origin/main:onchain/script-identity.json) \
       onchain/script-identity.json
  diff <(git show origin/main:naming-onchain/script-identity.json) \
       naming-onchain/script-identity.json
  echo "  script-identity.json manifests byte-identical to origin/main"
}

step6_prose() {
  echo "step 6: prose product mentions become registry"
  # Case-sensitive fixups first (idempotent: each matches the pre-state only).
  sed -i -e 's/"MPFS off-chain/"Registry off-chain/' offchain/flake.nix
  sed -i -e 's/"MPFS on-chain/"Registry on-chain/' onchain/flake.nix
  sed -i -e 's/for the MPFS cage validator/for the registry validator/' \
    offchain/app/test-vectors/Main.hs \
    offchain/lib/Singular/Registry/Types.hs
  sed -i -e 's/as an MPFS cage datum/as a registry datum/' \
    onchain/validators/consumer.ak
  sed -i -e 's/decodes as an MPFS state/decodes as a registry state/' \
    offchain/journey/retire-verify/Main.hs
  sed -i -e 's/the imported MPFS cage partition/the imported registry partition/' \
    onchain-release/README.md
  sed -i -e 's/MPFS cage validator types, tx builders/Registry validator types, tx builders/' \
    offchain/singular-registry.cabal
  sed -i -e 's/Existing MPFS is a separate application/The product it was imported from is a separate application/' \
    README.md
  sed -i -e 's|`docs/design/registry-as-mpfs.md`|the registry design rulings|' \
         -e 's/Upstream cardano-mpfs-onchain$/Upstream/' \
    docs/consumer-conformance.md
  sed -i -e 's/^MPFS has no concept of/The registry has no concept of/' \
    offchain/naming-correspondence.md
  sed -i -e 's/The MPFS registry state hash/The registry state hash/' \
    naming-onchain/validators/naming.ak
  sed -i -e 's|/// MPFS state address|/// Registry state address|' \
    naming-onchain/validators/fixtures.ak
  sed -i -e 's/, an MPFS insert request/, a registry insert request/' \
         -e 's/-- MPFS side consumes/-- The registry side consumes/' \
    offchain/journey/register/Main.hs
  # CLI surface follows the rename (flag verified against its --help text).
  sed -i -e 's/--mpfs-blueprint/--registry-blueprint/g' \
         -e 's/argMpfsBlueprint/argRegistryBlueprint/g' \
    offchain/journey/verifier/Main.hs
  sed -i -e 's/mpfs_bp/registry_bp/g' nix/release.nix
  # General rules, whole-word only (MPF trie names, camelCase/snake_case
  # locals and Cage identifiers are untouched), citations guarded.
  # GNU sed \< \> are word boundaries: _ is a word char (- and / are not),
  # so MPFS_BLUEPRINT, MPFStandalone and mpfsPath never match.
  scan_files | xargs -0 -r sed -i \
    -e '/cardano-mpfs-onchain/!s/MPFS cage journey/registry journey/g' \
    -e '/cardano-mpfs-onchain/!s/\<MPFS cage\>/registry/g' \
    -e '/cardano-mpfs-onchain/!s/\<MPFS\>/registry/g' \
    -e '/cardano-mpfs-onchain/!s/\<mpfs\>/blueprint/g'
  # Re-bind curated speech companions to their edited pages; the speech
  # text itself is unchanged (no companion mentions MPFS outside prior art).
  stamp_pages=(
    README.md docs/certification.md docs/decisions.md
    docs/consumer-conformance.md docs/LEAN-CLARITY.md specs/protocol/spec.md
  )
  if command -v python3 >/dev/null 2>&1; then
    python3 tools/stamp_speech.py "${stamp_pages[@]}"
  else
    nix develop --quiet --command python3 tools/stamp_speech.py "${stamp_pages[@]}"
  fi
}

step6b_identifier_sweep() {
  echo "step 6b: product-named local identifiers become registry*"
  # NOTE: pipe git ls-files straight into xargs; a bash variable cannot
  # hold the NUL-separated list (NULs are stripped, gluing paths together).
  git ls-files -z -- 'offchain/journey' 'conformance' \
    ':!conformance/coverage/evaluation/evidence' | xargs -0 -r sed -i \
    -e 's/\<mpfsPath\>/registryPath/g' \
    -e 's/\<mpfsBp\>/registryBp/g' \
    -e 's/\<mpfsBlueprint\>/registryBlueprint/g' \
    -e 's/\<envMpfsBlueprint\>/envRegistryBlueprint/g' \
    -e 's/\<checkPinnedMpfsState\>/checkPinnedRegistryState/g' \
    -e 's/\<submitMPFSRequest\>/submitRegistryRequest/g' \
    -e 's/\<MpfsFold\>/RegistryFold/g' \
    -e 's/\<argMpfsBlueprint\>/argRegistryBlueprint/g' \
    -e '/cardano-mpfs-onchain/!s/\<mpfs\>/registry/g'
}

step7_gate() {
  echo "step 7: final gate"
  residual="$(git grep -iw mpfs -- \
    ':!PROVENANCE.md' ':!docs/prior-art.md' ':!docs/prior-art.speech.json' \
    ':!CHANGELOG.md' ':!site' ':!.docs-source' \
    ':!tools/rename-registry.sh' ':!tools/rename-registry.test.sh' || true)"
  if [ -z "$residual" ]; then
    echo "error: no mpfs matches at all; the upstream citations must survive" >&2
    exit 1
  fi
  # Allowed residuals are derived from the same grep above, never a hand
  # list (#108): a file survives only if every one of its mpfs hits sits on
  # an upstream citation line (cardano-mpfs-onchain#100/#101, with or
  # without the space before the issue number). The gate must pass on a
  # clean main and fail on any other product mention.
  strays="$(printf '%s\n' "$residual" \
    | grep -Ev 'cardano-mpfs-onchain ?#(100|101)' || true)"
  if [ -n "$strays" ]; then
    echo "error: mpfs remains outside the upstream citation lines:" >&2
    echo "$strays" >&2
    exit 1
  fi
  echo "$residual"
  echo "gate: only upstream citation lines remain"
}

case "${1:-}" in
  --gate-only)
    step7_gate
    ;;
  "")
    step1_move_modules
    step2_modules_and_package
    step3_env_vars
    step4_workflow
    step5_aiken_and_identities
    step6_prose
    step6b_identifier_sweep
    step7_gate
    echo "rename-registry.sh: complete"
    ;;
  *)
    echo "usage: $0 [--gate-only]" >&2
    exit 2
    ;;
esac
