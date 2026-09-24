# Naming CLI ownership and dependency interfaces

Issue #114; draft PR #115; branch feat/naming-cli; worktree /code/singular-naming-cli.
Accepted #106 integration: f558d0e8fc916eef494fffcef09cfe2ac5582b8e, merged into lane at 45a8c07ddd8d6a3b8ec95519cbf3257d95eed4fc.

## Owned paths and current APIs

- `offchain/naming-cli/Main.hs`: public executable entry, strict option parsing and named errors.
- `offchain/naming-cli/src/Naming/CLI/Options.hs`: `Connection` (manifest path/socket/network magic), `Options`, `Command`, `parserInfo`. Current implementation exposes attach/inspect only; the other frozen actions remain to implement, not inert command branches.
- `offchain/naming-cli/src/Naming/CLI/Read.hs`: `runRead :: Options -> IO Aeson.Value`. Uses accepted `Deployment.readDeployment/attach/loadMirror`, `mkPureTrieManagerFrom`, live Provider and datum codec. Read-only connection takes no key and never calls deployment builders. Internal asset loader currently uses accepted pre-#110 representative application parameters; final adapter must update when #110 lands.
- `offchain/naming-cli/test/OptionsSpec.hs`: 10 parser checks pass.
- `offchain/naming-cli/read-e2e.sh`: new packaged read-only devnet check; not yet executed. It is narrower than the frozen full `naming-cli-e2e` acceptance, which remains absent.
- Additive cabal executable/test stanzas and Nix `singular-naming`, `naming-cli-read-e2e` declarations; narrow justfile, release asset/check and CI/navigation additions are this lane's scope per A-001.

No edits to existing journey, Deployment, FoldAll, naming datatypes or validators. New transaction construction will live under `Naming.CLI` and consume existing production builders; it must not compete with the cancellation owner's new builder.

## Required dependency integration

- #104: call actual accepted `foldAll` with application-specific `prepareFold`, fee signing and confirmed mirror persistence; no adaptive algorithm here.
- #107: preserve use of existing `loadMirror`/`saveMirror`; consume actual follower API when landed, never synthesize checkpoint metadata. Read mirror root must match live state before absence/retirement observations.
- #110: consume accepted representative name and policy-parameter API; no copied unaccepted code or hash assertions from its draft.
- Connected cancellation repair: this CLI needs its production builder to accept real connected claim/request references, the committed refund and necessary wallet/signing inputs, and return/report submitted and confirmed effects. No concrete new token/refund representation is assumed. Registration must emit whatever claim/request handles the accepted repair needs. Please route the repair's exact types and registration changes through the desk before integration.
- Deposit: model-only first, later separate protocol/CLI implementation. No deposit option, amount default, recipient invention or changed refund semantics in #114.

The public command output will expose pending claim/request handles, transaction IDs, actual refusal reasons and confirmation separately. Explicit mapping inputs are transaction attachments, not follower checkpoints or reconstructed trie state.

## Implemented draft update 66067e9

PR115 now carries attach/inspect and `ChangeRecord` maintenance/recovery; `Naming.CLI.Change.runChange` uses existing keys, verified mirror and datum, generic `Cardano.Tx.Build` with live Provider evaluation, and exact confirmed datum readback. Thirteen parser checks and build pass. Packaged read devnet plus expected wrong-identity refusal pass; connected write checks are underway. Release assembly/artifact check passes; archive installation check underway. Manual docs/naming-cli.md and additive registry CI read job are present. Full acceptance remains incomplete.

NOTE008-010 acknowledged. Cancellation registration/issuance requires the actual accepted #117 bridge and distinct withdrawal approval; no old one-token preimage encoded here. Please expose the registration constructor (or exact shared producer used by #117's real setup) along with cancellation so #114 can consume the approved co-creation and refund binding without duplicating it. Existing-deployment compatibility is unresolved; this lane neither migrates nor silently narrows it.
