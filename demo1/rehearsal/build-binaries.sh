#!/usr/bin/env bash
# Check the assembled release's sums, extract its on-chain archive, and build the four binaries the play
# runs (singular, open-datum, devnet, singular-negative) from the archive's own flakes, as
# tools/verify_release.sh does. Links them under WORK/bin.
# usage: build-binaries.sh WORK      (WORK/release holds the assembled release)
set -euo pipefail
[ "$#" -eq 1 ] || {
  echo "usage: $0 WORK" >&2
  exit 2
}
work=$1
(cd "$work/release" && sha256sum --check --strict --quiet SHA256SUMS) && echo "sums ok"
rm -rf "$work/verify"
mkdir -p "$work/verify/extracted" "$work/roots" "$work/bin"
archive=$(cd "$work/release" && set -- singular-onchain-*.tar.gz && echo "$1")
tar -xzf "$work/release/$archive" -C "$work/verify/extracted"
extracted="$work/verify/extracted"
(cd "$extracted" && sha256sum --check --strict --quiet SHA256SUMS) && echo "inner sums ok"
printf 'model revision: %s\n' "$(cat "$extracted/MODEL-REVISION")"
# the application's flake reaches the registry through ../../../offchain, which pure evaluation
# allows only inside a git worktree, and the archive carries no .git (as tools/verify_release.sh)
git -C "$extracted" init -q
git -C "$extracted" add -A
git -C "$extracted" -c user.email=rehearsal@local -c user.name=rehearsal -c commit.gpgsign=false commit -qm extracted
build() { # build DIRECTORY ATTRIBUTE BINARY
  (cd "$extracted/$1" && nix build --quiet --out-link "$work/roots/$2" .#"$2")
  ln -sf "$work/roots/$2/bin/$3" "$work/bin/$3"
  [ -x "$work/bin/$3" ] || {
    echo "build-binaries: $2 built no bin/$3" >&2
    exit 1
  }
}
build offchain singular singular
build applications/open-datum/offchain open-datum open-datum
build offchain devnet devnet
build applications/open-datum/offchain singular-negative singular-negative
echo "binaries: singular, open-datum, devnet and singular-negative from the archive flakes"
