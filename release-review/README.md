# Reproduce the Singular archive candidate

Run these commands from the directory where the documentation archive was extracted:

```sh
sha256sum --check artifacts/SHA256SUMS
nix run --no-write-lock-file ./artifacts/review#check
```

The first command checks every raw review input against the archive's internal manifest. The second command evaluates only the shipped review flake and its lock, compiles the shipped Lean model, regenerates both finite corpora, checks the compiled axiom inventory, rebuilds the standalone page in check mode, replays the generic and naming corpora, and executes all negative controls.

Nix may acquire the exact `nixpkgs` revision recorded in `flake.lock` when it is not already cached. That locked toolchain is the only external build input; model, theorem, scenario, simulator, replay, checker, and configuration sources all come from this extracted directory. No checkout is consulted.

The result is finite executable-design evidence for the candidate in this archive. It is not independent acceptance, a compiled Cardano validator, or observed ledger execution.
