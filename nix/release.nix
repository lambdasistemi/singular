{ pkgs, src, docs }:
let
  version = pkgs.lib.removeSuffix "\n" (builtins.readFile (src + "/version.txt"));
  python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);

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
      pkgs.bash pkgs.coreutils pkgs.findutils pkgs.gnutar pkgs.gzip
      pkgs.jq pkgs.nix python
    ];
    text = ''
      usage() { echo "usage: assemble-onchain-release <repo-root> <docs-dir> <out-dir>" >&2; exit 2; }
      [ "$#" -eq 3 ] || usage
      root="$1"; docs="$2"; out="$3"
      # Each blueprint: built from this checkout's own partition flake, its
      # own lock — the same builds CI's script-identity jobs verify.
      cd "$root"
      mpfs_bp="$(nix build --quiet --no-link --print-out-paths ./onchain#plutus-blueprint)"
      naming_bp="$(nix build --quiet --no-link --print-out-paths ./naming-onchain#plutus-blueprint)"
      python3 "$root/tools/assemble_onchain_release.py" \
        "$root" "$docs" "$mpfs_bp" "$naming_bp" "$out"
      # The full release check — version agreement, archive members, both
      # checksum manifests, release text, and identity verification run from
      # the extracted artifact — against the exact bytes to be published.
      python3 "$root/tools/check_release.py" "$root" "$out"
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

  archive = pkgs.runCommand "singular-docs-release-${version}" {
    nativeBuildInputs = [ pkgs.gnutar pkgs.gzip pkgs.coreutils pkgs.python3 ];
  } ''
    mkdir -p "$out"
    python3 ${src}/tools/stage_release.py --selftest
    python3 ${src}/tools/stage_release.py ${docs} release-stage
    tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner \
      -C release-stage -cf - . | gzip -n > "$out/singular-docs-${version}.tar.gz"
    (cd "$out" && sha256sum "singular-docs-${version}.tar.gz" > SHA256SUMS)
  '';

  checker = pkgs.writeShellApplication {
    name = "release-check";
    runtimeInputs = [ python pkgs.actionlint pkgs.bash pkgs.jq pkgs.coreutils pkgs.diffutils ];
    text = ''
      python3 ${src}/tools/check_release.py ${src} ${archive}
      python3 ${src}/tools/check_publish.py ${src}/tools/publish_docs.sh
      actionlint -ignore 'label "nixos" is unknown' ${src}/.github/workflows/*.yml
    '';
  };

  publisher = pkgs.writeShellApplication {
    name = "publish-docs";
    runtimeInputs = [ pkgs.gh pkgs.git pkgs.jq pkgs.coreutils pkgs.diffutils ];
    text = ''
      export DOCS_VERSION=${version}
      export RELEASE_NOTES=${src}/onchain-release/RELEASE.md
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
in {
  inherit archive checker publisher releaseArtifacts;
  check = pkgs.runCommand "singular-release-check" { nativeBuildInputs = [ publisher ]; } ''
    ${pkgs.lib.getExe checker}
    touch "$out"
  '';
}
