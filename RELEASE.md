Not for mainnet. Do not deploy Singular or open datum on mainnet until on-chain verification and an independent audit are complete.

Singular is a registry of unique keys on Cardano that applications can use with
their own rules. This release carries ready-built commands for Linux and macOS,
the compiled smart contracts and the sources they are built from. Demo 1 creates
a registry, inserts a key, changes it, terminates it and shows each refusal where
it should appear; it is played from singular-demo, on a private development node.

## Get the commands

On a Mac with Apple Silicon: `brew install lambdasistemi/tap/singular`, and
`brew upgrade` takes the next release.

On Linux on x86_64: `singular-<version>-x86_64-linux.deb` or
`singular-<version>-x86_64-linux.rpm` installs `singular`, `open-datum` and `devnet` into `/usr/bin`,
and `singular-<version>-x86_64-linux.AppImage` (with `open-datum-…` and `devnet-…`)
holds one command as one file. Their checksums are in
`singular-<version>-x86_64-linux.SHA256SUMS`.

Or download the tarball for your machine and `SHA256SUMS` from this release:

- `singular-<version>-x86_64-linux.tar.gz` for Linux on x86_64;
- `singular-<version>-aarch64-darwin.tar.gz` for a Mac with Apple Silicon.

Check the file against `SHA256SUMS`, unpack it and run `singular --version`,
which prints the release and the commit the program was built from. Each file
holds `singular`, `open-datum` and `devnet`, the program that starts a private
development node, with the Cardano node it starts and everything they need: no
Nix and no compiling. The tarballs, the DEB, the RPM and the Homebrew installation also
hold the deployment blueprint the commands take as `--blueprint`, the same file as
`onchain/plutus.json` in the on-chain archive, with the release's `version.txt`
beside it (`share/` in a tarball, `/usr/share/singular/` from a package). The
[install page](https://lambdasistemi.github.io/singular/docs/install/) has the
commands for each platform.

## Play Demo 1

1. Have the programs and a private development node. Every one of the files above
   holds them, on Linux on x86_64 and on a Mac with Apple Silicon.
   Anywhere else, the Demo 1 shell, https://github.com/lambdasistemi/singular-demo,
   gives them with Nix: `nix develop github:lambdasistemi/singular-demo --accept-flake-config`
   opens a shell with `singular`, `open-datum`, the development node and `jq`, all
   built by the project's CI. It needs Nix; its README says what it is pinned to.
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

## What this release assumes and does not establish

The trie library's proofs are assumed sound.

The statements about the chain's history assume Cardano's rule for how scripts run,
and that rule is not proved here.

The packaged development node cannot run the public test network's (preprod's)
current protocol version, so the batch limits are evaluated under recorded protocol
parameters and corroborated by the node, and are not submitted to that network.

The conformance rows that remain uncovered are published on the
[conformance evidence page](https://lambdasistemi.github.io/singular/docs/conformance-evidence/),
whose count and rows are computed from the receipts.

The [release decision table](https://lambdasistemi.github.io/singular/docs/release-decision-table/)
gives each measurement with the date of the parameters it was taken under.
