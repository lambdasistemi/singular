# Recovery interfaces

As a maintainer, I want independently selectable cases and portable collection, so that CI invokes the same declared boundaries a reviewer can reproduce.

## Interface boundary

Product function signatures are unchanged. CLI_RECOVERY_PARTS remains the scenario selection mechanism and the existing checkwrapper retains its repository argument. Only the harness may add a source-discovery mode that never boots a node.

| Entry point | Contract |
|---|---|
| cli-recovery-cross-wallet-parts | Emit a nonempty source-bound matrix of every fold hold plus the lost-answer case; discovery executes no node. |
| cli-recovery-cross-wallet-part PART | Execute exactly the selected case through CLI_RECOVERY_PARTS, independent ordinary setup and existing ran-proof; preserve outcomes and report actual elapsed node-backed invocation time. |
| cli-recovery-cross-wallet-evidence SOURCE OUTPUT SHA RUN PART | Collect genuine captured records with explicit runtime tools; preserve producer SHA/run/part, file hashes, measured exclusions and truthful absence. SOURCE is the exact captured run root, never an implicitly selected container. SHA and RUN identify that captured producer; the collector implementation candidate is recorded separately in its control receipt. |

The collector is also exposed as a buildable package under the same name, referring to the same writeShellApplication derivation as its app. The empty-PATH control uses the absolute executable from that build output.

## Case and timing contract

PART is one atomic CLI_RECOVERY_PARTS token: cross-wallet:HOLD for each source-discovered fold hold, plus cross-wallet:SINGULAR_HARNESS_HOLD_AFTER_SEND:lost-answer. The discovery app emits a nonempty JSON object with a part array; the execution app accepts exactly one discovered token and refuses unknown tokens before starting a node. Discovery and execution share one source census. The historical aggregate cross-wallet selector may remain for compatibility; the hosted gate selects the complete case matrix.

Each execution writes node-execution-time.json at its captured run root with part, elapsed_seconds and actual exit_code. Time spans the actual node-backed harness invocation, including setup and clause checks, and excludes collection/upload. It is elapsed wall time, not node CPU time. Interrupted runs retain only observations actually written; missing timing is reported absent and cannot pass the completed-part gate.

## Observable effects

The collector's packaged executable works with env -i PATH= and absolute store entrypoint. Local controls use existing genuine records, not new node runs or manufactured missing files. The matrix's hosted artifacts retain each producer's real receipts and timing. The complete matrix's extent remains the full obligation; selecting one case narrows only that invocation's observation extent.

Any product change, altered expectation, raised timeout or additional seat requires a revised mandate. An unresolved second collection or case-split review block returns to the epic.
