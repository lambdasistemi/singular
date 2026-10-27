# The open-datum application's classified component inventory.
#
# Every Cabal component the open-datum package declares is classified here
# against the live required workflow commands:
#
#   built-here       the carrier builds it (the application's library,
#                    executables and tests)
#   covered-elsewhere
#                    another required CI job builds it (none today)
#   unverified       declared and exported but not buildable here; the row
#                    names the owning issue and the reason
#
# `component-build` in flake.nix builds exactly the built-here rows; its
# inventory gate re-derives the declared set from the application's Cabal
# files at build time and fails the carrier on an unclassified new
# component, a stale row, a missing issue/reason, or an empty set.
{ pkgs, components }:
let
  inherit (pkgs) lib;

  builtHere = {
    library = [ "open-datum" ];
    exes = [
      "open-datum"
      # #730: the test-only harness of the forged-pins journey; no release
      # archive carries it.
      "forged-registry"
      # #742: the test-only harness of the refusals journey; no release
      # archive carries it.
      "no-pin-refusals"
    ];
    tests = [
      "open-datum-tests"
    ];
    sublibs = [ ];
  };

  coveredElsewhere = [ ];

  unverified = [ ];

  rows = [
    {
      class = "built-here";
      kind = "library";
      name = "open-datum";
      detail = "";
    }
    {
      class = "built-here";
      kind = "exe";
      name = "open-datum";
      detail = "";
    }
    {
      class = "built-here";
      kind = "exe";
      name = "forged-registry";
      detail = "";
    }
    {
      class = "built-here";
      kind = "exe";
      name = "no-pin-refusals";
      detail = "";
    }
    {
      class = "built-here";
      kind = "test";
      name = "open-datum-tests";
      detail = "";
    }
  ]
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

  manifest = pkgs.writeText "open-datum-component-build-manifest" (
    lib.concatStringsSep "\n" (map renderRow rows) + "\n"
  );

  checker = pkgs.writeShellApplication {
    name = "open-datum-component-inventory-check";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      gnugrep
      diffutils
    ];
    text = ''
      usage() { echo "usage: open-datum-component-inventory-check <open-datum.cabal> <manifest>" >&2; exit 2; }
      [ "$#" -eq 2 ] || usage
      cabalFile="$1"; manifestFile="$2"

      declared_of() {
        awk '
          /^[ \t]/ || /^$/ || /^--/ { next }
          /^[a-zA-Z0-9-]+:/ { next }
          {
            keyword = tolower($1)
            if (keyword == "library") {
              if (NF == 1) print "library\topen-datum"
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
        ' "$1" | sort
      }

      declared="$(declared_of "$cabalFile" | sort -u)"
      if printf '%s\n' "$declared" | grep -q "^UNRECOGNIZED-STANZA"; then
        echo "component-inventory: unrecognized column-0 stanza header(s) — extend the recognition set or classify them:" >&2
        printf '%s\n' "$declared" | grep "^UNRECOGNIZED-STANZA" >&2
        exit 1
      fi
      [ -n "$declared" ] || { echo "component-inventory: no components declared — refusing an empty derivation" >&2; exit 1; }
      declaredCount=$(printf '%s\n' "$declared" | wc -l)

      [ -s "$manifestFile" ] || { echo "component-inventory: classification manifest is empty — refusing an empty derivation" >&2; exit 1; }
      classified=$(cut -f2-3 "$manifestFile" | sort)
      classifiedCount=$(printf '%s\n' "$classified" | wc -l)

      unclassified=$(comm -23 <(printf '%s\n' "$declared") <(printf '%s\n' "$classified"))
      [ -z "$unclassified" ] || { echo "component-inventory: declared component(s) without a classification row — classify or remove them:" >&2; printf '%s\n' "$unclassified" >&2; exit 1; }
      stale=$(comm -13 <(printf '%s\n' "$declared") <(printf '%s\n' "$classified"))
      [ -z "$stale" ] || { echo "component-inventory: classification row(s) naming no declared component:" >&2; printf '%s\n' "$stale" >&2; exit 1; }

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

  inventoryGate = pkgs.runCommand "open-datum-component-inventory-gate" { } ''
    ${lib.getExe checker} ${../open-datum.cabal} ${manifest}
    mkdir -p "$out/share"
    install -m 0444 ${manifest} "$out/share/open-datum-component-build-manifest"
  '';

  memberPaths = [
    components.library
  ]
  ++ map (name: components.exes.${name}) builtHere.exes
  ++ map (name: components.tests.${name}) builtHere.tests;

in
{
  inherit memberPaths manifest inventoryGate;
}
