# shellcheck shell=bash
# programs, node_program, work and bundle come from the common steps sourced below
# shellcheck disable=SC2154
# The macOS bundle: the executables and every non-system dynamic library
# they need, load paths rewritten to the bundle, each file signed ad hoc (an
# Apple Silicon kernel refuses unsigned code, and rewriting a load path
# invalidates the signature). System libraries stay where macOS provides them.
# The registry's programs share lib/; the node has lib-node/, so a library the
# two were built with in different versions never collides.
set -euo pipefail
# shellcheck source=/dev/null
. "$COMMON"

# nixpkgs' signing helper: names the allocator the signing tool spawns and
# signs a copy of a file whose signature the load-path rewrite left unusable
# shellcheck source=/dev/null
. "$SIGNING_UTILS"

copy_executables

# The libraries a file loads that macOS does not provide: everything outside
# /usr/lib and /System, and not already a relative load path.
non_system_loads() {
  otool -L "$1" | awk 'NR > 1 { print $1 }' | while IFS= read -r library; do
    case "$library" in
      "" | /usr/lib/* | /System/* | @*) ;;
      *) printf '%s\n' "$library" ;;
    esac
  done
}

enqueue() {
  if ! grep -Fxq "$1" "$seen"; then
    printf '%s\n' "$1" >>"$seen"
    printf '%s\n' "$1" >>"$queue"
  fi
}

# Point every non-system load of $1 at $2/<file name>, queueing the library.
rewrite_loads() {
  binary="$1"
  prefix="$2"
  own_id="${3:-}"
  # the listing is read in full before the file is changed under it
  loads="$(non_system_loads "$binary")"
  for library in $loads; do
    [ "$library" = "$own_id" ] && continue
    enqueue "$library"
    install_name_tool -change "$library" "$prefix/$(basename "$library")" "$binary"
  done
}

# bundle_libraries DIRECTORY PROGRAM...: every non-system library the programs
# load, transitively, into the bundle's DIRECTORY, with the programs and the
# libraries pointed at it.
bundle_libraries() {
  directory="$1"
  shift
  mkdir -p "$bundle/$directory"
  queue="$work/dylib-queue.$directory"
  seen="$work/dylib-seen.$directory"
  : >"$queue"
  : >"$seen"

  for program in "$@"; do
    binary="$bundle/libexec/$program"
    # Run-path entries into the Nix store mean nothing outside it.
    rpaths="$(otool -l "$binary" | awk '$1 == "cmd" && $2 == "LC_RPATH" { found = 1; next } found && $1 == "path" { print $2; found = 0 }')"
    for entry in $rpaths; do
      install_name_tool -delete_rpath "$entry" "$binary"
    done
    rewrite_loads "$binary" "@executable_path/../$directory"
  done

  while [ -s "$queue" ]; do
    library="$(head -n 1 "$queue")"
    tail -n +2 "$queue" >"$queue.next"
    mv "$queue.next" "$queue"
    target="$bundle/$directory/$(basename "$library")"
    if [ ! -f "$target" ]; then
      cp -L "$library" "$target"
      chmod u+w "$target"
      printf '%s\n' "$library" >"$work/origin.$directory.$(basename "$library")"
    elif [ "$(cat "$work/origin.$directory.$(basename "$library")")" != "$library" ]; then
      # the same file name from two places is two libraries in one directory
      cmp -s "$library" "$(cat "$work/origin.$directory.$(basename "$library")")" \
        || fail "one name resolves to two libraries in $directory: $library and $(cat "$work/origin.$directory.$(basename "$library")")"
    fi
    install_name_tool -id "@loader_path/$(basename "$library")" "$target"
    rewrite_loads "$target" "@loader_path" "$library"
  done
}

# shellcheck disable=SC2086
bundle_libraries lib $programs
bundle_libraries lib-node "$node_program"

# What is left must be a system library or a path inside the bundle.
for file in "$bundle"/libexec/* "$bundle"/lib/* "$bundle"/lib-node/*; do
  leftover="$(non_system_loads "$file")"
  [ -z "$leftover" ] || fail "$file still loads: $leftover"
  # the run paths were deleted, so a load through one can no longer resolve
  unresolved="$(otool -L "$file" | awk 'NR > 1 { print $1 }' | grep '^@rpath/' || true)"
  [ -z "$unresolved" ] || fail "$file loads through a run path the bundle does not carry: $unresolved"
  sign "$file"
done

copy_data
copy_genesis
write_launchers "" ""
write_tarball
