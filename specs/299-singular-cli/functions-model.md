# New public signatures and effects

Only the CLI component's entry contract is new; production facade signatures remain unchanged. Internal helpers stay implementation-owned, constrained by MM299 and DM299.

FM299-PARSE: `parseCommand(args: [String]) -> Either CLIError Command`. Command and CLIError realize DM299-COMMAND/ERROR. Parsing has no IO/signing/submission effect and rejects malformed selected keys/partial settings before execution.

FM299-RUN: `runCommand(command: Command) -> IO ()`. This dispatches the four ordinary commands, produces DM299-RECEIPT and typed attributable failure. Inspect has no signing, funding or submission effect; writes obey saved-identity, seed reservation, commitment and partial-outcome contracts. Help/preview report actual supported configuration without submission. Command, CLIError and runtime refinements remain private to the CLI component unless the owner approves a shared abstraction.

FM299-MAIN: `main() -> IO ()`. Public packaged singular entry point invokes the two contracts above; demo orchestration invokes this process separately for each command and implements no registry behavior.
