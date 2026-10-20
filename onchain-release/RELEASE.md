Singular is a registry of unique keys on Cardano that applications can use with
their own rules. This release carries ready-built commands for Linux and macOS,
the compiled smart contracts and the run page for Demo 1: create a registry,
insert a key, change it, terminate it, and see each refusal appear where the page
says it will. Play it on a private development node; the run page also names the
three settings that change for a public test network.

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
2. Download `singular-onchain-<version>.tar.gz` and `SHA256SUMS` from this
   release. The documentation archive is 220 MB and Demo 1 does not need it.
   Check the download: `sha256sum --check --ignore-missing SHA256SUMS`. The file
   names carry the version without a `v`.
3. Extract the archive into a directory of its own, because it has no top-level
   directory and carries a `SHA256SUMS` of the same name:
   `mkdir singular && tar xzf singular-onchain-<version>.tar.gz -C singular`.
   Then, inside that directory, run `sha256sum --check --quiet SHA256SUMS` and
   `bash verify-identities.sh` to check every file and the compiled validators.
4. Follow `DEMO1.md` in the extracted directory. It starts the private
   development node, makes Alice's and Bob's vault wallets and runs Demo 1 with
   no faucet and no account. If you did not take the shell in step 1, it also
   shows how to build the commands; that compiles a large Haskell stack unless the
   project's public binary cache serves it.
5. The same steps as a page to paste from, one block at a time, are at
   https://lambdasistemi.github.io/singular-demo/.
