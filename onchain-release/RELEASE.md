Singular is a registry of unique keys on Cardano that applications can use with
their own rules. This release carries the compiled smart contracts and the run
page for Demo 1: create a registry, insert a key, change it, terminate it, and
see each refusal appear where the page says it will. Play it first on a private
development node, then on the public preprod network with test ada.

## Play Demo 1

1. Download `singular-onchain-<version>.tar.gz` and `SHA256SUMS` from this
   release. The documentation archive is 220 MB and Demo 1 does not need it.
2. Check the download: `sha256sum --check --ignore-missing SHA256SUMS`. The file
   names carry the version without a `v`.
3. Extract the archive into a directory of its own, because it has no top-level
   directory and carries a `SHA256SUMS` of the same name:
   `mkdir singular && tar xzf singular-onchain-<version>.tar.gz -C singular`.
   Then, inside that directory, run `sha256sum --check --quiet SHA256SUMS` and
   `bash verify-identities.sh` to check every file and the compiled validators.
4. Follow `DEMO1.md` in the extracted directory. It builds `singular` and
   `open-datum`, starts a private development node, makes Alice's and Bob's vault
   wallets and runs Demo 1 with no faucet and no account.
5. Then follow the preprod runbook,
   https://lambdasistemi.github.io/singular/docs/demo1-on-preprod/, which plays
   the same steps on preprod with the faucet, a Koios address and the amounts.

This release ships no ready-built binaries. Building compiles a large Haskell
stack unless the project's public binary cache serves it; the runbook says how to
use the cache. The naming material in the archive's `README.md` is history and no
part of Demo 1.
