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

The documentation package and checks use the locked shared MkDocs toolchain. The documentation check inspects rendered internal links, section anchors, navigation, speech data and theme assets. Separate model and simulator checks exercise the admitted Lean candidate and its finite corpus; none proves application behavior. See the [model ledger](model-ledger.md) and [simulation](simulation.md) for their exact scope.

The browser check launches the pinned Chromium build, serves the standalone simulator on a temporary loopback port, and executes its manual-control and story assertions. The canonical runner is `tools/browser-check.mjs`; the earlier callback under `simulator/` is retained as historical browser evidence. Screenshots use a temporary writable directory; no browser download or external service is required during execution. Set `KEEP_BROWSER_EVIDENCE=1` to retain successful browser evidence. CI's build gate realizes the packages, executing checks, and development-shell inputs before the downstream verification jobs.

## Edit and serve

The development shell has a separate CI build because packaged builds do not exercise it:

```sh
nix develop --quiet -c just ci
nix develop --quiet -c just serve-docs
```

To serve the packaged output without a live-reload editor, run `nix run .#docs-serve -- 8000` and open `http://127.0.0.1:8000`.

## Publication and accessibility

Pull requests publish to a live preview with the candidate revision recorded alongside the generated site. Preview publication does not post PR comments. The default branch publishes through workflow-mode GitHub Pages after merge; the same documentation build supplies both routes.

The Material theme follows the system light/dark preference and provides a toggle. Section read-aloud controls use the browser's speech voices and curated companion JSON. The shared reader is pinned by the Nix input; its speech URL lookup is adapted to work under both site prefixes. Diagrams are Mermaid, rendered by the copy the shared toolchain pins as a fixed-output Nix input and served from the site itself; no page loads a script or stylesheet from outside the site, and the site check fails if one does. Voice availability depends on the browser and device.

## Documentation releases

At this bootstrap revision, no documentation version has been released. `version.txt` starts at the explicitly unreleased build baseline `0.0.0`; the release manifest is empty. Release-please's `simple` strategy proposes `0.1.0` for the first release, then updates `version.txt`, the manifest and changelog together. Nix reads `version.txt`; a check requires equality with the manifest after the initial proposal. These are documentation versions, not deployed protocol versions.

After a successful main-branch gate, repository-scoped App credentials let release-please prepare a release PR whose changes trigger normal CI. It plans PRs only: release creation is disabled because upstream release creation posts a PR comment. Merging the release PR prepares the version but does not tag or publish it. An operator-authorized `v<version>` tag on that merged release PR's exact commit triggers publication. The commit must belong to main, and tag, manifest and version must agree.

The tag workflow builds and checks a Nix-produced documentation archive and checksum, publishes them to the matching GitHub release, downloads and verifies the uploaded bytes, then changes the release PR's pending label to tagged. It accepts a pending or already-tagged matching PR so interrupted publication can be retried. It does not post PR comments. CI has a manual recovery trigger; no release workflow or tag is dispatched merely by adding this automation.

Build the documentation archive locally with `nix build .#docs-release`, and run version, workflow and artifact checks with `nix run .#release-check`. The archive contains the rendered site and speech data; `SHA256SUMS` checks byte integrity; provenance comes from the validated tag and build binding. The release workflow has not been exercised against a real tag because no release is authorized yet.

The initial empty-manifest behavior and version override follow the [release-please manifest documentation](https://github.com/googleapis/release-please/blob/c65408d9f68b2772c6e61dcdc4a8b6f5969bb4e1/docs/manifest-releaser.md). Publishing remains a separate action from reviewing this documentation.
