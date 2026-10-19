{
  pkgs,
  src,
  docs,
}:
let
  version = pkgs.lib.removeSuffix "\n" (builtins.readFile (src + "/version.txt"));
  python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);

  # Issue #91: the candidate revision the on-chain archive publishes as
  # its RELEASE-COMMIT file (the archive is not a git checkout, so the
  # runners could not otherwise establish their candidate). The
  # pipeline's TAG_COMMIT (github.sha) wins at run time; a local build
  # falls back to the flake's own revision; a tree with no git identity
  # says so instead of inventing one.
  releaseCommit = src.rev or (src.dirtyRev or "unknown-dirty");

  # NOTE-001 (t57-release): the root flake never crosses a flake boundary at
  # eval time — no builtins.getFlake, no path inputs, no lock edit. The two
  # compiled blueprints the on-chain release carries are built as their own
  # steps by the assembler below (`nix build ./onchain#plutus-blueprint` and
  # `./naming-onchain#plutus-blueprint`), exactly as the journey and row jobs
  # already do, so each partition evaluates against its own committed lock.
  # The resulting store paths are passed into staging as arguments — a step
  # passing a store path is pure. The check afterwards verifies the carried
  # blueprints against the committed script-identity.json manifests in both
  # directions (hashes, parameter counts, compiler string), from the archive
  # itself, so any divergence from the identity CI enforces fails loudly.
  assembler = pkgs.writeShellApplication {
    name = "assemble-onchain-release";
    runtimeInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.gnutar
      pkgs.gzip
      pkgs.jq
      pkgs.nix
      pkgs.git
      python
    ];
    text = ''
      usage() { echo "usage: assemble-onchain-release <repo-root> <docs-dir> <out-dir>" >&2; exit 2; }
      [ "$#" -eq 3 ] || usage
      root="$1"; docs="$2"; out="$3"
      # Each blueprint: built from this checkout's own partition flake, its
      # own lock — the same builds CI's script-identity jobs verify.
      # S5.2: the archive's onchain/plutus.json is the merged deployment
      # document (the one the CLIs get as --blueprint, application plus
      # witnesses from one build), built in the application's onchain flake
      # from the same two trees the comparison verifies.
      cd "$root"
      deployment_bp="$(nix build --quiet --no-link --print-out-paths ./applications/open-datum/onchain#open-datum-blueprint)"
      naming_bp="$(nix build --quiet --no-link --print-out-paths ./naming-onchain#plutus-blueprint)"
      # #528 slice 4: the release ships both executables. The assembly
      # obtains `open-datum` (and the negative-host pair's
      # `singular-negative`, built from the application's tree now) from
      # the application's flake as its own steps, exactly as the blueprints
      # above — no eval-time flake crossing, no lock edit. The archive
      # itself carries both trees' sources (see assemble_onchain_release.py);
      # these builds prove both flakes evaluate and both executables link.
      open_datum_store="$(nix build --quiet --no-link --print-out-paths ./applications/open-datum/offchain#open-datum)"
      host_store="$(nix build --quiet --no-link --print-out-paths ./applications/open-datum/offchain#singular-negative)"
      registry_store="$(nix build --quiet --no-link --print-out-paths ./offchain#singular)"
      [ -x "$open_datum_store/bin/open-datum" ] || { echo "assemble-onchain-release: open-datum binary missing at $open_datum_store" >&2; exit 1; }
      [ -x "$host_store/bin/singular-negative" ] || { echo "assemble-onchain-release: singular-negative binary missing at $host_store" >&2; exit 1; }
      [ -x "$registry_store/bin/singular" ] || { echo "assemble-onchain-release: singular binary missing at $registry_store" >&2; exit 1; }
      # Issue #91: the archive carries the commit it publishes (see
      # releaseCommit above); assemble_onchain_release.py writes it into
      # the archive root as RELEASE-COMMIT.
      RELEASE_COMMIT="''${TAG_COMMIT:-${releaseCommit}}"
      export RELEASE_COMMIT
      python3 "$root/tools/assemble_onchain_release.py" \
        "$root" "$docs" "$deployment_bp" "$naming_bp" "$out"
      # The full release check — version agreement, archive members, both
      # checksum manifests, release text, and identity verification run from
      # the extracted artifact — against the exact bytes to be published.
      python3 "$root/tools/check_release.py" "$root" "$out"
      # The surface negative control, on those exact assembled bytes: the
      # verified-command promise, the retained-command disclosure and the
      # release-text consistency are each mutated in temporary extracted
      # copies, both manifests recomputed and proven, and the checker must
      # refuse each variant for its stated surface reason. The assembled
      # archive itself is never modified. The control lives here — inside
      # the active archive-build boundary that required CI executes
      # (`release-artifacts`) and that the publish path reuses — so a
      # docs-only `release-check` pass can never stand in for an on-chain
      # surface pass, and nothing uploads or publishes without it. It calls
      # the checker directly, never this assembler, so it cannot recurse.
      bash "$root/tools/release_surface_control.sh" "$root" "$out"
    '';
  };

  # One command for CI: assemble and fully check the on-chain release from
  # this checkout. `nix run .#release-artifacts -- <out-dir>`
  releaseArtifacts = pkgs.writeShellApplication {
    name = "release-artifacts";
    runtimeInputs = [ assembler ];
    text = ''
      out="''${1:?usage: release-artifacts <out-dir>}"
      mkdir -p "$out"
      ${pkgs.lib.getExe assembler} "$PWD" ${archive} "$out"
    '';
  };

  # #565: reproduce the review archive from its own bytes the way a
  # reviewer would. The docs release derivation above assembles the
  # archive with the same tools the release uses
  # (tools/prepare_release.py over the built site), so this wrapper
  # builds that same derivation instead of assembling twice, extracts it
  # to a scratch directory outside the checkout, runs the checksum
  # manifest and the archived check, then proves the check can fail by
  # removing one shipped input with the manifest recomputed. The wrapper
  # owns its scratch directory, created and removed on every exit
  # (including setup failure); it stops no process. Setup failure is
  # exit 2, never a verdict.
  releaseReviewCheck = pkgs.writeShellApplication {
    name = "release-review-check";
    runtimeInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.git
      pkgs.gnutar
      pkgs.gzip
      pkgs.gnugrep
      pkgs.nix
    ];
    text = ''
      set -euo pipefail
      setup_fail() { echo "release-review-check: SETUP: $1" >&2; exit 2; }
      verdict_fail() { echo "release-review-check: FAIL: $1" >&2; exit 1; }
      work="$(mktemp -d)" || setup_fail "cannot create a scratch directory"
      trap 'rm -rf "$work"' EXIT
      root="$PWD"
      release_out="$(nix build --quiet --no-link --print-out-paths "$root#docs-release")" \
        || setup_fail "building the docs release archive"
      archive_path=$(echo "$release_out"/singular-docs-*.tar.gz)
      case "$archive_path" in
        *"*") setup_fail "no docs tarball in $release_out" ;;
      esac
      [ -f "$archive_path" ] || setup_fail "no docs tarball in $release_out"
      extracted="$work/extracted"
      mkdir -p "$extracted" || setup_fail "creating the extraction directory"
      tar -C "$extracted" -xzf "$archive_path" || setup_fail "extracting the docs archive"
      test ! -e "$extracted/.git" || verdict_fail "the archive carries a git checkout"
      (cd "$extracted" && sha256sum --check artifacts/SHA256SUMS) \
        || verdict_fail "checksum manifest mismatch"
      check_log="$work/check.log"
      (cd "$extracted/artifacts/review" && nix run --no-write-lock-file .#check >"$check_log" 2>&1) \
        || verdict_fail "the archived check failed"
      grep -F "PASS archive model and replay reproduction" "$check_log" >/dev/null \
        || verdict_fail "the archived check passed without its receipt line"
      default_log="$work/default.log"
      (cd "$extracted/artifacts/review" && nix run --no-write-lock-file .#default >"$default_log" 2>&1) \
        || verdict_fail "the archived default app failed"
      # The control: one shipped input removed, the manifest recomputed,
      # so the checksum step stays green and the check must go red for
      # the missing file, distinguished from a toolchain failure by the
      # missing path in its diagnostic.
      mutant="$work/mutant"
      mkdir -p "$mutant" || setup_fail "creating the control directory"
      tar -C "$mutant" -xzf "$archive_path" || setup_fail "extracting the control archive"
      rm "$mutant/artifacts/review/.specify/memory/constitution.md" \
        || setup_fail "removing the control input"
      grep -vF "artifacts/review/.specify/memory/constitution.md" "$mutant/artifacts/SHA256SUMS" >"$work/SHA256SUMS" \
        || setup_fail "recomputing the mutant manifest"
      mv "$work/SHA256SUMS" "$mutant/artifacts/SHA256SUMS"
      (cd "$mutant" && sha256sum --check artifacts/SHA256SUMS >/dev/null) \
        || setup_fail "the mutant manifest does not verify"
      mutant_log="$work/mutant.log"
      if (cd "$mutant/artifacts/review" && nix run --no-write-lock-file .#check >"$mutant_log" 2>&1); then
        verdict_fail "control undetected: the check passed without the constitution"
      fi
      grep -F "constitution" "$mutant_log" >/dev/null \
        || verdict_fail "control failed for the wrong reason (no constitution diagnostic)"
      echo "release-review-check: PASS — the archived check passes alone, and fails without the constitution"
    '';
  };

  archive =
    pkgs.runCommand "singular-docs-release-${version}"
      {
        nativeBuildInputs = [
          pkgs.gnutar
          pkgs.gzip
          pkgs.coreutils
          pkgs.python3
        ];
      }
      ''
        mkdir -p "$out"
        python3 ${src}/tools/stage_release.py ${docs} release-stage
        tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner \
          -C release-stage -cf - . | gzip -n > "$out/singular-docs-${version}.tar.gz"
        (cd "$out" && sha256sum "singular-docs-${version}.tar.gz" > SHA256SUMS)
      '';

  checker = pkgs.writeShellApplication {
    name = "release-check";
    runtimeInputs = [
      python
      pkgs.actionlint
      pkgs.bash
      pkgs.findutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.jq
      pkgs.coreutils
      pkgs.diffutils
    ];
    text = ''
      python3 ${src}/tools/stage_release.py --selftest
      python3 ${src}/tools/check_release.py ${src} ${archive}
      python3 ${src}/tools/check_publish.py ${src}/tools/publish_docs.sh
      # #695: where each workflow job may run, with the check shown to refuse
      python3 ${src}/tools/check_workflow_runners.py --selftest
      python3 ${src}/tools/check_workflow_runners.py ${src}
      # #695: the programs' Cabal versions follow the release manifest, and the
      # check is shown to refuse each way they can drift
      bash ${src}/tools/cabal_versions.sh check ${src}
      bash ${src}/tools/cabal_versions.test.sh ${src}/tools/cabal_versions.sh ${src}
      bash ${src}/tools/merge_release_bundles.test.sh ${src}/tools/merge_release_bundles.sh ${src}/tools/release_bundles.sh
      actionlint -ignore 'label "nixos" is unknown' ${src}/.github/workflows/*.yml
    '';
  };

  publisher = pkgs.writeShellApplication {
    name = "publish-docs";
    runtimeInputs = [
      pkgs.gh
      pkgs.git
      pkgs.findutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.jq
      pkgs.coreutils
      pkgs.diffutils
    ];
    text = ''
      export DOCS_VERSION=${version}
      export RELEASE_NOTES=${src}/onchain-release/RELEASE.md
      # #695: the step that adds the platform bundles to the release
      export BUNDLES_MERGE=${src}/tools/merge_release_bundles.sh
      export BUNDLES_CONF=${src}/tools/release_bundles.sh
      # Coverage release boundary (issue #80 slice t80c): enforced exactly
      # when the candidate opts in by carrying
      # conformance/coverage/release-required. Candidate-owned
      # configuration, not an environment variable: omitting or unsetting
      # nothing can disable it, and pre-integration trees (without the
      # file) warn and proceed under operator governance. Uses the
      # checkout's own flake so the gate version always matches the tree.
      # Candidate identity and cleanliness are enforced BEFORE consulting
      # the marker: a deleted marker is a dirty tree, and a dirty tree
      # never proceeds — otherwise deleting the working-tree file would
      # silently switch the guard off.
      [[ "$(git -C "$PWD" rev-parse HEAD 2>/dev/null)" == "''${TAG_COMMIT:?publish-docs needs TAG_COMMIT}" ]] \
        || { echo "FAIL: checkout $PWD is not the tag commit $TAG_COMMIT" >&2; exit 1; }
      [[ -z "$(git -C "$PWD" status --porcelain 2>/dev/null)" ]] \
        || { echo "FAIL: dirty or unreadable working tree at $PWD" >&2; exit 1; }
      if [ -f "$PWD/conformance/coverage/release-required" ]; then
        nix run --quiet "$PWD#coverage-gate" -- --root "$PWD" release \
          --candidate "$TAG_COMMIT"
      else
        echo "warning: publish-docs without the coverage release boundary (no conformance/coverage/release-required in $PWD)" >&2
      fi
      # Assemble the on-chain archive (blueprint builds included) and verify
      # the exact bytes to be published before anything is uploaded.
      release_dir="$(mktemp -d)"
      ${pkgs.lib.getExe assembler} "$PWD" ${archive} "$release_dir"
      test -f "$release_dir/singular-onchain-$DOCS_VERSION.tar.gz"
      export DOCS_ARCHIVE="$release_dir"
      ${builtins.readFile ../tools/publish_docs.sh}
    '';
  };
in
{
  inherit
    archive
    checker
    publisher
    releaseArtifacts
    releaseReviewCheck
    ;
  check = pkgs.runCommand "singular-release-check" { nativeBuildInputs = [ publisher ]; } ''
    ${pkgs.lib.getExe checker}
    touch "$out"
  '';
}
