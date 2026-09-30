# Run record fields

As a reviewer, I want each run record to carry every identity the two runs must share or differ on, so their comparison is mechanical.

## Run record

One JSON object per run, `mutant.json` and `restored.json`. Every field is read from the environment or the command's output, never typed.

| Field | Meaning | Validation |
| --- | --- | --- |
| `role` | `mutant` or `restored` | one of the two |
| `commit`, `tree` | source commit and tree the command ran in | the restored commit is the candidate; the mutant's parent is the candidate |
| `dirty` | porcelain status line count before the run | 0 |
| `patch` | path and SHA-256 of the committed patch; for the mutant, `git diff candidate mutant` equals it | mutant only; byte-equal |
| `lean` | tree id of `lean/` and SHA-256 of `lean/driver-corpus.json` | equal in both records |
| `blueprint` | store path and SHA-256 of the blueprint passed as `REGISTRY_BLUEPRINT` | equal in both records |
| `genesis` | the genesis directory the wrapper used and a content digest over its files | digest equal in both records |
| `node` | the node version line the run printed | equal in both records |
| `command`, `cwd`, `env` | the exact argument vector, working directory and every variable the recorder set | equal in both records except the tree root |
| `builds` | store paths of the regression target and the runner built for this tree | the regression target path differs between records |
| `start`, `end`, `exit` | UTC times and the real exit status | the mutant is nonzero, the restored run is 0 |
| `log` | `retained`, the raw log's file name in the evidence directory; `bytes`, `lines` and `sha256` of that complete raw output | `sha256` equals the digest of the retained file |
| `witnesses` | the log lines matched for each R280-01 or R280-02 witness, with line numbers | all present, in order |
| `invocations` | every nix and git invocation the recorder made for this run, with its exit | complete and ordered |

## Pair invariants

A pair is admissible only when both records exist, share `lean`, `blueprint`, `genesis`, `node`, `command` and `env`, and satisfy their own exit and witness rules. A missing witness, a setup failure or any other cause of a nonzero mutant exit makes the pair inadmissible, and the record says so.
