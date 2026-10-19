# The commit an executable was built from, written into a copy of the built
# executable.
#
# The Haskell build never knows the commit: committing would rebuild the
# whole package. Its executables carry a fixed-width slot
# (Singular.CLI.Version.commitSlot) and this overwrites the slot's payload,
# so the cached build stays untouched, the result is the same executable
# byte for byte apart from the stamp, and `<program> --version` states the
# commit. Used by every flake that offers a packaged command.
{ pkgs }:
{
  exe,
  program,
  commit,
}:
pkgs.runCommand "${program}-stamped"
  {
    nativeBuildInputs = [
      pkgs.coreutils
      pkgs.perl
    ]
    ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
      pkgs.darwin.cctools
      pkgs.darwin.sigtool
    ];
    inherit commit;
    passthru.unstamped = exe;
    meta.mainProgram = program;
  }
  ''
    mkdir -p "$out/bin"
    cp ${exe}/bin/${program} "$out/bin/${program}"
    chmod u+w "$out/bin/${program}"
    perl -0777 -i -pe '
      BEGIN {
        $commit = $ENV{commit};
        die "stamp: the commit must be 1 to 64 characters without # or NUL\n"
          if length($commit) < 1 or length($commit) > 64 or $commit =~ /[#\0]/;
        $payload = $commit . ("#" x (64 - length($commit)));
      }
      $count += s/(SINGULAR-COMMIT-SLOT-V1:)unknown#{57}/$1$payload/g;
      END { die "stamp: expected one commit slot, found $count\n" unless $count == 1 }
    ' "$out/bin/${program}"
    # the stamp changes bytes, never the size
    [ "$(stat -c %s "$out/bin/${program}")" = "$(stat -c %s ${exe}/bin/${program})" ]
    ${pkgs.lib.optionalString pkgs.stdenv.isDarwin ''
      # a changed Mach-O needs its ad-hoc signature again; nixpkgs' own signing
      # helper names the allocator the signing tool spawns and signs a copy
      . ${pkgs.darwin.signingUtils}
      sign "$out/bin/${program}"
    ''}
  ''
