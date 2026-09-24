# Issue #264 (epic answer A-005): the classified component inventory.
#
# Every Cabal component the package declares is classified here against the
# live required workflow commands and the shipped registry commands:
#
#   built-here       the carrier builds it (required-workflow consumers,
#                    shipped registry commands, the library, the tests)
#   covered-elsewhere
#                    another required CI job builds it (none today)
#   unverified       declared and exported but not buildable here; the row
#                    names the owning issue and the reason
#
# `component-build` in flake.nix builds exactly the built-here rows; its
# inventory gate (below) re-derives the declared set from the Cabal file at
# build time and fails the carrier on an unclassified new component, a stale
# row naming no declared component, a missing issue/reason, or an empty set.
# A green carrier therefore covers exactly the classified members — never the
# whole package.
{ pkgs, components }:
let
  lib = pkgs.lib;

  # Derived at intake 2026-09-24 from the live workflow commands (see the
  # table in the ticket evidence; every consumer is cited there):
  #   cage-test-vectors  registry.yml:194 just vectors-check -> .#test-vectors
  #   journey            registry.yml:347 nix run .#journey
  #   insert-active      registry.yml:379 release-archive nix run .#insert-active
  #   update-terminal    registry.yml:439 release-archive nix run .#update-terminal
  #   record-value-tests registry.yml:84  nix run .#record-value-tests
  #   cage-tests         registry.yml:414 nix run .#cage-tests
  #   e2e-tests          registry.yml:309 nix run .#cage-tests-e2e
  # plus the supported shipped packages devnet and deployment (issue #102
  # tooling; no D6 record, flake packages). The library is consumed by every
  # component and, across the flake boundary, by the required conformance
  # jobs (conformance/conformance.cabal depends on singular-registry).
  #
  # The seven NYA journey surfaces named in the D6 retirement record
  # (registry.yml:258-269 — li01, li-refusals, lmlc/naming-rows, recovery,
  # retirement with its retained retire-verify exhibit, repair) are
  # classified by CURRENT REQUIRED USE, not compile success (operator note
  # via ticket NOTE-010/011, applying A-008): none has a live required
  # workflow consumer or a flake-closure builder (transitive check in the
  # ticket evidence), so all seven are retained retired journeys under #172,
  # wherever their sources happen to compile today.
  builtHere = {
    library = [ "singular-registry" ];
    exes = [
      "cage-test-vectors"
      "journey"
      "insert-active"
      "update-terminal"
      "devnet"
      "deployment"
    ];
    tests = [
      "record-value-tests"
      "cage-tests"
      "e2e-tests"
    ];
  };

  # Another required CI job building a component none of the rows above
  # covers. Empty today: every workflow-consumed and supported shipped
  # component is in builtHere, so this class stays here to keep the schema
  # complete, and a future entry must name the job and its command.
  coveredElsewhere = [ ];

  # Declared and exported, not built here. The seven D6 journeys are
  # retained retired surfaces under #172 (registry.yml:258-269; re-cut owned
  # by #172 under NYA epic #174); register-rows is NOT D6 and is owned by
  # #283; connected-verifier is owned by #282. Every row keeps its Cabal
  # stanza and flake app; the final epic #278 still lints and formats their
  # source. Evidence class per row: "boundary" names an actual carrier-run
  # component receipt; "source-level" means the single carrier exit is NOT
  # attributed to that component. The local developer gate
  # offchain/deployment-attach-check.sh runs three of these runners and is
  # broken by them — disclosed in the inventory evidence, not a required
  # consumer.
  unverified = [
    {
      kind = "exe";
      name = "recovery-rows";
      issue = "#172";
      reason =
        "D6-retired NYA journey (registry.yml:258-269); journey/recovery/Main.hs imports registerConsumerImpl, removed by 9cba521 (#157); boundary receipt: carrier run at f64ac08 exited 1 here first";
    }
    {
      kind = "exe";
      name = "li01";
      issue = "#172";
      reason =
        "D6-retired NYA journey (registry.yml:258-269); journey/li01/Main.hs sets removed CageConfig fields cfgRepPolicy/cfgConsumerPin (#157); boundary receipt: carrier run at e69dce4 exited 1 here";
    }
    {
      kind = "exe";
      name = "li-refusals";
      issue = "#172";
      reason =
        "D6-retired NYA journey (registry.yml:258-269); journey/li-refusals/Main.hs references identifiers removed by #157 (cfgRepPolicy/cfgConsumerPin class) — source-level evidence, no individual carrier receipt";
    }
    {
      kind = "exe";
      name = "naming-rows";
      issue = "#172";
      reason =
        "D6-retired NYA journey (lmlc; registry.yml:258-269); source currently compiles — retired by current-required-use criterion, unverified for current behavior; no required consumer";
    }
    {
      kind = "exe";
      name = "retirement-rows";
      issue = "#172";
      reason =
        "D6-retired NYA journey (registry.yml:258-269); journey/retirement/Main.hs imports registerConsumerImpl, removed by 9cba521 (#157) — source-level evidence, no individual carrier receipt";
    }
    {
      kind = "exe";
      name = "retirement-verify";
      issue = "#172";
      reason =
        "D6-retired retained exhibit of the retirement journey (registry.yml:258-269); source currently compiles — retired by current-required-use criterion, unverified for current behavior; no required consumer";
    }
    {
      kind = "exe";
      name = "repair-rows";
      issue = "#172";
      reason =
        "D6-retired NYA journey (registry.yml:258-269); journey/repair/Main.hs imports registerConsumerImpl, removed by 9cba521 (#157) — source-level evidence, no individual carrier receipt";
    }
    {
      kind = "exe";
      name = "register-rows";
      issue = "#283";
      reason =
        "not on the D6 retired list; #283 owns its migration or retirement; journey/register/Main.hs imports registerConsumerImpl, removed by 9cba521 (#157) — source-level evidence, no individual carrier receipt";
    }
    {
      kind = "exe";
      name = "connected-verifier";
      issue = "#282";
      reason =
        "imports the removed stateRepPolicyBytes accessor and expects the removed representative-policy blueprint; not buildable at this revision, repair owned by #282, no required workflow consumes it";
    }
  ];

  kindOf =
    set: name:
    if lib.elem name set.library then "library"
    else if lib.elem name set.exes then "exe"
    else if lib.elem name set.tests then "test"
    else throw "component-inventory: unknown kind for ${name}";

  rows =
    map (name: {
      class = "built-here";
      kind = kindOf builtHere name;
      inherit name;
      detail = "";
    }) (builtHere.library ++ builtHere.exes ++ builtHere.tests)
    ++ map (name: {
      class = "covered-elsewhere";
      kind = kindOf builtHere name;
      inherit name;
      detail = "";
    }) coveredElsewhere
    ++ map (row: {
      class = "unverified";
      inherit (row) kind name;
      detail = "${row.issue} ${row.reason}";
    }) unverified;

  renderRow = row: lib.concatStringsSep "\t" ([ row.class row.kind row.name ] ++ lib.optional (row.detail != "") row.detail);

  manifest = pkgs.writeText "component-build-manifest" (
    lib.concatStringsSep "\n" (map renderRow rows) + "\n"
  );

  # The executable inventory gate. Quantified: the declared set is awk-extracted
  # from the Cabal file itself, so a newly declared component is caught without
  # anyone editing this file; the guard set (every declared component classified,
  # every row naming a declared component, unverified rows carrying issue and
  # reason, non-empty declared/built-here sets) is asserted at carrier build
  # time, not by inspection.
  checker = pkgs.writeShellApplication {
    name = "component-inventory-check";
    runtimeInputs = with pkgs; [ coreutils gawk gnugrep diffutils ];
    text = ''
      usage() { echo "usage: component-inventory-check <singular-registry.cabal> <manifest>" >&2; exit 2; }
      [ "$#" -eq 2 ] || usage
      cabalFile="$1"; manifestFile="$2"

      # Declared components, straight from the Cabal authority. Column-0
      # stanza headers only; comments and indented fields never match.
      declared=$(awk '
        /^--/ { next }
        /^library[ \t]*$/        { print "library\tsingular-registry"; next }
        /^executable[ \t]+/      { sub(/^executable[ \t]+/, ""); print "exe\t" $1; next }
        /^test-suite[ \t]+/      { sub(/^test-suite[ \t]+/, ""); print "test\t" $1; next }
      ' "$cabalFile" | sort)
      [ -n "$declared" ] || { echo "component-inventory: no components declared in $cabalFile — refusing an empty derivation" >&2; exit 1; }
      declaredCount=$(printf '%s\n' "$declared" | wc -l)

      [ -s "$manifestFile" ] || { echo "component-inventory: classification manifest is empty — refusing an empty derivation" >&2; exit 1; }
      classified=$(cut -f2-3 "$manifestFile" | sort)
      classifiedCount=$(printf '%s\n' "$classified" | wc -l)

      # Fail closed both ways: a newly declared component with no row, and a
      # row naming nothing declared.
      unclassified=$(comm -23 <(printf '%s\n' "$declared") <(printf '%s\n' "$classified"))
      [ -z "$unclassified" ] || { echo "component-inventory: declared component(s) without a classification row — classify or remove them:" >&2; printf '%s\n' "$unclassified" >&2; exit 1; }
      stale=$(comm -13 <(printf '%s\n' "$declared") <(printf '%s\n' "$classified"))
      [ -z "$stale" ] || { echo "component-inventory: classification row(s) naming no declared component:" >&2; printf '%s\n' "$stale" >&2; exit 1; }

      # The carrier must build a non-empty supported set, and every unverified
      # row must name its issue and reason.
      builtHereRows=$(awk -F'\t' '$1 == "built-here" { print $2 "\t" $3 }' "$manifestFile")
      [ -n "$builtHereRows" ] || { echo "component-inventory: no built-here member — refusing an empty derivation" >&2; exit 1; }
      badRows=$(awk -F'\t' '$1 == "unverified" && ($4 == "" || $4 !~ /#/) { print $2 "\t" $3 }' "$manifestFile")
      [ -z "$badRows" ] || { echo "component-inventory: unverified row(s) missing an issue/reason:" >&2; printf '%s\n' "$badRows" >&2; exit 1; }
      unknownClass=$(cut -f1 "$manifestFile" | grep -vxE 'built-here|covered-elsewhere|unverified' || true)
      [ -z "$unknownClass" ] || { echo "component-inventory: unknown classification class(es): $unknownClass" >&2; exit 1; }

      builtCount=$(printf '%s\n' "$builtHereRows" | wc -l)
      echo "component-inventory: $declaredCount declared, $builtCount built here, $((classifiedCount - builtCount)) not built by this carrier (unverified rows carry issue+reason)"
    '';
  };

  # Runs the gate against the Cabal file and the rendered manifest as part of
  # the component-build closure: a failure here fails `nix build
  # .#component-build` itself. The manifest ships in the carrier output so
  # the published classification travels with the artifact.
  inventoryGate = pkgs.runCommand "component-inventory-gate" { } ''
    ${lib.getExe checker} ${../singular-registry.cabal} ${manifest}
    mkdir -p "$out/share"
    install -m 0444 ${manifest} "$out/share/component-build-manifest"
  '';

  memberPaths =
    [ components.library ]
    ++ map (name: components.exes.${name}) builtHere.exes
    ++ map (name: components.tests.${name}) builtHere.tests;
in
{
  inherit memberPaths manifest inventoryGate;
}
