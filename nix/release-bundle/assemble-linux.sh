# shellcheck shell=bash
# programs, work and bundle come from the common steps sourced below
# shellcheck disable=SC2154
# The Linux bundle: the two executables, the C library's loader and every
# shared library they need, started through the bundled loader. Nothing is
# read from the Nix store or from the host's libraries.
set -euo pipefail
# shellcheck source=/dev/null
. "$COMMON"

copy_executables

loader_path=""
for program in $programs; do
  this="$(patchelf --print-interpreter "$bundle/libexec/$program")"
  [ -z "$loader_path" ] || [ "$loader_path" = "$this" ] \
    || fail "the executables use different loaders"
  loader_path="$this"
done
loader="$(basename "$loader_path")"
glibc_lib="$(dirname "$loader_path")"
cp -L "$loader_path" "$bundle/lib/$loader"

# The libraries the loader itself resolves for each executable: the exact
# set it would load at run time, found before any rewriting.
: >"$work/libraries"
for program in $programs; do
  "$loader_path" --list "$bundle/libexec/$program" \
    | awk '$2 == "=>" && $3 ~ /^\// { print $1, $3 }' >>"$work/libraries"
done
sort -u "$work/libraries" -o "$work/libraries"
[ -s "$work/libraries" ] || fail "no shared libraries found"
duplicated="$(awk '{ print $1 }' "$work/libraries" | sort | uniq -d)"
[ -z "$duplicated" ] || fail "one name resolves to two libraries: $duplicated"

while read -r soname path; do
  cp -L "$path" "$bundle/lib/$soname"
  chmod u+w "$bundle/lib/$soname"
  # the C library's own files keep the loader's search; the rest search the bundle
  if [ "$(dirname "$path")" != "$glibc_lib" ]; then
    # shellcheck disable=SC2016
    patchelf --set-rpath '$ORIGIN' "$bundle/lib/$soname"
  fi
done <"$work/libraries"

for program in $programs; do
  # shellcheck disable=SC2016
  patchelf --set-rpath '$ORIGIN/../lib' "$bundle/libexec/$program"
done

copy_data
write_launchers "\"\$here/lib/$loader\" --library-path \"\$here/lib\""
write_tarball
