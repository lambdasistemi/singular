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
# (j) a registry-side naming in an onchain/ source file (the S5.1
# extension: the onchain tree names no application either).
# (k) the bound Aiken module spelling application/envelope alone in an
# onchain/ source file (the S5-1d-r1 finding: none of the earlier tokens
# matches it).
# The keri-stub slice adds eighteen plants, each refused with the file
# and the name: a registry file naming the stub word; a registry file
# naming the stub module prefix; the stub cabal depending on the open
# datum; a stub source importing an open-datum module; an open-datum
# file naming the stub tree; the five reach spellings against the stub
# project; the stub script bytes, read from the committed record at run
# time and never typed, in each of the four trees; the stub script
# constant name, read from the same record and never typed, in each of
# the same four trees.
# A temporary-file ownership control runs the check with a
# fault-injection mktemp that delegates twice and then fails: the run
# must fail closed (nonzero) and leave none of the files it created
# behind. The injection is an exported shell function, not a PATH
# shadow: the check binary sets its own PATH, which would bypass a
# shadow directory, while functions take precedence in every child.
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
[ -f "$root/applications/keri-stub/offchain/keri-stub.cabal" ] || {
  echo "application-separation-controls: no applications/keri-stub/offchain/keri-stub.cabal under $root" >&2
  exit 2
}
[ -f "$root/applications/keri-stub/offchain/cabal.project" ] || {
  echo "application-separation-controls: no applications/keri-stub/offchain/cabal.project under $root" >&2
  exit 2
}
[ -f "$root/applications/keri-stub/offchain/script-record.json" ] || {
  echo "application-separation-controls: no applications/keri-stub/offchain/script-record.json under $root" >&2
  exit 2
}
[ -f "$root/naming-onchain/validators/naming.ak" ] || {
  echo "application-separation-controls: no naming-onchain/validators/naming.ak under $root" >&2
  exit 2
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

copy_tree() {
  mkdir -p "$work/$1"
  cp -r "$root/offchain" "$work/$1/offchain"
  rm -rf "$work/$1/offchain/dist-newstyle" "$work/$1/offchain/result" "$work/$1/offchain/.git"
  mkdir -p "$work/$1/onchain"
  cp -r "$root/onchain" "$work/$1/onchain-tmp"
  rm -rf "$work/$1/onchain-tmp/build" "$work/$1/onchain-tmp/result" "$work/$1/onchain-tmp/.git"
  cp -r "$work/$1/onchain-tmp/." "$work/$1/onchain/"
  rm -rf "$work/$1/onchain-tmp"
  mkdir -p "$work/$1/naming-onchain"
  cp -r "$root/naming-onchain" "$work/$1/naming-onchain-tmp"
  rm -rf "$work/$1/naming-onchain-tmp/result" "$work/$1/naming-onchain-tmp/.git"
  cp -r "$work/$1/naming-onchain-tmp/." "$work/$1/naming-onchain/"
  rm -rf "$work/$1/naming-onchain-tmp"
  mkdir -p "$work/$1/applications/open-datum"
  cp -r "$root/applications/open-datum/offchain" "$work/$1/applications/open-datum/offchain"
  cp -r "$root/applications/open-datum/negative" "$work/$1/applications/open-datum/negative"
  mkdir -p "$work/$1/applications/open-datum/onchain"
  cp "$root/applications/open-datum/onchain/permanent-contract.json" "$work/$1/applications/open-datum/onchain/permanent-contract.json"
  mkdir -p "$work/$1/applications/keri-stub"
  cp -r "$root/applications/keri-stub/offchain" "$work/$1/applications/keri-stub/offchain"
  rm -rf "$work/$1/applications/keri-stub/offchain/dist-newstyle" "$work/$1/applications/keri-stub/offchain/result" "$work/$1/applications/keri-stub/offchain/.git"
}

# The stub script bytes, hash and constant names, read from the committed
# record at run time and never typed. Fail closed when the record is
# missing or misshapen: without them the stub plants prove nothing.
stub_record="$root/applications/keri-stub/offchain/script-record.json"
stub_bytes=$(jq -r '.scriptBytesHex' "$stub_record")
stub_hash=$(jq -r '.scriptHashHex' "$stub_record")
[ -n "$stub_bytes" ] && [ "$stub_bytes" != "null" ] || {
  echo "application-separation-controls: cannot read the stub script bytes from $stub_record" >&2
  exit 2
}
[ -n "$stub_hash" ] && [ "$stub_hash" != "null" ] || {
  echo "application-separation-controls: cannot read the stub script hash from $stub_record" >&2
  exit 2
}
mapfile -t stub_names < <(jq -r '.scriptConstantNames[]' "$stub_record")
[ "${#stub_names[@]}" -gt 0 ] || {
  echo "application-separation-controls: no stub script constant names in $stub_record" >&2
  exit 2
}
stub_name="${stub_names[0]}"
[ -n "$stub_name" ] || {
  echo "application-separation-controls: empty stub script constant name" >&2
  exit 2
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
app_hash=$(jq -r '.scripts[] | select(.title == "open_datum.open_datum") | .hash' "$root/applications/open-datum/onchain/permanent-contract.json")
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

# Plant (j): a registry-side naming in an onchain/ source file — the
# S5.1 extension's case. The check must refuse an onchain naming with
# the file, the line and the name.
copy_tree plant-onchain-naming
printf '%s\n' "-- probe: Singular.Application.OpenDatum.Envelope" >>"$work/plant-onchain-naming/onchain/lib/registry_pin.ak"
grep -q 'Singular.Application.OpenDatum.Envelope' "$work/plant-onchain-naming/onchain/lib/registry_pin.ak" \
  || {
    echo "application-separation-controls: onchain-naming plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-onchain-naming" 2>&1); then
  echo "application-separation-controls: check MISSED the planted onchain naming" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q 'Singular.Application.OpenDatum' \
  || {
    echo "application-separation-controls: check failed but did not name the planted module:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
printf '%s\n' "$out" | grep -q 'registry_pin.ak' \
  || {
    echo "application-separation-controls: check failed but did not name the planted file:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
echo "application-separation-controls: planted onchain naming caught" >&2

# Plant (k): the bound Aiken module spelling application/envelope alone in
# an onchain/ source file (S5-1d-r1). None of the earlier tokens matches
# this spelling, so the planted line names only it. The check must refuse
# with the file and the token.
copy_tree plant-onchain-envelope
printf '%s\n' "-- probe: application/envelope" >>"$work/plant-onchain-envelope/onchain/lib/registry_pin.ak"
grep -q 'application/envelope' "$work/plant-onchain-envelope/onchain/lib/registry_pin.ak" \
  || {
    echo "application-separation-controls: onchain-envelope plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-onchain-envelope" 2>&1); then
  echo "application-separation-controls: check MISSED the planted onchain envelope spelling" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q 'application/envelope' \
  || {
    echo "application-separation-controls: check failed but did not name the planted envelope spelling:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
printf '%s\n' "$out" | grep -q 'registry_pin.ak' \
  || {
    echo "application-separation-controls: check failed but did not name the planted file:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
echo "application-separation-controls: planted onchain envelope spelling caught" >&2

# Stub plants (a) to (r): each must be refused with the file and the name.
# The script bytes and the constant name come from the record at run time.

# Plant (stub-a): a registry file naming the stub word.
copy_tree plant-stub-word
printf '%s\n' "-- probe: keri-stub" >>"$work/plant-stub-word/offchain/lib/Singular/Registry/Config.hs"
grep -q 'keri-stub' "$work/plant-stub-word/offchain/lib/Singular/Registry/Config.hs" \
  || {
    echo "application-separation-controls: stub-word plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-stub-word" 2>&1); then
  echo "application-separation-controls: check MISSED the planted stub word" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q 'keri-stub' \
  || {
    echo "application-separation-controls: check failed but did not name the planted stub word:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
printf '%s\n' "$out" | grep -q 'Config.hs' \
  || {
    echo "application-separation-controls: check failed but did not name the planted file:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
echo "application-separation-controls: planted stub word caught" >&2

# Plant (stub-b): a registry file naming the stub module prefix.
copy_tree plant-stub-module
printf '%s\n' "-- probe: Singular.Application.KeriStub.Value" >>"$work/plant-stub-module/offchain/lib/Singular/Registry/Application.hs"
grep -q 'Singular.Application.KeriStub' "$work/plant-stub-module/offchain/lib/Singular/Registry/Application.hs" \
  || {
    echo "application-separation-controls: stub-module plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-stub-module" 2>&1); then
  echo "application-separation-controls: check MISSED the planted stub module" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q 'Singular.Application.KeriStub' \
  || {
    echo "application-separation-controls: check failed but did not name the planted stub module:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
printf '%s\n' "$out" | grep -q 'Application.hs' \
  || {
    echo "application-separation-controls: check failed but did not name the planted file:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
echo "application-separation-controls: planted stub module caught" >&2

# Plant (stub-c): the stub cabal depending on the open datum.
copy_tree plant-stub-dep
sed -i '/^library$/,/^[^ \t]/ s/^\([ \t]*build-depends:\)$/\1\n    , open-datum/' "$work/plant-stub-dep/applications/keri-stub/offchain/keri-stub.cabal"
grep -q '^    , open-datum$' "$work/plant-stub-dep/applications/keri-stub/offchain/keri-stub.cabal" \
  || {
    echo "application-separation-controls: stub-dep plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-stub-dep" 2>&1); then
  echo "application-separation-controls: check MISSED the planted stub dependency" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q 'build-depends' \
  || {
    echo "application-separation-controls: check failed but did not name the planted build-depends entry:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
echo "application-separation-controls: planted stub dependency caught" >&2

# Plant (stub-d): a stub source importing an open-datum module.
copy_tree plant-stub-import
printf '%s\n' "import Singular.Application.OpenDatum.Value" >>"$work/plant-stub-import/applications/keri-stub/offchain/src/Singular/Application/KeriStub/Value.hs"
grep -q 'Singular.Application.OpenDatum.Value' "$work/plant-stub-import/applications/keri-stub/offchain/src/Singular/Application/KeriStub/Value.hs" \
  || {
    echo "application-separation-controls: stub-import plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-stub-import" 2>&1); then
  echo "application-separation-controls: check MISSED the planted stub import" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q 'Singular.Application.OpenDatum' \
  || {
    echo "application-separation-controls: check failed but did not name the planted import:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
printf '%s\n' "$out" | grep -q 'Value.hs' \
  || {
    echo "application-separation-controls: check failed but did not name the planted file:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
echo "application-separation-controls: planted stub import caught" >&2

# Plant (stub-e): an open-datum file naming the stub tree.
copy_tree plant-opendatum-stub-path
printf '%s\n' "-- probe: applications/keri-stub" >>"$work/plant-opendatum-stub-path/applications/open-datum/offchain/src/Singular/Application/OpenDatum/Value.hs"
grep -q 'applications/keri-stub' "$work/plant-opendatum-stub-path/applications/open-datum/offchain/src/Singular/Application/OpenDatum/Value.hs" \
  || {
    echo "application-separation-controls: opendatum-stub-path plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-opendatum-stub-path" 2>&1); then
  echo "application-separation-controls: check MISSED the planted open-datum stub path" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q 'applications/keri-stub' \
  || {
    echo "application-separation-controls: check failed but did not name the planted stub path:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
printf '%s\n' "$out" | grep -q 'Value.hs' \
  || {
    echo "application-separation-controls: check failed but did not name the planted file:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
echo "application-separation-controls: planted open-datum stub path caught" >&2

# Plant (stub-f): relative reach out of the stub tree.
copy_tree plant-stub-reach
printf '%s\n' "  ../../../conformance" >>"$work/plant-stub-reach/applications/keri-stub/offchain/cabal.project"
grep -q 'conformance' "$work/plant-stub-reach/applications/keri-stub/offchain/cabal.project" \
  || {
    echo "application-separation-controls: stub-reach plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-stub-reach" 2>&1); then
  echo "application-separation-controls: check MISSED the planted stub reach" >&2
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
echo "application-separation-controls: planted stub reach caught" >&2

# Plant (stub-g): absolute reach into the repository from the stub project.
copy_tree plant-stub-absolute-reach
printf '%s\n' "  $work/plant-stub-absolute-reach/conformance" >>"$work/plant-stub-absolute-reach/applications/keri-stub/offchain/cabal.project"
grep -q 'conformance' "$work/plant-stub-absolute-reach/applications/keri-stub/offchain/cabal.project" \
  || {
    echo "application-separation-controls: stub-absolute-reach plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-stub-absolute-reach" 2>&1); then
  echo "application-separation-controls: check MISSED the planted stub absolute reach" >&2
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
echo "application-separation-controls: planted stub absolute reach caught" >&2

# Plant (stub-h): absolute reach outside the scratch root from the stub.
copy_tree plant-stub-absolute-outside
mkdir -p "$work/sibling-stub-outside/conformance"
printf '%s\n' "  $work/sibling-stub-outside/conformance" >>"$work/plant-stub-absolute-outside/applications/keri-stub/offchain/cabal.project"
grep -q 'sibling-stub-outside' "$work/plant-stub-absolute-outside/applications/keri-stub/offchain/cabal.project" \
  || {
    echo "application-separation-controls: stub-outside-reach plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-stub-absolute-outside" 2>&1); then
  echo "application-separation-controls: check MISSED the planted stub outside reach" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q 'cabal.project' \
  || {
    echo "application-separation-controls: check failed but did not name the planted cabal.project:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
printf '%s\n' "$out" | grep -q 'sibling-stub-outside' \
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
echo "application-separation-controls: planted stub outside reach caught" >&2

# Plant (stub-i): a bare slash as a stub package path.
copy_tree plant-stub-slash-package
sed -i 's|^  \.\./\.\./\.\./offchain$|&\n  /|' "$work/plant-stub-slash-package/applications/keri-stub/offchain/cabal.project"
grep -q '^  /$' "$work/plant-stub-slash-package/applications/keri-stub/offchain/cabal.project" \
  || {
    echo "application-separation-controls: stub-slash-package plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-stub-slash-package" 2>&1); then
  echo "application-separation-controls: check MISSED the planted stub slash package" >&2
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
echo "application-separation-controls: planted stub slash package caught" >&2

# Plant (stub-j): cd slash in a stub script.
copy_tree plant-stub-cd-root
mkdir -p "$work/plant-stub-cd-root/applications/keri-stub/offchain/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'cd /' >"$work/plant-stub-cd-root/applications/keri-stub/offchain/scripts/cd-root.sh"
grep -q '^cd /$' "$work/plant-stub-cd-root/applications/keri-stub/offchain/scripts/cd-root.sh" \
  || {
    echo "application-separation-controls: stub-cd-root plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-stub-cd-root" 2>&1); then
  echo "application-separation-controls: check MISSED the planted stub cd-root" >&2
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
echo "application-separation-controls: planted stub cd-root caught" >&2

# Plant (stub-k): the stub script bytes in an onchain file.
copy_tree plant-stub-bytes-onchain
printf '%s\n' "-- probe $stub_bytes" >>"$work/plant-stub-bytes-onchain/onchain/lib/registry_pin.ak"
grep -q "$stub_bytes" "$work/plant-stub-bytes-onchain/onchain/lib/registry_pin.ak" \
  || {
    echo "application-separation-controls: stub-bytes-onchain plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-stub-bytes-onchain" 2>&1); then
  echo "application-separation-controls: check MISSED the planted stub bytes in onchain" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q "$stub_bytes" \
  || {
    echo "application-separation-controls: check failed but did not name the planted bytes:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
printf '%s\n' "$out" | grep -q 'registry_pin.ak' \
  || {
    echo "application-separation-controls: check failed but did not name the planted file:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
echo "application-separation-controls: planted stub bytes in onchain caught" >&2

# Plant (stub-l): the stub script bytes in a naming-onchain file.
copy_tree plant-stub-bytes-naming
printf '%s\n' "-- probe $stub_bytes" >>"$work/plant-stub-bytes-naming/naming-onchain/validators/naming.ak"
grep -q "$stub_bytes" "$work/plant-stub-bytes-naming/naming-onchain/validators/naming.ak" \
  || {
    echo "application-separation-controls: stub-bytes-naming plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-stub-bytes-naming" 2>&1); then
  echo "application-separation-controls: check MISSED the planted stub bytes in naming-onchain" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q "$stub_bytes" \
  || {
    echo "application-separation-controls: check failed but did not name the planted bytes:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
printf '%s\n' "$out" | grep -q 'naming.ak' \
  || {
    echo "application-separation-controls: check failed but did not name the planted file:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
echo "application-separation-controls: planted stub bytes in naming-onchain caught" >&2

# Plant (stub-m): the stub script bytes in an offchain file.
copy_tree plant-stub-bytes-offchain
printf '%s\n' "-- probe $stub_bytes" >>"$work/plant-stub-bytes-offchain/offchain/lib/Singular/Registry/Config.hs"
grep -q "$stub_bytes" "$work/plant-stub-bytes-offchain/offchain/lib/Singular/Registry/Config.hs" \
  || {
    echo "application-separation-controls: stub-bytes-offchain plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-stub-bytes-offchain" 2>&1); then
  echo "application-separation-controls: check MISSED the planted stub bytes in offchain" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q "$stub_bytes" \
  || {
    echo "application-separation-controls: check failed but did not name the planted bytes:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
printf '%s\n' "$out" | grep -q 'Config.hs' \
  || {
    echo "application-separation-controls: check failed but did not name the planted file:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
echo "application-separation-controls: planted stub bytes in offchain caught" >&2

# Plant (stub-n): the stub script bytes in an open-datum file.
copy_tree plant-stub-bytes-opendatum
printf '%s\n' "-- probe $stub_bytes" >>"$work/plant-stub-bytes-opendatum/applications/open-datum/offchain/src/Singular/Application/OpenDatum/Value.hs"
grep -q "$stub_bytes" "$work/plant-stub-bytes-opendatum/applications/open-datum/offchain/src/Singular/Application/OpenDatum/Value.hs" \
  || {
    echo "application-separation-controls: stub-bytes-opendatum plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-stub-bytes-opendatum" 2>&1); then
  echo "application-separation-controls: check MISSED the planted stub bytes in open-datum" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q "$stub_bytes" \
  || {
    echo "application-separation-controls: check failed but did not name the planted bytes:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
printf '%s\n' "$out" | grep -q 'Value.hs' \
  || {
    echo "application-separation-controls: check failed but did not name the planted file:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
echo "application-separation-controls: planted stub bytes in open-datum caught" >&2

# Plant (stub-o): the stub constant name in an onchain file.
copy_tree plant-stub-name-onchain
printf '%s\n' "-- probe $stub_name" >>"$work/plant-stub-name-onchain/onchain/lib/registry_pin.ak"
grep -q "$stub_name" "$work/plant-stub-name-onchain/onchain/lib/registry_pin.ak" \
  || {
    echo "application-separation-controls: stub-name-onchain plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-stub-name-onchain" 2>&1); then
  echo "application-separation-controls: check MISSED the planted stub name in onchain" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q "$stub_name" \
  || {
    echo "application-separation-controls: check failed but did not name the planted constant name:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
printf '%s\n' "$out" | grep -q 'registry_pin.ak' \
  || {
    echo "application-separation-controls: check failed but did not name the planted file:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
echo "application-separation-controls: planted stub name in onchain caught" >&2

# Plant (stub-p): the stub constant name in a naming-onchain file.
copy_tree plant-stub-name-naming
printf '%s\n' "-- probe $stub_name" >>"$work/plant-stub-name-naming/naming-onchain/validators/naming.ak"
grep -q "$stub_name" "$work/plant-stub-name-naming/naming-onchain/validators/naming.ak" \
  || {
    echo "application-separation-controls: stub-name-naming plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-stub-name-naming" 2>&1); then
  echo "application-separation-controls: check MISSED the planted stub name in naming-onchain" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q "$stub_name" \
  || {
    echo "application-separation-controls: check failed but did not name the planted constant name:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
printf '%s\n' "$out" | grep -q 'naming.ak' \
  || {
    echo "application-separation-controls: check failed but did not name the planted file:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
echo "application-separation-controls: planted stub name in naming-onchain caught" >&2

# Plant (stub-q): the stub constant name in an offchain file.
copy_tree plant-stub-name-offchain
printf '%s\n' "-- probe $stub_name" >>"$work/plant-stub-name-offchain/offchain/lib/Singular/Registry/Config.hs"
grep -q "$stub_name" "$work/plant-stub-name-offchain/offchain/lib/Singular/Registry/Config.hs" \
  || {
    echo "application-separation-controls: stub-name-offchain plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-stub-name-offchain" 2>&1); then
  echo "application-separation-controls: check MISSED the planted stub name in offchain" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q "$stub_name" \
  || {
    echo "application-separation-controls: check failed but did not name the planted constant name:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
printf '%s\n' "$out" | grep -q 'Config.hs' \
  || {
    echo "application-separation-controls: check failed but did not name the planted file:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
echo "application-separation-controls: planted stub name in offchain caught" >&2

# Plant (stub-r): the stub constant name in an open-datum file.
copy_tree plant-stub-name-opendatum
printf '%s\n' "-- probe $stub_name" >>"$work/plant-stub-name-opendatum/applications/open-datum/offchain/src/Singular/Application/OpenDatum/Value.hs"
grep -q "$stub_name" "$work/plant-stub-name-opendatum/applications/open-datum/offchain/src/Singular/Application/OpenDatum/Value.hs" \
  || {
    echo "application-separation-controls: stub-name-opendatum plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-stub-name-opendatum" 2>&1); then
  echo "application-separation-controls: check MISSED the planted stub name in open-datum" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q "$stub_name" \
  || {
    echo "application-separation-controls: check failed but did not name the planted constant name:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
printf '%s\n' "$out" | grep -q 'Value.hs' \
  || {
    echo "application-separation-controls: check failed but did not name the planted file:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
echo "application-separation-controls: planted stub name in open-datum caught" >&2

# Temporary-file ownership: every list the check acquires registers its
# cleanup before the next acquisition is attempted. A fault-injection
# mktemp delegates twice and then fails, forcing the check to exit
# between its second and third acquisitions; the run must fail closed
# (nonzero — set -e propagates the failed acquisition's status, so no
# specific code is asserted) and leave none of the files it created
# behind. The fault must fire, or the control proves nothing.
fault_state="$work/mktemp-fault"
mkdir -p "$fault_state"
printf '%s\n' '0' >"$fault_state/count"
: >"$fault_state/created.log"
_MKTEMP_FAULT_STATE="$fault_state"
_MKTEMP_FAULT_REAL=$(command -v mktemp) || {
  echo "application-separation-controls: no mktemp on PATH" >&2
  exit 2
}
export _MKTEMP_FAULT_STATE _MKTEMP_FAULT_REAL
# shellcheck disable=SC2329 # exported to the faulted check run below, which invokes it
mktemp() {
  local state="${_MKTEMP_FAULT_STATE:?fault-injection state not set}"
  local real="${_MKTEMP_FAULT_REAL:?real mktemp not set}"
  local n
  read -r n <"$state/count" || n=0
  n=$((n + 1))
  printf '%s\n' "$n" >"$state/count"
  if [ "$n" -le 2 ]; then
    local p
    p=$("$real" "$@") || return 1
    printf '%s\n' "$p" >>"$state/created.log"
    printf '%s\n' "$p"
  else
    echo "mktemp: injected fault (call $n)" >&2
    return 1
  fi
}
export -f mktemp
set +e
out=$("$check" "$root" 2>&1)
fault_status=$?
set -e
unset -f mktemp
unset _MKTEMP_FAULT_STATE _MKTEMP_FAULT_REAL
# Fail-closed, not a specific code: set -e propagates the failed mktemp
# acquisition's own nonzero status, so the assertion is nonzero (a
# run that exits 0 here would be a false clean verdict) plus no
# orphan below. Either failure is the control failing.
[ "$fault_status" -ne 0 ] || {
  echo "application-separation-controls: faulted check exited 0 (must fail closed):" >&2
  printf '%s\n' "$out" >&2
  exit 1
}
[ "$(<"$fault_state/count")" -ge 3 ] || {
  echo "application-separation-controls: mktemp fault never fired (check changed its acquisitions?)" >&2
  exit 2
}
[ -f "$fault_state/created.log" ] || {
  echo "application-separation-controls: fault log missing (harness failure)" >&2
  exit 2
}
# The loop's own status is noise (a missing path is the signal, not a
# failure), so it is discarded; the orphans text below is the verdict.
orphans=$(while IFS= read -r p; do
  [ -n "$p" ] || continue
  [ -e "$p" ] && printf '%s\n' "$p"
done <"$fault_state/created.log") || true
if [ -n "$orphans" ]; then
  echo "application-separation-controls: faulted check left temp files behind:" >&2
  printf '%s\n' "$orphans" >&2
  exit 1
fi
echo "application-separation-controls: faulted temp acquisition leaves no orphan" >&2

# The clean tree passes.
if out=$("$check" "$root" 2>&1); then
  echo "application-separation-controls: clean tree passes" >&2
else
  echo "application-separation-controls: check refused the clean tree:" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi

echo "application-separation-controls: all plants caught, clean tree passes"
