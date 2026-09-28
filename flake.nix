{
  description = "Singular executable model, statement debt and documentation";
  inputs.dev-assets-mkdocs.url = "github:paolino/dev-assets/34c7df6959c9fa36c6927808de6712b939e7a7fb?dir=mkdocs";
  inputs.dev-assets-playwright.url = "github:paolino/dev-assets/a8f2ff7603bc793794d3e4459b2d5510a57e72a2?dir=playwright";
  # This repository's own off-chain tree, as a relative in-tree input: the
  # generated API reference's Haddock build and its manifest source digests
  # come from exactly this source. Its dependencies keep their own locked
  # revisions (no follows rebinding), and offchain/flake.lock stays as is.
  inputs.offchain.url = "path:./offchain";
  # The Conformance tree the same way, as a relative path input that keeps
  # the whole repository as the flake's source (dir=conformance): the
  # Conformance build root synthesizes from sibling trees (offchain, lean,
  # tools), so a bare subdirectory input could not evaluate, and the flake's
  # outPath is the conformance directory itself. Its generated library
  # reference binds to this candidate's own source, with its dependencies
  # keeping their own locked revisions and conformance/flake.lock staying as
  # is. The Conformance flake's inputs are declared verbatim from the
  # off-chain flake's, so the lock node shares the already-locked revisions
  # those declarations resolve to — no new upstream input is fetched or
  # created.
  inputs.conformance.url = "path:./?dir=conformance";
  inputs.nixpkgs.follows = "dev-assets-mkdocs/nixpkgs";
  outputs = { self, nixpkgs, dev-assets-mkdocs, dev-assets-playwright, offchain, conformance }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      each = nixpkgs.lib.genAttrs systems;
      project = system: import ./nix/docs.nix {
        pkgs = import nixpkgs { inherit system; };
        src = self;
        sharedShell = dev-assets-mkdocs.devShells.${system}.default;
        sharedSource = dev-assets-mkdocs;
        mermaidJs = dev-assets-mkdocs.packages.${system}.mermaid-js;
        inherit offchain conformance;
      };
      model = system: import ./nix/model.nix { pkgs = import nixpkgs { inherit system; }; src = self; };
      coverage = system: import ./nix/coverage.nix { pkgs = import nixpkgs { inherit system; }; src = self; };
      inventory = system: import ./nix/inventory.nix { pkgs = import nixpkgs { inherit system; }; src = self; };
      simulator = system: import ./nix/simulator.nix { pkgs = import nixpkgs { inherit system; }; src = self; };
      browser = system: import ./nix/browser.nix {
        pkgs = import nixpkgs { inherit system; };
        browserPkgs = import dev-assets-playwright.inputs.nixpkgs { inherit system; };
        src = self;
      };
      packages = system: { default = (project system).docs; docs = (project system).docs; docs-release = (project system).releaseArchive; model = (model system).package; };
      buildGate = system:
        let pkgs = import nixpkgs { inherit system; };
        # Build artifacts only; checks and check-running apps stay separate.
        in pkgs.linkFarm "singular-build-gate" (
          pkgs.lib.mapAttrsToList (name: path: { name = "package-${name}"; inherit path; }) (packages system)
        );
    in {
      packages = each (system: packages system // { build-gate = buildGate system; });
      checks = each (system: { docs = (project system).check; release = (project system).releaseCheck; model = (model system).check; simulator = (simulator system).check; browser = (browser system).check; coverage = (coverage system).check; inventory = (inventory system).check; });
      apps = each (system: ((project system).apps // (model system).apps // (simulator system).apps // (browser system).apps // (coverage system).apps // (inventory system).apps));
      devShells = each (system: { default = (project system).shell.overrideAttrs (old: (browser system).environment // { nativeBuildInputs = (old.nativeBuildInputs or []) ++ (with import nixpkgs { inherit system; }; [ lean4 nodejs ]); }); });
    };
}
