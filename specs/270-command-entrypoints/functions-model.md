# Command function boundaries

As a maintainer, I want each entry to delegate to one orchestration function while keeping the old outer error and exit behavior.

## Signatures

| ID | Signature-level obligation |
| --- | --- |
| F270-J | `journey :: IO ()` remains the command orchestration boundary; `main :: IO ()` preserves the existing exception prefix and exit status. Identity, steps and controls are owned behind explicit exports. |
| F270-I | `insertActive :: Maybe FilePath -> IO ()` remains the scenario boundary; `observedPathFrom :: [String] -> Maybe FilePath` keeps its first-match behavior; `main :: IO ()` preserves exception handling. |
| F270-U | `updateTerminal :: Maybe FilePath -> IO ()` remains the scenario boundary; `observedPathFrom :: [String] -> Maybe FilePath` keeps its first-match behavior; `main :: IO ()` preserves exception handling. |
| F270-D | `run :: IO ()` retains deploy/verify/count/genesis-skey dispatch by first non-dash argument; `flagValue :: String -> [String] -> Maybe String` retains separate and equals flag spellings; `main :: IO ()` retains the existing outer failure behavior. Verb functions remain reachable through explicit command-local exports. |

New helper names and types may be chosen by the coder inside these owners only when each responsibility has one definition, dependency direction stays acyclic and the CLI/ledger observations remain unchanged. A placement or signature conflict returns to this mandate before implementation continues.
