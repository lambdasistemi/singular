# Building the documentation

The site renders the repository's canonical Markdown and specification. A generated staging directory preserves their relative paths; it is not a second editable documentation tree.

## Build and check

With Nix flakes enabled, run:

```sh
nix build .#docs
nix flake check --no-eval-cache
nix run .#docs-check
```

The documentation package and checks use the locked shared MkDocs toolchain. The checks inspect rendered internal links, section anchors, navigation, speech data and theme assets. They do not execute protocol acceptance scenarios or prove application behavior.

## Edit and serve

The development shell has a separate CI build because packaged builds do not exercise it:

```sh
nix develop --quiet -c just ci
nix develop --quiet -c just serve-docs
```

To serve the packaged output without a live-reload editor, run `nix run .#docs-serve -- 8000` and open `http://127.0.0.1:8000`.

## Publication and accessibility

Pull requests publish to a live preview with the candidate revision recorded alongside the generated site. Preview publication does not post PR comments. The default branch publishes through workflow-mode GitHub Pages after merge; the same documentation build supplies both routes.

The Material theme follows the system light/dark preference and provides a toggle. Section read-aloud controls use the browser's speech voices and curated companion JSON. The shared reader is pinned by the Nix input; its speech URL lookup is adapted to work under both site prefixes. Voice availability depends on the browser and device.
