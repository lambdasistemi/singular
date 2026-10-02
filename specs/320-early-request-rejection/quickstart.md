# Check the repair yourself

## On the compiled validators

```sh
cd onchain && nix flake check
```

The Aiken suite includes accepting rejections in the processing and retraction windows, for both the state and the request purpose. It also includes refused short, misdirected, script and missing refunds in those windows, and refused updates outside the processing window.

## On a devnet, through the product's builder

```sh
cd offchain
blueprint="$(nix build --quiet --no-link --print-out-paths ../onchain#plutus-blueprint)"
REGISTRY_BLUEPRINT="$blueprint" nix run --quiet .#cage-tests-e2e
```

Look for the rejection cases named by their window. Each one submits the builder's transaction, then reads back from the ledger that the request is gone, the owner received at least the deposit, and the registry state is unchanged.

## Compared with the model

```sh
cd conformance
blueprint="$(nix build --quiet --no-link --print-out-paths ../onchain#plutus-blueprint)"
REGISTRY_BLUEPRINT="$blueprint" nix run --quiet .#conformance -- run reject-before-deadline-consumer-requirement --receipts-dir "$(mktemp -d)"
```

reject-before-deadline-consumer-requirement's receipt shows the chain accepting a processing-window rejection, with the verdict `unmet-by-ruling`. Its consumer requirement still says refuse and, by operator ruling 2026-10-01, remains unmet. reject-inside-processing-and-retraction-windows is run the same way. Each of its steps is compared with the model, and the log states the window each reject was placed in.

## Identities

```sh
nix shell --quiet nixpkgs#jq nixpkgs#diffutils -c bash offchain/deployment-identity-check.sh
```

It checks the committed manifests and the deployed scripts against freshly built blueprints, in both directions.
