#!/usr/bin/env bash
# Negative controls for the documentation guard (#271): a guard that cannot
# fail guards nothing.
#
#   controls.sh CHECK_SH PROJECT_DIR [AIKEN]
#
# PROJECT_DIR is the Aiken project (aiken.toml, validators/, and its staged
# build/packages). The guard must pass the real tree, then refuse copies of it
# with one real gap planted each, found from the guard's own inventory rather
# than named here:
#
#   1. the module doc of a real registry module deleted;
#   2. the doc comment above a real export of that module deleted;
#   3. an undocumented public function added to that module;
#   4. an undocumented module added under registry/;
#   5. an empty extent (no state.ak, no registry/).
#
# Each of 1–4 is refused by the source layer alone. With AIKEN, the reference
# is regenerated with `aiken docs` from each planted tree and the reference
# layer alone (`--reference-only`) must refuse it too; control 5 is refused by
# the source layer and by the reference layer over an empty reference.
set -euo pipefail

check=${1:?usage: controls.sh CHECK_SH PROJECT_DIR [AIKEN]}
project=${2:?usage: controls.sh CHECK_SH PROJECT_DIR [AIKEN]}
aiken=${3:-}
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fresh() {
  rm -rf "$work/p"
  mkdir -p "$work/p"
  cp -r "$project/aiken.toml" "$project/validators" "$work/p/"
  [ -f "$project/aiken.lock" ] && cp "$project/aiken.lock" "$work/p/"
  if [ -n "$aiken" ]; then
    mkdir -p "$work/p/build"
    cp -r "$project/build/packages" "$work/p/build/"
  fi
  chmod -R u+w "$work/p"
}
reference() {
  rm -rf "$work/docs"
  "$aiken" docs -o "$work/docs" "$work/p" >"$work/aiken-docs.log" 2>&1 || {
    echo "CONTROL FAIL: aiken docs did not run on the tree"; cat "$work/aiken-docs.log"; exit 1
  }
}
refused() {
  local layer=$1 name=$2; shift 2
  if out="$(bash "$check" "$@" 2>&1)"; then
    echo "CONTROL FAIL: the $layer layer accepted: $name"; printf '%s\n' "$out"; exit 1
  fi
  echo "control refused by the $layer layer ($name): $(grep -m1 '^FAIL' <<<"$out")"
}
planted() {
  local name=$1
  refused source "$name" "$work/p/validators"
  if [ -n "$aiken" ]; then
    reference
    refused reference "$name" "$work/p/validators" --reference "$work/docs" --reference-only
  fi
}

fresh
bash "$check" "$work/p/validators" >/dev/null || { echo "CONTROL FAIL: the real tree does not pass the source layer"; exit 1; }
if [ -n "$aiken" ]; then
  reference
  bash "$check" "$work/p/validators" --reference "$work/docs" >/dev/null \
    || { echo "CONTROL FAIL: the real tree does not pass the reference layer"; exit 1; }
fi

first_export="$(bash "$check" --list "$work/p/validators" | grep '/registry/' | head -n1)"
[ -n "$first_export" ] || { echo "CONTROL FAIL: no registry export to plant a gap in"; exit 1; }
module="${first_export%%:*}"
rel="${module#"$work"/p/validators/}"
rest="${first_export#*:}"; line="${rest%%:*}"; decl="${rest#*:}"

# 1. Module doc deleted.
sed -i '/^\/\/\/\//d' "$module"
planted "module doc deleted from $rel"

# 2. The doc comment above a real export deleted.
fresh
awk -v n="$line" '{ l[FNR] = $0 } END {
    s = n; while (s > 1 && l[s - 1] ~ /^\/\/\/( |$)/) s--
    if (s == n) exit 1
    for (i = 1; i <= FNR; i++) if (i < s || i >= n) print l[i] }' "$module" > "$work/m"
cp "$work/m" "$module"
planted "doc removed from '$decl' in $rel"

# 3. An undocumented public function added to a real module.
fresh
printf '\npub fn undocumentedControl() -> Bool {\n  True\n}\n' >> "$module"
planted "undocumented export added to $rel"

# 4. An undocumented module added.
fresh
printf 'pub fn undocumentedModuleControl() -> Bool {\n  True\n}\n' > "$work/p/validators/registry/undocumented_control.ak"
planted "undocumented module added"

# 5. Empty extent.
rm -rf "$work/empty"; mkdir -p "$work/empty/validators" "$work/empty/docs"
refused source "empty extent" "$work/empty/validators"
if [ -n "$aiken" ]; then
  refused reference "empty extent" "$work/empty/validators" --reference "$work/empty/docs" --reference-only
fi

echo "aiken-docs controls: every planted gap refused"
