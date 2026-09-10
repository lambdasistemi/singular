{ pkgs, src, docs }:
let
  version = pkgs.lib.removeSuffix "\n" (builtins.readFile (src + "/version.txt"));
  python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
  archive = pkgs.runCommand "singular-docs-release-${version}" {
    nativeBuildInputs = [ pkgs.gnutar pkgs.gzip pkgs.coreutils pkgs.python3 ];
  } ''
    mkdir -p "$out"
    python3 ${src}/tools/stage_release.py --selftest
    python3 ${src}/tools/stage_release.py ${docs} release-stage
    tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner \
      -C release-stage -cf - . | gzip -n > "$out/singular-docs-${version}.tar.gz"
    cd "$out"
    sha256sum "singular-docs-${version}.tar.gz" > SHA256SUMS
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
      export DOCS_ARCHIVE=${archive}
      export DOCS_VERSION=${version}
      ${builtins.readFile ../tools/publish_docs.sh}
    '';
  };
in {
  inherit archive checker publisher;
  check = pkgs.runCommand "singular-release-check" { nativeBuildInputs = [ publisher ]; } ''
    ${pkgs.lib.getExe checker}
    touch "$out"
  '';
}
