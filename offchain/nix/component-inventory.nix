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
  inherit (pkgs) lib;

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
  builtHere = {
    library = [ "singular-registry" ];
    exes = [
      "local-services-record"
      "cage-test-vectors"
      "journey"
      "insert-active"
      "update-terminal"
      "devnet"
      "deployment"
      # #299: the packaged `singular registry` commands the release
      # archive documents and the demo1-cli-check CI step runs.
      "singular"
      # #389: the read-only Koios probe and fixture recorder.
      "singular-koios"
      # #641: the test-harness tool that seals a devnet key into a vault for
      # the packaged bundle control.
      "vault-seal"
    ];
    tests = [
      "record-value-tests"
      "cage-tests"
      "e2e-tests"
      # #326: the backend contract suite; registry.yml job `contract` runs
      # nix run .#contract-tests and nix run .#contract-external.
      "contract-tests"
    ];
    # #389: the inherited public Koios HTTP client and recorder stay active.
    # Generic ledger evidence, signing, wallet, time and fixed local services
    # have stable public ownership. Shipping composition links koios-http;
    # the old process-global node/indexer runtime is deleted.
    sublibs = [
      "local-services"
      "koios-http"
      # #528 slice 4: the application lives in its own tree; the entry
      # commands moved there and this library names no application.
      "registry-cli"
    ];
  };

  # Each entry carries its own kind and names the job and its verbatim
  # command: a covered-elsewhere component is by definition not in builtHere,
  # so it cannot borrow builtHere's kind lookup.
  coveredElsewhere = [ ];

  unverified = [ ];

  kindOf =
    set: name:
    if lib.elem name set.library then
      "library"
    else if lib.elem name set.exes then
      "exe"
    else if lib.elem name set.tests then
      "test"
    else if lib.elem name set.sublibs then
      "sublib"
    else
      throw "component-inventory: unknown kind for ${name}";

  rows =
    map (name: {
      class = "built-here";
      kind = kindOf builtHere name;
      inherit name;
      detail = "";
    }) (builtHere.library ++ builtHere.exes ++ builtHere.tests ++ builtHere.sublibs)
    ++ map (row: {
      class = "covered-elsewhere";
      inherit (row) kind name;
      detail = "${row.job} :: ${row.command}";
    }) coveredElsewhere
    ++ map (row: {
      class = "unverified";
      inherit (row) kind name;
      detail = "${row.issue} ${row.reason}";
    }) unverified;

  renderRow =
    row:
    lib.concatStringsSep "\t" (
      [
        row.class
        row.kind
        row.name
      ]
      ++ lib.optional (row.detail != "") row.detail
    );

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
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      gnugrep
      diffutils
    ];
    text = ''
      usage() { echo "usage: component-inventory-check <singular-registry.cabal> <manifest>" >&2; exit 2; }
      [ "$#" -eq 2 ] || usage
      cabalFile="$1"; manifestFile="$2"

      # Declared components, straight from the Cabal authority: EVERY
      # column-0 line is examined. Top-level package fields (name:, version:,
      # …) are skipped by their colon; component stanza kinds (case-#
      # insensitive) map to classification kinds — an unnamed `library` is
      # the package library, a named `library` or `sublibrary` is a sublib,
      # plus executable, test-suite, benchmark and foreign-library — and a
      # non-component stanza (common, flag, source-repository, custom-setup,
      # if, else) is skipped. Anything else fails the gate: a stanza kind
      # this parser does not know can never silently join no class.
      declared=$(awk '
        /^[ \t]/ || /^$/ || /^--/ { next }
        /^[a-zA-Z0-9-]+:/ { next }
        {
          keyword = tolower($1)
          if (keyword == "library") {
            if (NF == 1) print "library\tsingular-registry"
            else { sub(/^[^ \t]+[ \t]+/, ""); print "sublib\t" $1 }
          } else if (keyword == "sublibrary" || keyword == "executable" ||
                     keyword == "test-suite" || keyword == "benchmark" ||
                     keyword == "foreign-library") {
            if (keyword == "sublibrary") kind = "sublib"
            else if (keyword == "executable") kind = "exe"
            else if (keyword == "test-suite") kind = "test"
            else if (keyword == "benchmark") kind = "benchmark"
            else kind = "foreign-lib"
            sub(/^[^ \t]+[ \t]+/, "")
            print kind "\t" $1
          } else if (keyword == "common" || keyword == "flag" ||
                     keyword == "source-repository" || keyword == "custom-setup" ||
                     keyword == "if" || keyword == "else") {
            next
          } else {
            print "UNRECOGNIZED-STANZA\t" $0
          }
        }
      ' "$cabalFile" | sort)
      if printf '%s\n' "$declared" | grep -q "^UNRECOGNIZED-STANZA"; then
        echo "component-inventory: unrecognized column-0 stanza header(s) in $cabalFile — extend the recognition set or classify them:" >&2
        printf '%s\n' "$declared" | grep "^UNRECOGNIZED-STANZA" >&2
        exit 1
      fi
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
      unknownKind=$(cut -f2 "$manifestFile" | grep -vxE 'library|sublib|exe|test|benchmark|foreign-lib' || true)
      [ -z "$unknownKind" ] || { echo "component-inventory: unknown component kind(s) in classification rows: $unknownKind" >&2; exit 1; }

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

  memberPaths = [
    components.library
  ]
  ++ map (name: components.exes.${name}) builtHere.exes
  ++ map (name: components.tests.${name}) builtHere.tests
  ++ map (name: components.sublibs.${name}) builtHere.sublibs;
in
{
  inherit memberPaths manifest inventoryGate;
}
