{ pkgs }:
let
  inherit (pkgs) lib;
  root = ./..;
  table = builtins.fromJSON (builtins.readFile ./result-cache/classification.json);
  # Marker-format version: the only knob that moves every identity without
  # touching a test input. Bump it when the marker body gains a field
  # (v2 adds the wrapped command and its hash to the pin name and body).
  markerVersion = "2";
  isInputFor = family: e: e.class == "input" && builtins.elem family (e.families or [ ]);
  pathOf = e: root + "/${e.path}";
  sharedEntries = builtins.filter (isInputFor "negative-host-pair") table.entries;
  mutantExtraEntries = builtins.filter (
    e: isInputFor "negative-host-mutant" e && !(isInputFor "negative-host-pair" e)
  ) table.entries;
  sharedFileset = lib.fileset.unions (map pathOf sharedEntries);
  mutantExtraFileset = lib.fileset.unions (map pathOf mutantExtraEntries);
  # Setup-only files travel with the setup but stay outside the identity:
  # subtract them even where an input directory physically contains them
  # (specs/299-singular-cli/spec.md under specs/).
  setupFileset = lib.fileset.unions (
    map pathOf (builtins.filter (e: e.class == "setup-only") table.entries)
  );
  # The pair leg never reads the mutant extras: subtract them even where a
  # shared directory physically contains them.
  pairFileset = lib.fileset.difference (lib.fileset.difference sharedFileset mutantExtraFileset) setupFileset;
  mutantFileset = lib.fileset.difference (lib.fileset.unions [
    sharedFileset
    mutantExtraFileset
  ]) setupFileset;
  nh = import ./negative-host.nix { inherit pkgs; };
  # A derivation per family over exactly the inputs: the lib.fileset source
  # of the input files, the store paths of the wrapped apps (script text
  # plus tool closure), and the marker-format version. Read with
  # nix eval --raw as the output path hash; never built.
  mkIdentity =
    name: family: fileset: programs:
    pkgs.runCommand name
      {
        src = lib.fileset.toSource {
          inherit root fileset;
        };
        version = markerVersion;
        programs = builtins.concatStringsSep "\n" programs;
        passAsFile = [ ];
      }
      ''
        mkdir -p "$out"
        printf '%s\n' "$version" >"$out/marker-version"
        printf '%s\n' "${family}" >"$out/family"
        printf '%s\n' "$programs" >"$out/programs"
        printf '%s\n' "$src" >"$out/src"
      '';
  identities = {
    result-cache-identity-pair =
      mkIdentity "result-cache-identity-negative-host-pair" "negative-host-pair" pairFileset
        [
          nh."negative-host-part".program
        ];
    result-cache-identity-mutant =
      mkIdentity "result-cache-identity-negative-host-mutant" "negative-host-mutant" mutantFileset
        [
          nh."negative-host-mutants".program
          nh."negative-host-part".program
        ];
  };
  resultCache = pkgs.writeShellApplication {
    name = "result-cache";
    runtimeInputs = with pkgs; [
      bash
      cachix
      coreutils
      curl
      gnugrep
      jq
      nix
    ];
    text = ''
      exec bash ${./../tools/result_cache_run.sh} "$@"
    '';
  };
  resultCacheControls = pkgs.writeShellApplication {
    name = "result-cache-controls";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      git
      gnugrep
      jq
      nix
    ];
    text = ''
      result_cache=${lib.getExe resultCache} bash ${./../tools/result_cache_controls.sh} "$@"
    '';
  };
in
{
  apps = {
    result-cache = {
      type = "app";
      program = lib.getExe resultCache;
    };
    result-cache-controls = {
      type = "app";
      program = lib.getExe resultCacheControls;
    };
  };
  inherit identities;
}
