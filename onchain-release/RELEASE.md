Singular is a registry of unique names on Cardano that applications can use
with their own rules. This archive includes the compiled smart contracts and
runnable examples: claim a name, change its payment destination, recover
control after losing a key, and retire it permanently so it cannot be reused.
Run the naming application on a local devnet or against your own test-network
node.

## Use it

1. Download the `singular-onchain-<version>.tar.gz` archive and `SHA256SUMS`
   from this release. The checksum file also covers the documentation archive;
   download that too to check every listed file.
2. Run `sha256sum --check SHA256SUMS`, extract the on-chain archive, then run
   `bash verify-identities.sh` inside it to check the compiled validators.
3. For a local devnet, follow `README.md` in the archive. The runners use Nix.
4. To use your own node and wallet, follow the
   [onboarding runbook](https://lambdasistemi.github.io/singular/docs/consumer-onboarding/).
5. For the shared registry on preprod, follow `docs/preprod.md` once that
   deployment guide is published.
