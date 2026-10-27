{
  pkgs,
  components,
  shell,
  ...
}:
let
  openDatumTestsWrapped = pkgs.writeShellApplication {
    name = "open-datum-tests";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      fixture_dir=$(mktemp -d)
      trap 'rm -rf "$fixture_dir"' EXIT
      mkdir -p "$fixture_dir/test"
      if [ -d "${../test/fixtures}" ]; then
        cp -R "${../test/fixtures}" "$fixture_dir/test/fixtures"
        chmod -R u+w "$fixture_dir/test/fixtures"
      fi
      cd "$fixture_dir"
      ${pkgs.lib.getExe components.tests.open-datum-tests} "$@"
    '';
  };
  unitCheck =
    name: app:
    pkgs.runCommand "${name}-check"
      {
        nativeBuildInputs = [ pkgs.glibcLocales ];
        LANG = "C.UTF-8";
        LC_ALL = "C.UTF-8";
      }
      ''
        ${pkgs.lib.getExe app} > "$out" 2>&1 || { cat "$out"; exit 1; }
      '';
  lintSrc = pkgs.runCommand "open-datum-lint-src" { } ''
    mkdir -p $out/offchain
    cp -r ${../.}/. $out/offchain
    rm -rf $out/offchain/dist-newstyle $out/offchain/result $out/offchain/.git
  '';
in
{
  apps = {
    open-datum-tests = openDatumTestsWrapped;
  };
  open-datum-tests = unitCheck "open-datum-tests" openDatumTestsWrapped;
  lint = pkgs.writeShellApplication {
    name = "lint";
    runtimeInputs = shell.nativeBuildInputs ++ [
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.findutils
    ];
    excludeShellChecks = [
      "SC2046"
      "SC2086"
    ];
    text = ''
      cd "${lintSrc + "/offchain/"}"
      cabal_dirs=$(
        awk '/^[ \t]*hs-source-dirs:/ {
          sub(/^[ \t]*hs-source-dirs:[ \t]*/, "")
          for (i = 1; i <= NF; i++) print $i
        }' open-datum.cabal
      ) || { echo "lint: source discovery failed: cannot read open-datum.cabal (awk exit $?)" >&2; exit 1; }
      [ -n "$cabal_dirs" ] || { echo "lint: source discovery found no hs-source-dirs in open-datum.cabal" >&2; exit 1; }
      dirs=$(
        printf '%s\n' "$cabal_dirs" test
      )
      dirs=$(printf '%s\n' "$dirs" | sort -u)
      [ -n "$dirs" ] || { echo "lint: discovered no source directories" >&2; exit 1; }
      for d in $dirs; do
        [ -d "$d" ] || { echo "lint: declared source directory missing: $d" >&2; exit 1; }
      done
      files=$(find $dirs -name '*.hs' | sort -u)
      [ -n "$files" ] || { echo "lint: no Haskell sources in the discovered extent" >&2; exit 1; }
      fourmolu --config ${../../../../fourmolu.yaml} --ghc-opt=-XImportQualifiedPost -m check $files
      echo "lint inventory: $(printf '%s\n' $files | wc -l) files in $(printf '%s\n' $dirs | wc -l) dirs; fourmolu and hlint over the same files, house fourmolu.yaml, no exclusions" >&2
      hlint $files
    '';
  };
}
