# Building the documentation

The site renders the repository's canonical Markdown and specification. A generated staging directory preserves their relative paths; it is not a second editable documentation tree.

## Build and check

With Nix flakes enabled, run:

```sh
nix build .#docs
nix flake check --no-eval-cache
nix run .#docs-check
nix run .#browser-check
```

The documentation package and checks use the locked shared MkDocs toolchain. The documentation check inspects rendered internal links, section anchors, navigation, speech data and theme assets. Separate model and simulator checks exercise the proved Lean model and its finite corpus, and the model check cross-checks the compiled axiom report against the theorem manifest; none proves application behavior. See the [model ledger](model-ledger.md) and [simulation](simulation.md) for their exact scope.

The browser check launches the pinned Chromium build, serves the standalone simulator on a temporary loopback port, and executes its manual-control and story assertions. The canonical runner is `tools/browser-check.mjs`; the earlier callback under `simulator/` is retained as historical browser evidence. Screenshots use a temporary writable directory; no browser download or external service is required during execution. Set `KEEP_BROWSER_EVIDENCE=1` to retain successful browser evidence. CI's build gate realizes the packages, executing checks, and development-shell inputs before the downstream verification jobs.

## Generated API references

The site ships a generated reference for each library a contributor calls
into, built from the same revision as the pages that link it. Which code
has one, and what stands in for it where there is none:

| Code | Reference on this site |
| --- | --- |
| The off-chain registry library's public modules | Haddock: the [off-chain API reference](offchain-api-reference.md), including the ledger and provider modules it re-exports from its package-private library |
| The Conformance library | Haddock: the [Conformance API reference](conformance-api-reference.md) |
| The registry validators under `onchain/` | `aiken docs` from the onchain flake's pinned compiler: the [validator API reference](onchain-api-reference.md) |
| The six package-private node owners | None generated; each links its source file from the [Node module ownership](offchain-node-ownership.md) page, and the public pages that re-export an owner's names link that entry |
| The rest of the package-private `node-internal` library | Its only other modules, the ledger and provider types, are re-exported and documented in the off-chain reference |
| The off-chain and Conformance executables and test suites | None generated; the [registry command owners](offchain-command-entrypoints.md) and [Conformance suite owners](conformance-architecture.md) pages link their sources |
| The naming validators under `naming-onchain/` | None generated; a separate Aiken project, documented by [record value and recovery](record-value.md) |

Private owners and executables are not Haddock-documented on their own by
decision: nothing imports them outside their package, and an owner page
that names each module's responsibility and links its source serves a
contributor better than a second, unlinked reference. Each generated
reference carries a manifest binding its pages to the digests of the
source it was generated from, and the documentation check fails when a
page, its source or its link targets no longer agree.

## The repository code inventory

`just inventory` maps every file the tree actually holds to its lint policy
and its format policy — or, for data and artifacts, to a named non-code
class — and fails on anything unmapped. Discovery walks the tree itself
(extensions, shebangs, executable mode and component manifests), so a new
source file in a covered directory is mapped without editing anything,
while a file nobody classified fails with a named diagnostic instead of
passing silently. The same inventory runs over the Nix flake source, where
no Git directory exists, through `nix run .#inventory-check`; pull-request
CI runs both forms so the two contexts cannot drift. The checked registry
lives in `tools/code_inventory.py`.

The inventory is a mapping, not enforcement: its report names which
policies CI executes today and which are pending debt owned by the
remaining slices of the lint-and-format work — including the retained HLint
hint debt in the excluded offchain directories, which stays visible until
it is resolved. `just inventory-controls` runs the negative and positive
controls: synthetic orphans injected into scratch copies of the classified
tree, each required to produce its intended failure. The controls never
touch the working tree.

## Haskell formatting

The repository's Haskell trees are formatted with Fourmolu under one house
configuration, `fourmolu.yaml` at the repository root. Every formatter
entrypoint — the off-chain lint check, the Conformance format check and the
root recipes below — passes that file explicitly, so a missing configuration
fails loudly instead of falling back to Fourmolu's defaults, and there is no
per-tree configuration to drift from it.

```sh
nix develop --quiet -c just format        # apply to every discovered Haskell source
nix develop --quiet -c just format-check  # the same check `just ci` carries
```

Discovery is dynamic: every Haskell source under `offchain/` and
`conformance/` — the formerly fenced verifier sources and the evaluation
spike included — with no directory exclusions, so a new file or component
directory is covered with nothing to edit. The Conformance tree gets the
same check in its own Nix source context through `nix run .#format-check`
from `conformance/` (CI job 'Conformance Haskell format check'). `just
format-controls` runs the negative and positive controls: a source that
Fourmolu's defaults accept but the house configuration rejects must fail
the check — proving the configuration is read — and its formatter correction
must pass it again; a tree without the configuration must fail loudly rather
than format with defaults; a newly tracked component tree outside the old
directories joins the check through the Git index, while ignored untracked
build noise never enters it and a tracked file under an ignored path stays.
The controls run over scratch copies and never touch the working tree.

## Edit and serve

The development shell has a separate CI build because packaged builds do not exercise it:

```sh
nix develop --quiet -c just ci
nix develop --quiet -c just serve-docs
```

`just build-docs` and `just serve-docs` stage the generated API references
from the packaged site build, `nix build .#docs`, so the local site links
the same generated pages the packaged site and its checks carry; the
Markdown pages still reload live as they are edited.

To serve the packaged output without a live-reload editor, run `nix run .#docs-serve -- 8000` and open `http://127.0.0.1:8000`.

## Publication and accessibility

Pull requests publish to a live preview with the candidate revision recorded alongside the generated site. Preview publication does not post PR comments. The default branch publishes through workflow-mode GitHub Pages after merge; the same documentation build supplies both routes.

The Material theme follows the system light/dark preference and provides a toggle. Section read-aloud controls use the browser's speech voices and curated companion JSON. The shared reader is pinned by the Nix input; its speech URL lookup is adapted to work under both site prefixes. Diagrams are Mermaid, rendered by the copy the shared toolchain pins as a fixed-output Nix input and served from the site itself; no page loads a script or stylesheet from outside the site, and the site check fails if one does. Voice availability depends on the browser and device.

## Documentation releases

The first documentation version is prepared as `0.1.0`: `version.txt`, the release manifest, and the changelog agree. That prepared version is not evidence that an archive was tagged or published. Release-please's `simple` strategy updates those three surfaces together for later versions, and Nix requires the version and manifest to agree. These are documentation versions, not deployed protocol versions.

After a successful main-branch gate, repository-scoped App credentials let release-please prepare a release PR whose changes trigger normal CI. It plans PRs only: release creation is disabled because upstream release creation posts a PR comment. Merging the release PR prepares the version but does not tag or publish it. An operator-authorized `v<version>` tag on that merged release PR's exact commit triggers publication. The commit must belong to main, and tag, manifest and version must agree.

The tag workflow builds and checks a Nix-produced documentation archive and checksum, publishes them to the matching GitHub release, downloads and verifies the uploaded bytes, then changes the release PR's pending label to tagged. It accepts a pending or already-tagged matching PR so interrupted publication can be retried. It does not post PR comments. CI has a manual recovery trigger; no release workflow or tag is dispatched merely by adding this automation.

Build the documentation archive locally with `nix build .#docs-release`, and run version, workflow and artifact checks with `nix run .#release-check`. The archive contains the rendered site and speech data plus a complete review workspace under `artifacts/review/`: model and theorem sources, finite corpora, scenarios, simulator and replay sources, checkers, and a minimal flake with its exact lock. The inner `artifacts/SHA256SUMS` authenticates every review input plus the separately served corpus and identity files; the outer `SHA256SUMS` authenticates the archive.

Packaging checks alone do not establish reproduction. Extract the built `singular-docs-<version>.tar.gz` into a fresh directory, change to that directory, run `sha256sum --check artifacts/SHA256SUMS`, then run `nix run --no-write-lock-file ./artifacts/review#check`. Nix may acquire the exact locked toolchain when it is not cached; the model, scenario, simulator, replay, checker, and configuration inputs all come from the archive. Provenance comes from the validated tag and build binding. The release workflow has not been exercised against a real tag because no release is authorized yet.

The initial empty-manifest behavior and version override follow the [release-please manifest documentation](https://github.com/googleapis/release-please/blob/c65408d9f68b2772c6e61dcdc4a8b6f5969bb4e1/docs/manifest-releaser.md). Publishing remains a separate action from reviewing this documentation.
