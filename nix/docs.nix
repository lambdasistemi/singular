{ pkgs, src, sharedShell, sharedSource, mermaidJs }:
let
  tools = sharedShell.nativeBuildInputs ++ sharedShell.buildInputs ++ [ pkgs.python3 pkgs.just ];
  candidateRef = src.rev or (src.dirtyRev or "");
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
  uploadRecorder = pkgs.runCommand "upload-recorder" {} ''
    mkdir -p $out/bin
    cp ${./../conformance/coverage/publication_gh_stub.sh} $out/bin/gh
    chmod +x $out/bin/gh
  '';
  releaseTest = import ./release.nix {
    pkgs = pkgs // { gh = uploadRecorder; };
    inherit src docs;
  };
  checker = pkgs.writeShellApplication {
    name = "docs-check";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      cd ${src}
      ${pkgs.lib.optionalString (candidateRef != "") "export SINGULAR_CANDIDATE_REF=${pkgs.lib.escapeShellArg candidateRef}"}
      python3 tools/check_site.py ${docs}
      python3 tools/check_presentation_repo.py
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
in {
  inherit docs;
  releaseArchive = release.archive;
  releaseCheck = release.check;
  check = pkgs.runCommand "singular-docs-check" { } ''
    ${pkgs.lib.getExe checker}
    touch "$out"
  '';
  apps = {
    release-check = { type = "app"; program = pkgs.lib.getExe release.checker; };
    release-artifacts = { type = "app"; program = pkgs.lib.getExe release.releaseArtifacts; };
    publish-docs = { type = "app"; program = pkgs.lib.getExe release.publisher; };
    publish-docs-boundary-test = { type = "app"; program = pkgs.lib.getExe releaseTest.publisher; };
    docs-check = { type = "app"; program = pkgs.lib.getExe checker; };
    preview-check = { type = "app"; program = pkgs.lib.getExe previewCheck; };
    docs-serve = { type = "app"; program = pkgs.lib.getExe serve; };
    default = { type = "app"; program = pkgs.lib.getExe serve; };
  };
  shell = pkgs.mkShell {
    inputsFrom = [ sharedShell ];
    packages = [ pkgs.python3 pkgs.just ];
    DOCS_SHARED_SOURCE = "${sharedSource}";
    MERMAID_JS = "${mermaidJs}";
  };
}
