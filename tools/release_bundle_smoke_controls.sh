#!/usr/bin/env bash
# The controls of release_bundle_smoke.sh (#695): each way a bundle can be
# wrong is refused, and for the stated reason, so a green smoke run means the
# checks can fail.
#
# usage: release_bundle_smoke_controls.sh TARBALL VERSION COMMIT
#
# Each control builds a wrong bundle from the given good one (or states the
# wrong expectation), runs the smoke script on it and requires exit 1 with a
# FAIL line naming the check that ought to refuse it.
set -euo pipefail

# a missing tool is a failed setup, never a pass
for tool in tar gzip grep sed find basename tr wc cut head perl mktemp; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "release-bundle-controls: needs $tool on PATH" >&2
    exit 2
  }
done

[ "$#" -eq 3 ] || {
  echo "usage: release_bundle_smoke_controls.sh TARBALL VERSION COMMIT" >&2
  exit 2
}
tarball="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
version="$2"
commit="$3"
smoke="${RELEASE_BUNDLE_SMOKE:-$(cd "$(dirname "$0")" && pwd)/release_bundle_smoke.sh}"
[ -f "$smoke" ] || {
  echo "release-bundle-controls: no smoke script at $smoke" >&2
  exit 2
}
command -v perl >/dev/null 2>&1 || {
  echo "release-bundle-controls: perl is needed to stamp a wrong commit" >&2
  exit 2
}

work="$(mktemp -d "${TMPDIR:-/tmp}/release-bundle-controls.XXXXXX")"
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT

# the good bundle passes: a control that cannot pass proves nothing
bash "$smoke" "$tarball" "$version" "$commit" >"$work/good.out" 2>&1 \
  || {
    echo "release-bundle-controls: FAIL the good bundle is refused: $(grep FAIL "$work/good.out" | head -n 1)"
    exit 1
  }
echo "release-bundle-controls: the good bundle passes"

refused_for() {
  label="$1"
  check="$2"
  shift 2
  if "$@" >"$work/out" 2>&1; then
    echo "release-bundle-controls: FAIL $label was accepted"
    exit 1
  fi
  grep -Eq "FAIL ($check):" "$work/out" || {
    echo "release-bundle-controls: FAIL $label was refused for another reason: $(grep FAIL "$work/out" | head -n 1)"
    exit 1
  }
  echo "release-bundle-controls: $label refused at $check: $(grep -E "FAIL ($check):" "$work/out" | head -n 1 | cut -d: -f3- | cut -c1-110)"
}

other_commit() {
  case "${1:0:1}" in
    0) printf '1%s' "${1:1}" ;;
    *) printf '0%s' "${1:1}" ;;
  esac
}
other="$(other_commit "$commit")"

# the wrong expectation
refused_for "another commit expected" members bash "$smoke" "$tarball" "$version" "$other"
refused_for "another version expected" members bash "$smoke" "$tarball" "0.0.0" "$commit"

# a damaged tarball
size="$(wc -c <"$tarball" | tr -d ' ')"
head -c "$((size / 2))" "$tarball" >"$work/truncated.tar.gz"
refused_for "a truncated tarball" members bash "$smoke" "$work/truncated.tar.gz" "$version" "$commit"

# a member gone
unpack() {
  rm -rf "$work/tree"
  mkdir -p "$work/tree"
  tar -xzf "$tarball" -C "$work/tree"
  chmod -R u+w "$work/tree"
  top="$(ls "$work/tree")"
}
repack() {
  tar -czf "$work/changed.tar.gz" -C "$work/tree" "$top"
}
unpack
rm "$work/tree/$top/bin/open-datum"
repack
refused_for "a bundle without a launcher" members bash "$smoke" "$work/changed.tar.gz" "$version" "$commit"
unpack
rm -rf "$work/tree/$top/share/singular-registry/data"
repack
refused_for "a bundle without the packaged data" members bash "$smoke" "$work/changed.tar.gz" "$version" "$commit"

# a library missing from the bundle, which the loader would find elsewhere
# (in the Nix store, or nowhere): the bundle must not depend on the host
if [ "$(uname -s)" = Linux ]; then
  unpack
  rm "$work/tree/$top/lib/libgmp.so.10"
  repack
  refused_for "a bundle without one of its libraries" 'identity|standalone' bash "$smoke" "$work/changed.tar.gz" "$version" "$commit"
fi

# the scope job builds the bundle for a change to the table of releases (#747),
# read from the pattern the workflow's own `changes` job runs, and not for a
# change that cannot reach a bundle
if [ -n "${RELEASE_BUNDLES_WORKFLOW:-}" ]; then
  pattern="$(sed -n "s/^ *pattern='\\(.*\\)'\$/\\1/p" "$RELEASE_BUNDLES_WORKFLOW")"
  if [ -z "$pattern" ]; then
    echo "release-bundle-controls: SETUP the scope pattern was not read from $RELEASE_BUNDLES_WORKFLOW"
    exit 2
  fi
  printf '%s\n' tools/release_bundle_smoke.sh | grep -Eq "$pattern" || {
    echo "release-bundle-controls: SETUP the scope pattern does not match a path it must match"
    exit 2
  }
  printf '%s\n' offchain/data/contracts/state-contracts.json | grep -Eq "$pattern" || {
    echo "release-bundle-controls: FAIL the scope job does not build the bundle for a change to the table of releases"
    exit 1
  }
  if printf '%s\n' docs/overview.md | grep -Eq "$pattern"; then
    echo "release-bundle-controls: FAIL the scope job builds the bundle for a change to a documentation page"
    exit 1
  fi
  echo "release-bundle-controls: the scope job builds the bundle for a change to the table of releases"
fi

# the development node (#707): the bundles that carry it are held to it, and
# each way it can be wrong is refused for the stated reason. A bundle of an
# older release carries none and is checked as it was published.
# the listing is matched without a pipe: under pipefail, `grep -q` ending a pipe
# early would fail `tar` and make this look like a bundle without the node
listing="$(tar -tzf "$tarball")"
# the table of releases (#728): a bundle that carries it is held to it, and each
# way it can be wrong is refused for the stated reason. A bundle of an older
# release carries none and is checked as it was published.
if [[ "$listing" == *data/contracts/state-contracts.json* ]]; then
  unpack
  rm -r "$work/tree/$top/share/singular-registry/data/contracts"
  repack
  refused_for "a bundle without its table of releases" members bash "$smoke" "$work/changed.tar.gz" "$version" "$commit"
  # the table the bundle carries is the table the source holds (#747): the
  # source table is handed in, a bundle that carries another is refused, and a
  # source that differs from a good bundle is refused for the same reason
  unpack
  cp "$work/tree/$top/share/singular-registry/data/contracts/state-contracts.json" "$work/bundled-table.json"
  RELEASE_BUNDLE_SOURCE_TABLE="$work/bundled-table.json" bash "$smoke" "$tarball" "$version" "$commit" >"$work/out" 2>&1 \
    || {
      echo "release-bundle-controls: FAIL the good bundle is refused beside the table it carries: $(grep FAIL "$work/out" | head -n 1)"
      exit 1
    }
  echo "release-bundle-controls: the good bundle passes beside the table it carries"
  printf ' ' >"$work/source-altered.json"
  cat "$work/bundled-table.json" >>"$work/source-altered.json"
  RELEASE_BUNDLE_SOURCE_TABLE="$work/source-altered.json" refused_for "a bundle beside a source table that differs" table \
    bash "$smoke" "$tarball" "$version" "$commit"
  printf ' ' >>"$work/tree/$top/share/singular-registry/data/contracts/state-contracts.json"
  repack
  RELEASE_BUNDLE_SOURCE_TABLE="$work/bundled-table.json" refused_for "a bundle whose table is not the source's" table \
    bash "$smoke" "$work/changed.tar.gz" "$version" "$commit"
  # the release published without the table is accepted without it, and one after it is not:
  # the rule is read from a copy of the bundle rules with the last release moved
  unpack
  rm -r "$work/tree/$top/share/singular-registry/data/contracts"
  repack
  rules="${RELEASE_BUNDLES_CONF:-$(cd "$(dirname "$smoke")" && pwd)/release_bundles.sh}"
  sed "s/^LAST_WITHOUT_CONTRACT_TABLE=.*/LAST_WITHOUT_CONTRACT_TABLE=\"$version\"/" "$rules" >"$work/rules-without-table.sh"
  sed 's/^LAST_WITHOUT_CONTRACT_TABLE=.*/LAST_WITHOUT_CONTRACT_TABLE="0.0.1"/' "$rules" >"$work/rules-with-table.sh"
  if ! grep -q "^LAST_WITHOUT_CONTRACT_TABLE=\"$version\"\$" "$work/rules-without-table.sh" \
    || ! grep -q '^LAST_WITHOUT_CONTRACT_TABLE="0.0.1"$' "$work/rules-with-table.sh"; then
    echo "release-bundle-controls: SETUP the table rules were not written"
    exit 2
  fi
  RELEASE_BUNDLE_DEVNET=by-version RELEASE_BUNDLES_CONF="$work/rules-without-table.sh" \
    bash "$smoke" "$work/changed.tar.gz" "$version" "$commit" >"$work/out" 2>&1 \
    || {
      echo "release-bundle-controls: FAIL the bundle of the last release published without the table is refused: $(grep FAIL "$work/out" | head -n 1)"
      exit 1
    }
  echo "release-bundle-controls: the bundle of the last release published without the table passes without it"
  refused_for "a bundle without the table of a release after the last published without it" members \
    env RELEASE_BUNDLE_DEVNET=by-version RELEASE_BUNDLES_CONF="$work/rules-with-table.sh" \
    bash "$smoke" "$work/changed.tar.gz" "$version" "$commit"
fi

if [[ "$listing" == */bin/devnet* ]]; then
  # a bundle built from source must carry it, whatever its version says
  unpack
  rm -r "$work/tree/$top/share/devnet"
  repack
  refused_for "a bundle without the genesis files" members env RELEASE_BUNDLE_DEVNET=required bash "$smoke" "$work/changed.tar.gz" "$version" "$commit"
  unpack
  rm "$work/tree/$top/bin/cardano-node" "$work/tree/$top/libexec/cardano-node"
  repack
  refused_for "a bundle without the cardano-node" members env RELEASE_BUNDLE_DEVNET=required bash "$smoke" "$work/changed.tar.gz" "$version" "$commit"
  unpack
  rm "$work/tree/$top/bin/devnet" "$work/tree/$top/libexec/devnet"
  repack
  refused_for "a bundle built from source without the development node" members env RELEASE_BUNDLE_DEVNET=required bash "$smoke" "$work/changed.tar.gz" "$version" "$commit"
  # the blueprint the release ships, and the release number beside it
  unpack
  rm "$work/tree/$top/share/plutus.json"
  repack
  refused_for "a bundle without the blueprint" members env RELEASE_BUNDLE_DEVNET=required bash "$smoke" "$work/changed.tar.gz" "$version" "$commit"
  unpack
  printf '0.0.0\n' >"$work/tree/$top/share/version.txt"
  repack
  refused_for "a blueprint naming another release" members env RELEASE_BUNDLE_DEVNET=required bash "$smoke" "$work/changed.tar.gz" "$version" "$commit"
  # a node that cannot start its chain: the settings are never printed
  unpack
  printf '{ not json' >"$work/tree/$top/share/devnet/genesis/node-config.json"
  repack
  refused_for "a bundle whose node settings are damaged" node env RELEASE_BUNDLE_DEVNET=required bash "$smoke" "$work/changed.tar.gz" "$version" "$commit"
  # a launcher that names another release than the bundle's
  unpack
  OLD="devnet $version" NEW="devnet 0.0.0" perl -0777 -i -pe '
    $n += s/\Q$ENV{OLD}\E/$ENV{NEW}/g;
    END { die "control: expected one name, replaced $n\n" unless $n == 2 }
  ' "$work/tree/$top/bin/devnet"
  repack
  refused_for "a development node launcher naming another release" identity env RELEASE_BUNDLE_DEVNET=required bash "$smoke" "$work/changed.tar.gz" "$version" "$commit"
  if [ "$(uname -s)" = Linux ]; then
    unpack
    rm "$work/tree/$top/lib-node/libgmp.so.10"
    repack
    refused_for "a bundle without one of the node's libraries" 'identity|standalone' env RELEASE_BUNDLE_DEVNET=required bash "$smoke" "$work/changed.tar.gz" "$version" "$commit"
  fi
fi

# an executable that states another commit than the bundle does
unpack
OLD="$commit" NEW="$other" perl -0777 -i -pe '
  $n += s/\Q$ENV{OLD}\E/$ENV{NEW}/g;
  END { die "control: expected one stamp, replaced $n\n" unless $n == 1 }
' "$work/tree/$top/libexec/singular"
repack
refused_for "an executable stamped with another commit" identity bash "$smoke" "$work/changed.tar.gz" "$version" "$commit"

# a machine without a tool the checks need is a failed setup, never a pass
mkdir -p "$work/bin"
for tool in tar gzip grep sed find basename tr wc cut head sort mktemp uname dirname cat rm ls chmod mkdir cp mv printf ld; do
  if path="$(command -v "$tool" 2>/dev/null)"; then ln -sf "$path" "$work/bin/$tool"; fi
done
status=0
env PATH="$work/bin" "$BASH" "$smoke" "$tarball" "$version" "$commit" >"$work/out" 2>&1 || status=$?
if [ "$status" -ne 2 ] || ! grep -q "needs awk" "$work/out"; then
  echo "release-bundle-controls: FAIL a run without awk ended with status $status: $(head -n 1 "$work/out")"
  exit 1
fi
echo "release-bundle-controls: a run without awk is a failed setup (status 2): $(head -n 1 "$work/out")"

echo "release-bundle-controls: PASS"
