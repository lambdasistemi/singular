# Changed responsibilities

command-line-component: new offchain/cli component owns reusable public command parsing/dispatch and command-specific CLI errors. It depends on registry production facades; registry library never depends on CLI. See parse-command/RUN.

saved-registry-state: CLI configuration/state owner holds public identity and authenticated local state across processes, validates version/identity/commitment and excludes secrets. It composes existing Deployment/Trie persistence. See saved-public-identity/STATE.

authenticated-chain-observation: CLI observation owner reads ledger state and holdings with fresh chain points, binds selected-key proof to ledger commitment and labels local proof separately. Its inspection session consumes public node settings only and exposes no signing/funding/submission requirement. See command-observation-receipt.

MM299-WRITES: CLI lifecycle owner composes existing production boot/request/fold builders; caller wallet/seed/input safety and partial-state preservation are its obligations. Promote only a necessary reusable helper to its nearest existing stable owner, preserving facades and existing semantics; never duplicate model or builder logic.

MM299-ARTIFACT: Cabal/flake/component inventory and release assembly expose singular; ordinary-CLI archive CI and run page consume that packaged entry point. Demo script owns orchestration only. Existing commands remain available and their controls retained.
