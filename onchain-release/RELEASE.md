Singular is a registry of unique keys on Cardano that applications can use with
their own rules. This release carries ready-built commands for Linux and macOS,
the compiled smart contracts and the sources they are built from. Demo 1 creates
a registry, inserts a key, changes it, terminates it and shows each refusal where
it should appear; it is played from singular-demo, on a private development node.

## Get the commands

Download the file for your machine and `SHA256SUMS` from this release:

- `singular-<version>-x86_64-linux.tar.gz` for Linux on x86_64;
- `singular-<version>-aarch64-darwin.tar.gz` for a Mac with Apple Silicon.

Check the file against `SHA256SUMS`, unpack it and run `singular --version`,
which prints the release and the commit the program was built from. Each file
holds `singular` and `open-datum` with everything they need: no Nix and no
compiling. The
[install page](https://lambdasistemi.github.io/singular/docs/install/) has the
commands for each platform.

## Play Demo 1

1. Get the programs and a private development node from the Demo 1 shell,
   https://github.com/lambdasistemi/singular-demo.
   `nix develop github:lambdasistemi/singular-demo --accept-flake-config` opens a
   shell with `singular`, `open-datum`, the development node and `jq`, all built
   by the project's CI. It needs Nix; its README says what it is pinned to.
2. Open the step-by-step page, https://lambdasistemi.github.io/singular-demo/, and
   follow it. It plays the sixteen steps on the private development node with no
   faucet and no account.

## Check this release

1. Download `singular-onchain-<version>.tar.gz` and `SHA256SUMS` from this
   release. The documentation archive is 220 MB and is not needed for the check.
   Check the download: `sha256sum --check --ignore-missing SHA256SUMS`. The file
   names carry the version without a `v`.
2. Extract the archive into a directory of its own, because it has no top-level
   directory and carries a `SHA256SUMS` of the same name:
   `mkdir singular && tar xzf singular-onchain-<version>.tar.gz -C singular`.
   Then, inside that directory, run `sha256sum --check --quiet SHA256SUMS` and
   `bash verify-identities.sh` to check every file and the compiled validators.
