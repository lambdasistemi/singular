{
  description = "Singular executable model, statement debt and documentation";
  inputs.dev-assets-mkdocs.url = "github:paolino/dev-assets/34c7df6959c9fa36c6927808de6712b939e7a7fb?dir=mkdocs";
  inputs.dev-assets-playwright.url = "github:paolino/dev-assets/a8f2ff7603bc793794d3e4459b2d5510a57e72a2?dir=playwright";
  inputs.nixpkgs.follows = "dev-assets-mkdocs/nixpkgs";
  outputs = { self, nixpkgs, dev-assets-mkdocs, dev-assets-playwright }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      each = nixpkgs.lib.genAttrs systems;
      project = system: import ./nix/docs.nix {
        pkgs = import nixpkgs { inherit system; };
        src = self;
        sharedShell = dev-assets-mkdocs.devShells.${system}.default;
        sharedSource = dev-assets-mkdocs;
        mermaidJs = dev-assets-mkdocs.packages.${system}.mermaid-js;
      };
      model = system: import ./nix/model.nix { pkgs = import nixpkgs { inherit system; }; src = self; };
      coverage = system: import ./nix/coverage.nix { pkgs = import nixpkgs { inherit system; }; src = self; };
      simulator = system: import ./nix/simulator.nix { pkgs = import nixpkgs { inherit system; }; src = self; };
      browser = system: import ./nix/browser.nix {
        pkgs = import nixpkgs { inherit system; };
        browserPkgs = import dev-assets-playwright.inputs.nixpkgs { inherit system; };
        src = self;
      };
      packages = system: { default = (project system).docs; docs = (project system).docs; docs-release = (project system).releaseArchive; model = (model system).package; };
      buildGate = system:
        let pkgs = import nixpkgs { inherit system; };
        in pkgs.linkFarm "singular-build-gate" (
          pkgs.lib.mapAttrsToList (name: path: { name = "package-${name}"; inherit path; }) (packages system)
          ++ pkgs.lib.mapAttrsToList (name: path: { name = "check-${name}"; inherit path; }) self.checks.${system}
          ++ pkgs.lib.mapAttrsToList (name: app: { name = "app-${name}"; path = app.program; }) self.apps.${system}
          ++ [ { name = "dev-shell-inputs"; path = self.devShells.${system}.default.inputDerivation; } ]
        );
    in {
      packages = each (system: packages system // { build-gate = buildGate system; });
      checks = each (system: { docs = (project system).check; release = (project system).releaseCheck; model = (model system).check; simulator = (simulator system).check; browser = (browser system).check; coverage = (coverage system).check; });
      apps = each (system: ((project system).apps // (model system).apps // (simulator system).apps // (browser system).apps // (coverage system).apps));
      devShells = each (system: { default = (project system).shell.overrideAttrs (old: (browser system).environment // { nativeBuildInputs = (old.nativeBuildInputs or []) ++ (with import nixpkgs { inherit system; }; [ lean4 nodejs ]); }); });
    };
}
