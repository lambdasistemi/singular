#!/usr/bin/env bash
# Negative and positive controls for the documentation guard (#271): a guard
# that cannot fail guards nothing, and one that fails for the wrong reason
# proves nothing.
#
#   controls.sh CHECK_SH PROJECT_DIR [AIKEN]
#
# PROJECT_DIR is the Aiken project (aiken.toml, validators/, and its staged
# build/packages). The guard must pass the real tree, then refuse copies of it
# with one real gap planted each, found from the guard's own inventory rather
# than named here, each for its intended reason (the FAIL line is matched,
# and a run that did not reach its inventory is not a refusal):
#
#   1. the module doc of a real registry module deleted;
#   2. the doc comment above a real export of that module deleted;
#   3. an undocumented public function added to that module;
#   4. an undocumented module added under registry/;
#   5. an empty extent (no state.ak, no registry/);
#   6. an undocumented public function added to that module INDENTED — legal
#      Aiken the compiler puts on the generated page like any other.
#
# And the guard must accept, with the inventory grown by one on both layers:
#
#   7. the same indented function WITH a doc comment.
#
# With AIKEN, every planted tree is compiled with `aiken docs` and the
# reference layer alone (`--reference-only`) must refuse 1–6 and accept 7.
# Then its reconciliation is exercised directly:
#
#   8. the real source against the reference generated from 7: a member on
#      the page the source inventory does not have;
#   9. the source of 7 against the real reference: a source export missing
#      from the page.
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
  local out=$1
  rm -rf "$out"
  "$aiken" docs -o "$out" "$work/p" >"$work/aiken-docs.log" 2>&1 || {
    echo "CONTROL FAIL: aiken docs did not compile the tree (setup, not a documentation gap)"
    cat "$work/aiken-docs.log"
    exit 1
  }
}
inventory() { grep -o "$1=[0-9]*" <<<"$2" | cut -d= -f2; }
# refused LAYER NAME REASON-REGEX CHECK-ARGS...
refused() {
  local layer=$1 name=$2 reason=$3
  shift 3
  local out
  if out="$(bash "$check" "$@" 2>&1)"; then
    echo "CONTROL FAIL: the $layer layer accepted: $name"
    printf '%s\n' "$out"
    exit 1
  fi
  if ! grep -q '^INVENTORY ' <<<"$out"; then
    echo "CONTROL FAIL: the $layer layer did not reach its inventory on: $name"
    printf '%s\n' "$out"
    exit 1
  fi
  if ! grep -E -q "^FAIL .*($reason)" <<<"$out"; then
    echo "CONTROL FAIL: the $layer layer refused $name for another reason"
    printf '%s\n' "$out"
    exit 1
  fi
  echo "control refused by the $layer layer ($name): $(grep -E -m1 "^FAIL .*($reason)" <<<"$out")"
}
planted() {
  local name=$1 source_reason=$2 reference_reason=$3
  refused source "$name" "$source_reason" "$work/p/validators"
  if [ -n "$aiken" ]; then
    reference "$work/docs"
    refused reference "$name" "$reference_reason" "$work/p/validators" --reference "$work/docs" --reference-only
  fi
}

fresh
real_source="$(bash "$check" "$work/p/validators")" || {
  echo "CONTROL FAIL: the real tree does not pass the source layer"
  exit 1
}
real_exports="$(inventory exports "$real_source")"
[ "${real_exports:-0}" -gt 0 ] || {
  echo "CONTROL FAIL: empty inventory on the real tree"
  exit 1
}
if [ -n "$aiken" ]; then
  reference "$work/real-docs"
  real_reference="$(bash "$check" "$work/p/validators" --reference "$work/real-docs")" \
    || {
      echo "CONTROL FAIL: the real tree does not pass the reference layer"
      printf '%s\n' "$real_reference"
      exit 1
    }
  real_members="$(inventory page_members "$real_reference")"
  [ "${real_members:-0}" -gt 0 ] || {
    echo "CONTROL FAIL: no generated member on the real tree"
    exit 1
  }
fi

first_export="$(bash "$check" --list "$work/p/validators" | grep '/registry/' | head -n1)"
[ -n "$first_export" ] || {
  echo "CONTROL FAIL: no registry export to plant a gap in"
  exit 1
}
module="${first_export%%:*}"
rel="${module#"$work"/p/validators/}"
rest="${first_export#*:}"
line="${rest%%:*}"
decl="${rest#*:}"
name="${decl##* }"

# 1. Module doc deleted.
sed -i '/^\/\/\/\//d' "$module"
planted "module doc deleted from $rel" "module doc lacks" "module doc lacks"

# 2. The doc comment above a real export deleted.
fresh
awk -v n="$line" '{ l[FNR] = $0 } END {
    s = n; while (s > 1 && l[s - 1] ~ /^\/\/\/( |$)/) s--
    if (s == n) exit 1
    for (i = 1; i <= FNR; i++) if (i < s || i >= n) print l[i] }' "$module" >"$work/m"
cp "$work/m" "$module"
planted "doc removed from '$decl' in $rel" "'$decl' has no doc comment" "member '$name' renders no description"

# 3. An undocumented public function added to a real module.
fresh
printf '\npub fn undocumentedControl() -> Bool {\n  True\n}\n' >>"$module"
planted "undocumented export added to $rel" "'pub fn undocumentedControl' has no doc comment" "member 'undocumentedControl' renders no description"

# 4. An undocumented module added.
fresh
printf 'pub fn undocumentedModuleControl() -> Bool {\n  True\n}\n' >"$work/p/validators/registry/undocumented_control.ak"
planted "undocumented module added" "undocumented_control.ak: module doc lacks" "undocumented_control.html: module doc lacks"

# 5. Empty extent.
rm -rf "$work/empty"
mkdir -p "$work/empty/validators" "$work/empty/docs"
refused source "empty extent" "no state.ak" "$work/empty/validators"
if [ -n "$aiken" ]; then
  refused reference "empty extent" "no generated reference page checked" "$work/empty/validators" --reference "$work/empty/docs" --reference-only
fi

# 6. An undocumented public function added to a real module, indented.
fresh
printf '\n  pub fn indentedUndocumentedControl() -> Bool {\n    True\n  }\n' >>"$module"
planted "indented undocumented export added to $rel" "'pub fn indentedUndocumentedControl' has no doc comment" "member 'indentedUndocumentedControl' renders no description"

# 7. The same indented function, documented: accepted, inventory grown by one.
fresh
printf '\n  /// A documented indented control.\n  pub fn indentedDocumentedControl() -> Bool {\n    True\n  }\n' >>"$module"
out="$(bash "$check" "$work/p/validators")" || {
  echo "CONTROL FAIL: the source layer refused a documented indented export"
  printf '%s\n' "$out"
  exit 1
}
[ "$(inventory exports "$out")" -eq $((real_exports + 1)) ] || {
  echo "CONTROL FAIL: the source inventory did not grow by one"
  printf '%s\n' "$out"
  exit 1
}
echo "control accepted by the source layer (documented indented export): exports $real_exports -> $((real_exports + 1))"
if [ -n "$aiken" ]; then
  reference "$work/docs7"
  out="$(bash "$check" "$work/p/validators" --reference "$work/docs7" --reference-only)" \
    || {
      echo "CONTROL FAIL: the reference layer refused a documented indented export"
      printf '%s\n' "$out"
      exit 1
    }
  [ "$(inventory page_members "$out")" -eq $((real_members + 1)) ] || {
    echo "CONTROL FAIL: the page extent did not grow by one"
    printf '%s\n' "$out"
    exit 1
  }
  echo "control accepted by the reference layer (documented indented export): page members $real_members -> $((real_members + 1))"

  # 8. Real source against the reference of 7: an unseen member on the page.
  fresh
  refused reference "page member absent from the source inventory" "member 'indentedDocumentedControl' is on the generated page but not in the source inventory" \
    "$work/p/validators" --reference "$work/docs7" --reference-only

  # 9. The source of 7 against the real reference: an export missing from the page.
  printf '\n  /// A documented indented control.\n  pub fn indentedDocumentedControl() -> Bool {\n    True\n  }\n' >>"$module"
  refused reference "source export absent from the page" "source export 'indentedDocumentedControl' is missing from the generated page" \
    "$work/p/validators" --reference "$work/real-docs" --reference-only
fi

echo "aiken-docs controls: every planted gap refused for its reason; the documented equivalent accepted"
