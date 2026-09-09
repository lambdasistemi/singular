{ pkgs, src, sharedShell, sharedSource }:
let
  tools = sharedShell.nativeBuildInputs ++ sharedShell.buildInputs ++ [ pkgs.python3 pkgs.just ];
  docs = pkgs.stdenvNoCC.mkDerivation {
    pname = "singular-docs";
    version = "0.1.0";
    inherit src;
    nativeBuildInputs = tools;
    DOCS_SHARED_SOURCE = "${sharedSource}";
    buildPhase = ''
      python3 tools/prepare_docs.py
      mkdocs build --strict
    '';
    installPhase = ''
      cp -r site "$out"
    '';
  };
  checker = pkgs.writeShellApplication {
    name = "docs-check";
    runtimeInputs = [ pkgs.python3 ];
    text = ''python3 ${src}/tools/check_site.py ${docs}'';
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
  check = pkgs.runCommand "singular-docs-check" { } ''
    ${pkgs.lib.getExe checker}
    touch "$out"
  '';
  apps = {
    docs-check = { type = "app"; program = pkgs.lib.getExe checker; };
    preview-check = { type = "app"; program = pkgs.lib.getExe previewCheck; };
    docs-serve = { type = "app"; program = pkgs.lib.getExe serve; };
    default = { type = "app"; program = pkgs.lib.getExe serve; };
  };
  shell = pkgs.mkShell {
    inputsFrom = [ sharedShell ];
    packages = [ pkgs.python3 pkgs.just ];
    DOCS_SHARED_SOURCE = "${sharedSource}";
  };
}
