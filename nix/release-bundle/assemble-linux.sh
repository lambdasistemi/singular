# shellcheck shell=bash
# programs, node_program, work and bundle come from the common steps sourced below
# shellcheck disable=SC2154
# The Linux bundle: the executables, the C library's loader and every shared
# library they need, started through the bundled loader. Nothing is read from
# the Nix store or from the host's libraries. The registry's programs share
# lib/; the node, built against another C library, has lib-node/.
set -euo pipefail
# shellcheck source=/dev/null
. "$COMMON"

copy_executables

# bundle_libraries DIRECTORY PROGRAM...: the loader and the libraries the loader
# itself resolves for each program (the exact set it would load at run time,
# found before any rewriting) into the bundle's DIRECTORY, searched from the
# programs and from each other. Sets group_loader to the loader's file name.
bundle_libraries() {
  directory="$1"
  shift
  mkdir -p "$bundle/$directory"
  loader_path=""
  for program in "$@"; do
    this="$(patchelf --print-interpreter "$bundle/libexec/$program")"
    [ -z "$loader_path" ] || [ "$loader_path" = "$this" ] \
      || fail "the executables of $directory use different loaders"
    loader_path="$this"
  done
  group_loader="$(basename "$loader_path")"
  glibc_lib="$(dirname "$loader_path")"
  cp -L "$loader_path" "$bundle/$directory/$group_loader"

  libraries="$work/libraries.$directory"
  : >"$libraries"
  for program in "$@"; do
    "$loader_path" --list "$bundle/libexec/$program" \
      | awk '$2 == "=>" && $3 ~ /^\// { print $1, $3 }' >>"$libraries"
  done
  sort -u "$libraries" -o "$libraries"
  [ -s "$libraries" ] || fail "no shared libraries found for $directory"
  duplicated="$(awk '{ print $1 }' "$libraries" | sort | uniq -d)"
  [ -z "$duplicated" ] || fail "one name resolves to two libraries in $directory: $duplicated"

  while read -r soname path; do
    cp -L "$path" "$bundle/$directory/$soname"
    chmod u+w "$bundle/$directory/$soname"
    # the C library's own files keep the loader's search; the rest search the bundle
    if [ "$(dirname "$path")" != "$glibc_lib" ]; then
      # shellcheck disable=SC2016
      patchelf --set-rpath '$ORIGIN' "$bundle/$directory/$soname"
    fi
  done <"$libraries"

  for program in "$@"; do
    patchelf --set-rpath "\$ORIGIN/../$directory" "$bundle/libexec/$program"
  done
}

# shellcheck disable=SC2086
bundle_libraries lib $programs
loader="$group_loader"
bundle_libraries lib-node "$node_program"
node_loader="$group_loader"

copy_data
copy_genesis
copy_blueprint
write_launchers \
  "\"\$here/lib/$loader\" --library-path \"\$here/lib\"" \
  "\"\$here/lib-node/$node_loader\" --library-path \"\$here/lib-node\""
write_tarball
