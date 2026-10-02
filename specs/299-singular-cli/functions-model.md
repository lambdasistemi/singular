# New public signatures and effects

Only the CLI component's entry contract is new; production facade signatures remain unchanged. Internal helpers stay implementation-owned, constrained by the module and data contracts.

parse-command: `parseCommand(args: [String]) -> Either CLIError Command`. Command and CLIError realize command-inputs/ERROR. Parsing has no IO/signing/submission effect and rejects malformed selected keys/partial settings before execution.

run-command: `runCommand(command: Command) -> IO ()`. This dispatches the four ordinary commands, produces command-observation-receipt and typed attributable failure. Inspect has no signing, funding or submission effect; writes obey saved-identity, seed reservation, commitment and partial-outcome contracts. Help/preview report actual supported configuration without submission. Command, CLIError and runtime refinements remain private to the CLI component unless the owner approves a shared abstraction.

packaged-command-entrypoint: `main() -> IO ()`. Public packaged singular entry point invokes the two contracts above; demo orchestration invokes this process separately for each command and implements no registry behavior.
