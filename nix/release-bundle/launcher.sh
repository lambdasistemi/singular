#!/bin/sh
# @PROGRAM@ from the Singular @VERSION@ release bundle (commit @COMMIT@).
#
# Starts the executable that sits beside this launcher's directory with the
# bundle's own libraries and packaged data, so the program never reads a Nix
# store path or a host library. The executable states its own release and
# commit for --version. Only shell builtins run here, and readlink when the
# launcher is reached through a link.
set -eu

self=$0
# A link to the launcher (for example one placed on PATH) resolves to the
# bundle that holds it.
while [ -L "$self" ]; do
  target=$(readlink "$self")
  case $target in
    /*) self=$target ;;
    *)
      case $self in
        */*) self=${self%/*}/$target ;;
        *) self=$target ;;
      esac
      ;;
  esac
done
case $self in
  */*) directory=${self%/*} ;;
  *) directory=. ;;
esac
here=$(CDPATH='' cd -- "$directory/.." && pwd -P)

singular_registry_datadir=$here/share/singular-registry
export singular_registry_datadir

exec @LOADER@ "$here/libexec/@PROGRAM@" "$@"
