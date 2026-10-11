#!/usr/bin/env bash
# application-separation-controls: the check catches what it claims to catch.
#
# The controls plant, each in a throwaway copy that mirrors the repository
# layout (registry trees, the onchain contract, the application tree):
# (a) a registry-side naming — a comment containing the module prefix
# Singular.Application.OpenDatum in an offchain/ source file;
# (b) an application-side reach — a relative path to conformance in the
# application's cabal.project;
# (c) a registry build-depends entry on the application package;
# (d) the open-datum script hash itself, read from the contract at run
# time and never typed, in an offchain/ source file;
# (e) an application-side absolute reach — the scratch copy's own absolute
# path to conformance in the application's cabal.project (the 005a1-r1
# finding: an alternative literal spelling of the forbidden destination);
# (f) an application-side absolute reach outside the scratch root — a
# sibling directory beside the checked copy (the 005a1-r2 finding: the old
# check discarded every absolute path outside the checked root);
# (g) the audit checkout's conformance package named by absolute path
# (/code/singular-issue-528-audit/conformance, the 005a1-r1 verdict's user
# story: another checkout's real conformance package);
# (h) `/` as a cabal.project package path, inside the packages: stanza
# where it is a path position rather than prose (the 005a1-r2 finding:
# a slash-only token in a path position is a real outside destination);
# (i) `cd /` in an application script (the same finding for shell
# cd targets).
# The check must refuse each with the right reason (naming the file, the
# line and the name). The controls then run the clean tree through the
# check and require exit 0. They never edit the tracked tree. Each plant
# verifies its own application first: a plant that silently failed to
# apply would report "caught" while testing nothing.
# Exit 0: all plants caught and the clean tree passes. Exit 1: the check
# missed a plant or refused the clean tree. Exit 2: the harness failed.
#
# Usage: application-separation-controls [ROOT] (default: the working tree,
# the repository root).
# Requires $check to name the application-separation-check binary (wired in
# the flake app); a direct run without it exits 2.
set -euo pipefail

root="${1:-$PWD}"
: "${check:?application-separation-controls: \$check is not wired (run through the flake app)}"
[ -x "$check" ] || {
  echo "application-separation-controls: check binary not executable: $check" >&2
  exit 2
}
[ -f "$root/offchain/singular-registry.cabal" ] || {
  echo "application-separation-controls: no offchain/singular-registry.cabal under $root" >&2
  exit 2
}
[ -f "$root/applications/open-datum/offchain/cabal.project" ] || {
  echo "application-separation-controls: no applications/open-datum/offchain/cabal.project under $root" >&2
  exit 2
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

copy_tree() {
  mkdir -p "$work/$1"
  cp -r "$root/offchain" "$work/$1/offchain"
  rm -rf "$work/$1/offchain/dist-newstyle" "$work/$1/offchain/result" "$work/$1/offchain/.git"
  mkdir -p "$work/$1/onchain"
  cp "$root/onchain/permanent-contract.json" "$work/$1/onchain/permanent-contract.json"
  mkdir -p "$work/$1/applications/open-datum"
  cp -r "$root/applications/open-datum/offchain" "$work/$1/applications/open-datum/offchain"
  cp -r "$root/applications/open-datum/negative" "$work/$1/applications/open-datum/negative"
}

# Plant (a): a registry-side naming — the application module prefix in a
# comment in an offchain/ source file.
copy_tree plant-naming
printf '%s\n' "-- probe: Singular.Application.OpenDatum.Envelope" >>"$work/plant-naming/offchain/lib/Singular/Registry/Application.hs"
grep -q 'Singular.Application.OpenDatum.Envelope' "$work/plant-naming/offchain/lib/Singular/Registry/Application.hs" \
  || {
    echo "application-separation-controls: naming plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-naming" 2>&1); then
  echo "application-separation-controls: check MISSED the planted registry-side naming" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q 'Singular.Application.OpenDatum' \
  || {
    echo "application-separation-controls: check failed but did not name the planted module:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
printf '%s\n' "$out" | grep -q 'Application.hs' \
  || {
    echo "application-separation-controls: check failed but did not name the planted file:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
echo "application-separation-controls: planted registry-side naming caught" >&2

# Plant (b): an application-side reach — a path to conformance in the
# application's cabal.project.
copy_tree plant-reach
printf '%s\n' "  ../../../conformance" >>"$work/plant-reach/applications/open-datum/offchain/cabal.project"
grep -q 'conformance' "$work/plant-reach/applications/open-datum/offchain/cabal.project" \
  || {
    echo "application-separation-controls: reach plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-reach" 2>&1); then
  echo "application-separation-controls: check MISSED the planted application-side reach" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q 'cabal.project' \
  || {
    echo "application-separation-controls: check failed but did not name the planted cabal.project:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
printf '%s\n' "$out" | grep -q 'conformance' \
  || {
    echo "application-separation-controls: check failed but did not name the planted reach:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
echo "application-separation-controls: planted application-side reach caught" >&2

# Plant (c): a registry build-depends entry on the application package.
copy_tree plant-dep
sed -i '/^library$/,/^[^ \t]/ s/^\([ \t]*build-depends:\)$/\1\n    , open-datum/' "$work/plant-dep/offchain/singular-registry.cabal"
grep -q '^    , open-datum$' "$work/plant-dep/offchain/singular-registry.cabal" \
  || {
    echo "application-separation-controls: build-depends plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-dep" 2>&1); then
  echo "application-separation-controls: check MISSED the planted build-depends entry" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q 'build-depends' \
  || {
    echo "application-separation-controls: check failed but did not name the planted build-depends entry:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
echo "application-separation-controls: planted build-depends entry caught" >&2

# Plant (d): the open-datum script hash itself in an offchain/ source
# file. Read from the contract at run time, never typed.
copy_tree plant-hash
app_hash=$(jq -r '.scripts[] | select(.title == "open_datum.open_datum") | .hash' "$root/onchain/permanent-contract.json")
[ -n "$app_hash" ] || {
  echo "application-separation-controls: cannot read the open-datum hash" >&2
  exit 2
}
printf '%s\n' "-- probe hash $app_hash" >>"$work/plant-hash/offchain/lib/Singular/Registry/Config.hs"
grep -q "$app_hash" "$work/plant-hash/offchain/lib/Singular/Registry/Config.hs" \
  || {
    echo "application-separation-controls: hash plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-hash" 2>&1); then
  echo "application-separation-controls: check MISSED the planted script hash" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q "$app_hash" \
  || {
    echo "application-separation-controls: check failed but did not name the planted hash:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
echo "application-separation-controls: planted script hash caught" >&2

# Plant (e): an application-side absolute reach — the scratch copy's own
# absolute path to conformance in the application's cabal.project.
copy_tree plant-absolute-reach
printf '%s\n' "  $work/plant-absolute-reach/conformance" >>"$work/plant-absolute-reach/applications/open-datum/offchain/cabal.project"
grep -q 'conformance' "$work/plant-absolute-reach/applications/open-datum/offchain/cabal.project" \
  || {
    echo "application-separation-controls: absolute-reach plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-absolute-reach" 2>&1); then
  echo "application-separation-controls: check MISSED the planted absolute reach" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q 'cabal.project' \
  || {
    echo "application-separation-controls: check failed but did not name the planted cabal.project:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
printf '%s\n' "$out" | grep -q 'conformance' \
  || {
    echo "application-separation-controls: check failed but did not name the planted reach:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
printf '%s\n' "$out" | grep -q 'reach' \
  || {
    echo "application-separation-controls: check failed but did not give the reach reason:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
echo "application-separation-controls: planted absolute reach caught" >&2

# Plant (f): an application-side absolute reach outside the scratch root —
# a sibling directory beside the checked copy.
copy_tree plant-absolute-outside
mkdir -p "$work/sibling-outside/conformance"
printf '%s\n' "  $work/sibling-outside/conformance" >>"$work/plant-absolute-outside/applications/open-datum/offchain/cabal.project"
grep -q 'sibling-outside' "$work/plant-absolute-outside/applications/open-datum/offchain/cabal.project" \
  || {
    echo "application-separation-controls: outside-reach plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-absolute-outside" 2>&1); then
  echo "application-separation-controls: check MISSED the planted outside absolute reach" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q 'cabal.project' \
  || {
    echo "application-separation-controls: check failed but did not name the planted cabal.project:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
printf '%s\n' "$out" | grep -q 'sibling-outside' \
  || {
    echo "application-separation-controls: check failed but did not name the planted outside reach:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
printf '%s\n' "$out" | grep -q 'reach' \
  || {
    echo "application-separation-controls: check failed but did not give the reach reason:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
echo "application-separation-controls: planted outside absolute reach caught" >&2

# Plant (g): the audit checkout's conformance package named by absolute path.
copy_tree plant-absolute-audit
printf '%s\n' "  /code/singular-issue-528-audit/conformance" >>"$work/plant-absolute-audit/applications/open-datum/offchain/cabal.project"
grep -q 'singular-issue-528-audit' "$work/plant-absolute-audit/applications/open-datum/offchain/cabal.project" \
  || {
    echo "application-separation-controls: audit-path plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-absolute-audit" 2>&1); then
  echo "application-separation-controls: check MISSED the planted audit-checkout reach" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q 'cabal.project' \
  || {
    echo "application-separation-controls: check failed but did not name the planted cabal.project:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
printf '%s\n' "$out" | grep -q 'singular-issue-528-audit' \
  || {
    echo "application-separation-controls: check failed but did not name the planted audit reach:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
printf '%s\n' "$out" | grep -q 'reach' \
  || {
    echo "application-separation-controls: check failed but did not give the reach reason:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
echo "application-separation-controls: planted audit-checkout reach caught" >&2

# Plant (h): `/` as a cabal.project package path, inside the packages:
# stanza where it is a path position.
copy_tree plant-slash-package
sed -i 's|^  \.\./\.\./\.\./offchain$|&\n  /|' "$work/plant-slash-package/applications/open-datum/offchain/cabal.project"
grep -q '^  /$' "$work/plant-slash-package/applications/open-datum/offchain/cabal.project" \
  || {
    echo "application-separation-controls: slash-package plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-slash-package" 2>&1); then
  echo "application-separation-controls: check MISSED the planted slash package path" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q 'cabal.project' \
  || {
    echo "application-separation-controls: check failed but did not name the planted cabal.project:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
printf '%s\n' "$out" | grep -q ': /$' \
  || {
    echo "application-separation-controls: check failed but did not name the planted slash path:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
printf '%s\n' "$out" | grep -q 'reach' \
  || {
    echo "application-separation-controls: check failed but did not give the reach reason:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
echo "application-separation-controls: planted slash package path caught" >&2

# Plant (i): `cd /` in an application script.
copy_tree plant-cd-root
mkdir -p "$work/plant-cd-root/applications/open-datum/offchain/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'cd /' >"$work/plant-cd-root/applications/open-datum/offchain/scripts/cd-root.sh"
grep -q '^cd /$' "$work/plant-cd-root/applications/open-datum/offchain/scripts/cd-root.sh" \
  || {
    echo "application-separation-controls: cd-root plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-cd-root" 2>&1); then
  echo "application-separation-controls: check MISSED the planted cd-root reach" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q 'cd-root' \
  || {
    echo "application-separation-controls: check failed but did not name the planted script:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
printf '%s\n' "$out" | grep -q 'reach' \
  || {
    echo "application-separation-controls: check failed but did not give the reach reason:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
echo "application-separation-controls: planted cd-root reach caught" >&2

# The clean tree passes.
if out=$("$check" "$root" 2>&1); then
  echo "application-separation-controls: clean tree passes" >&2
else
  echo "application-separation-controls: check refused the clean tree:" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi

echo "application-separation-controls: all plants caught, clean tree passes"
