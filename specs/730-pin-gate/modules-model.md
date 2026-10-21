# Modules for the pin gate

Dependency direction runs from the programs down to the library. No new package.

## Changed responsibilities

- The state token module of the registry library owns the gate: resolving a state token against a release and an application, comparing every pin the application can derive, and the comparison itself, which is exported so that the command that creates a registry can compare the datum it reads back. It also exports the gate over several candidate applications.
- The application module owns what a pin form can derive: the pin forms that carry a script say so, and the module states which fields each form compares.
- The command line library's live module keeps one resolution entry for the commands (resolving and finding references) and gains the application pin standing in what it returns.
- The describe module prints the registry's pinned policies from the datum and states which were derived by the release and which were not.
- The inspect module resolves before the report of an interrupted create.
- The create module compares the read-back datum.
- The submit module resolves the registry its bundle names before the first send.
- The open-datum run module decides the mode through the gate and has no read of the state datum of its own.

## Not changed

Builders, folds, reconciliation, the bundle format, the signing verbs, the on-chain code, the Lean model, the blueprint and every script hash.

## Second pull request

A test-only harness executable in the off-chain package boots the forged registry and its tokens against a running development node. The journey script and the flake app that runs it follow the keri-stub journey. Nothing in the registry library, the commands or the applications changes.
