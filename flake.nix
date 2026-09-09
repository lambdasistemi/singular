{
  description = "Singular executable model, statement debt and documentation";
  inputs.dev-assets-mkdocs.url = "github:paolino/dev-assets/34c7df6959c9fa36c6927808de6712b939e7a7fb?dir=mkdocs";
  inputs.nixpkgs.follows = "dev-assets-mkdocs/nixpkgs";
  outputs = { self, nixpkgs, dev-assets-mkdocs }:
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
      simulator = system: import ./nix/simulator.nix { pkgs = import nixpkgs { inherit system; }; src = self; };
    in {
      packages = each (system: { default = (project system).docs; docs = (project system).docs; docs-release = (project system).releaseArchive; model = (model system).package; });
      checks = each (system: { docs = (project system).check; release = (project system).releaseCheck; model = (model system).check; simulator = (simulator system).check; });
      apps = each (system: ((project system).apps // (model system).apps // (simulator system).apps));
      devShells = each (system: { default = (project system).shell.overrideAttrs (old: { nativeBuildInputs = (old.nativeBuildInputs or []) ++ (with import nixpkgs { inherit system; }; [ lean4 nodejs ]); }); });
    };
}
