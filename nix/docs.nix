{
  pkgs,
  src,
  sharedShell,
  sharedSource,
  mermaidJs,
  offchain,
  conformance,
  onchain,
}:
let
  tools =
    sharedShell.nativeBuildInputs
    ++ sharedShell.buildInputs
    ++ [
      pkgs.python3
      pkgs.just
    ];
  candidateRef = src.rev or (src.dirtyRev or "");
  # The generated off-chain API reference: Haddock runs on the off-chain
  # flake input — this PR's own source tree — and the manifest records that
  # input's source digests beside the generated pages', so the docs checker
  # can prove the reference describes this candidate (a ref label alone is
  # not a freshness witness).
  apiHaddock = offchain.packages.${pkgs.system}.library-haddock;
  # The package-private ownership core's own Haddock tree: the only source
  # of the re-exported Ledger/Provider generated page pairs. The manifest
  # step takes exactly those two pairs from it and nothing else.
  apiReexportHaddock = offchain.packages.${pkgs.system}.node-internal-haddock;
  # The build's own package database: positive evidence for which modules a
  # dependency owns, used to neutralize (never merely unlink) the generated
  # references to dependency documentation this site does not bundle.
  apiPackageDb = offchain.packages.${pkgs.system}.library-haddock.configFiles;
  # The generated Conformance library reference, from this tree's own
  # Conformance input the same way: Haddock runs on the candidate's source,
  # and the manifest binds that source's digests to the generated pages so
  # the checker can prove the reference describes this candidate.
  apiConformanceHaddock = conformance.packages.${pkgs.system}.library-haddock;
  apiConformancePackageDb = conformance.packages.${pkgs.system}.library-haddock.configFiles;
  # The generated Aiken reference for the registry validators, from the
  # pinned compiler of the on-chain flake over this candidate's own
  # onchain/ tree. Its "view source" links are bound to the candidate
  # commit when the build has a clean one, and to main otherwise.
  aikenReference = onchain.packages.${pkgs.system}.aiken-reference;
  # Material fetches Mermaid from unpkg at read time unless `mermaid` is already
  # defined. The shared toolchain pins a copy; serving it from the site keeps
  # every diagram inside the checked, byte-verified build.
  docs = pkgs.stdenvNoCC.mkDerivation {
    pname = "singular-docs";
    version = pkgs.lib.removeSuffix "\n" (builtins.readFile (src + "/version.txt"));
    inherit src;
    nativeBuildInputs = tools;
    DOCS_SHARED_SOURCE = "${sharedSource}";
    MERMAID_JS = "${mermaidJs}";
    buildPhase = ''
      python3 tools/prepare_docs.py
      mkdocs build --strict
      python3 tools/api_reference.py manifest site ${apiHaddock.doc} ${offchain.outPath} ${apiPackageDb} ${apiReexportHaddock.doc}
      python3 tools/api_reference.py manifest --library conformance site ${apiConformanceHaddock.doc} ${conformance.outPath} ${apiConformancePackageDb}
      python3 tools/aiken_reference.py publish site ${aikenReference} onchain ${
        pkgs.lib.escapeShellArg (src.rev or "")
      }
      python3 tools/prepare_release.py site
    '';
    installPhase = ''
      cp -r site "$out"
    '';
  };
  release = import ./release.nix { inherit pkgs src docs; };
  # Test-only publisher for the publication-boundary control (NOTE-024):
  # the UNCHANGED publisher definition above, with only the upload tool
  # replaced by a recorder. Production logic and assembly are intact.
  # The recorder is bash plus coreutils only (no network possible).
  uploadRecorder = pkgs.runCommand "upload-recorder" { } ''
    mkdir -p $out/bin
    cp ${./../conformance/coverage/publication_gh_stub.sh} $out/bin/gh
    chmod +x $out/bin/gh
  '';
  releaseTest = import ./release.nix {
    pkgs = pkgs // {
      gh = uploadRecorder;
    };
    inherit src docs;
  };
  # The published conformance evidence page is recomputed from its committed
  # inputs by the conformance command itself; its controls tamper scratch
  # copies and require each tampering refused.
  evidencePage = conformance.packages.${pkgs.system}.conformance;
  checker = pkgs.writeShellApplication {
    name = "docs-check";
    runtimeInputs = [
      pkgs.python3
      pkgs.bash
      evidencePage
      pkgs.jq
      pkgs.coreutils
      pkgs.diffutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.gnused
    ];
    text = ''
      cd ${src}
      ${pkgs.lib.optionalString (
        candidateRef != ""
      ) "export SINGULAR_CANDIDATE_REF=${pkgs.lib.escapeShellArg candidateRef}"}
      # The generated-site tree under check is overridable for the negative
      # controls; the candidate checkout and its ref binding never move.
      python3 tools/check_site.py "''${SINGULAR_API_SITE_OVERRIDE:-${docs}}"
      python3 tools/aiken_reference.py controls "''${SINGULAR_API_SITE_OVERRIDE:-${docs}}" onchain "''${SINGULAR_CANDIDATE_REF:-}"
      python3 tools/check_presentation_repo.py
      conformance evidence-page --root .
      bash tools/evidence_page_controls.sh .
    '';
  };
  # The staged docs archive must carry the candidate site's generated API
  # pages — member for member, byte for byte — before the unchanged existing
  # release checks run. The archive under check is overridable for the
  # archive negative control; the site it is compared against never moves.
  apiArchiveCheck = pkgs.writeShellApplication {
    name = "api-archive-check";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      python3 ${src}/tools/api_reference.py archive-check "''${SINGULAR_DOCS_ARCHIVE_OVERRIDE:-${release.archive}}" ${docs}
    '';
  };
  releaseCheck = pkgs.writeShellApplication {
    name = "release-check";
    runtimeInputs = [ pkgs.bash ];
    text = ''
      ${pkgs.lib.getExe apiArchiveCheck}
      ${pkgs.lib.getExe release.checker}
    '';
  };
  previewCheck = pkgs.writeShellApplication {
    name = "preview-check";
    runtimeInputs = [ pkgs.python3 ];
    text = ''python3 ${src}/tools/verify_preview.py "$@"'';
  };
  serve = pkgs.writeShellApplication {
    name = "docs-serve";
    runtimeInputs = [ pkgs.python3 ];
    text = ''python3 -m http.server --bind 127.0.0.1 --directory ${docs} "''${1:-8000}"'';
  };
in
{
  inherit docs;
  releaseArchive = release.archive;
  releaseCheck = pkgs.runCommand "singular-release-check" { } ''
    ${pkgs.lib.getExe releaseCheck}
    touch "$out"
  '';
  check = pkgs.runCommand "singular-docs-check" { } ''
    ${pkgs.lib.getExe checker}
    touch "$out"
  '';
  apps = {
    release-check = {
      type = "app";
      program = pkgs.lib.getExe releaseCheck;
    };
    release-artifacts = {
      type = "app";
      program = pkgs.lib.getExe release.releaseArtifacts;
    };
    publish-docs = {
      type = "app";
      program = pkgs.lib.getExe release.publisher;
    };
    publish-docs-boundary-test = {
      type = "app";
      program = pkgs.lib.getExe releaseTest.publisher;
    };
    docs-check = {
      type = "app";
      program = pkgs.lib.getExe checker;
    };
    preview-check = {
      type = "app";
      program = pkgs.lib.getExe previewCheck;
    };
    docs-serve = {
      type = "app";
      program = pkgs.lib.getExe serve;
    };
    default = {
      type = "app";
      program = pkgs.lib.getExe serve;
    };
  };
  shell = pkgs.mkShell {
    inputsFrom = [ sharedShell ];
    packages = [
      pkgs.python3
      pkgs.just
    ];
    DOCS_SHARED_SOURCE = "${sharedSource}";
    MERMAID_JS = "${mermaidJs}";
  };
}
