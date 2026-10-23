# Select tests for the code you change

As a contributor, you want to run the tests for the areas your change can affect and see exactly which examples you selected. Each Hspec path starts with a stable module name and bracketed area tags. Selecting an area includes every module carrying that tag; selecting a module narrows the run to that module. A filtered run proves only its selected examples. Pending examples remain unexecuted.

## Select an area or module

Run the off-chain commands from `offchain/`. Keep the brackets quoted so the shell passes them literally to Hspec:

```sh
nix run .#cage-tests -- --match "[time]"
nix run .#cage-tests -- --match "/Singular.Registry.NetworkTime "
nix run .#cage-tests -- --match "[provider]" --skip "[history]"
```

The time filter matches the literal tag wherever it occurs in a path. The module filter uses a leading slash for the path segment start and a trailing space for the end of the module name. The slash-terminated form selects nothing: Hspec matches substrings of the joined path, and the tags sit between the module name and the next slash. Combining match with skip first selects matching paths and then excludes the skipped paths. Different area tags on one module mean that either area can select its examples; they do not duplicate examples.

## Area vocabulary

All suites compile the same `Area` type in `offchain/test-tags/Test/Tags.hs`. Its constructors produce the following lowercase labels. Add a label only when a gate needs it, then document it here.

| Tag | Selects |
|---|---|
| `provider` | Ledger adapters, sessions, reads and submission. |
| `history` | Archived evidence, recorded chain data and replay. |
| `time` | Network time, bounded waiting and slot conversion. |
| `validity` | Transaction windows and candidate admission. |
| `evaluation` | Script evaluation, execution units and measured construction. |
| `wallet` | Wallet keys, signing and wallet observations. |
| `cli` | Command parsing, plans, output and command admission. |
| `recovery` | Restart, cleanup, journals and recovery paths. |
| `trie` | Registry trie storage and state commitments. |
| `builders` | Blueprint parameters and transaction construction. |
| `naming` | Naming registration, records and retirement. |
| `application` | Naming and open-datum application construction. |
| `conformance` | The Hspec evidence-harness appendix. |
| `e2e` | Development-node and backend contract scenarios. |

For example, network-time examples start under `Singular.Registry.NetworkTime [time][provider]`. A gate changing time material can select time; a broader adapter change can select provider. Module names omit a trailing `Spec` suffix.

## Suite commands and evidence limits

The Cabal manifests declare eight test suites: seven Hspec suites, `cage-tests`, `e2e-tests` exposed as `cage-tests-e2e`, `contract-tests`, `record-value-tests`, `conformance-tests` exposed for filtering as `conformance-appendix-tests`, `open-datum-tests` and `keri-stub-tests`, and one Tasty suite, `cleanup-control`. The record-value entrypoint defines its examples inline, under the module name `Main`. Contract checks include repeated runs of the same case list against different adapters, each wrapped under its defining module. Development-node evidence descriptions and conformance appendix markers remain inside the module groups.

Each suite runs in one hosted job, named in the second column. A suite that no hosted job runs is not evidence for a pull request, so a new suite is added to this table with the job that runs it.

| Suite | Hosted job | What the job runs |
|---|---|---|
| `cage-tests` | `journey` | `nix run .#cage-tests` from `offchain/`, after the narrated registry journey |
| `e2e-tests` | `e2e-part` | `nix run .#cage-tests-e2e -- --match "{lane:…}"`, one development-node lane per matrix entry |
| `contract-tests` | `contract` | `nix run .#contract-tests`, the adapter contract |
| `record-value-tests` | `naming-validators` | `nix run .#record-value-tests` over the naming validators' blueprint |
| `conformance-tests` | `conformance-checks` | `nix run .#conformance-appendix-tests`, the Hspec appendix of the conformance book |
| `cleanup-control` | `evaluation-cleanup-controls` | the evaluation spike's four cleanup controls, `nix run ./conformance#evaluation-cleanup-controls` |
| `open-datum-tests` | `open-datum-tests` | `nix run .#open-datum-tests` from `applications/open-datum/offchain/` |
| `keri-stub-tests` | `keri-stub-tests` | `nix run .#keri-stub-tests` from `applications/keri-stub/offchain/`, including the producers' group |

Beside the suites, the check `tagged-law-consumers-check` reads the consumers of the tagged-request law: the statement bindings of the conformance stories against the accepted model, the negative host, the journeys and rehearsal scripts, the retained entrypoints, and these pages. For the journeys it also runs the helpers that read a booking's and a fold's receipt over receipts it builds in the producers' shape: a registration receipt names a processing deadline and a termination receipt names none, and a damaged copy of each helper must be caught; those receipts are built by the check and no node printed them. It runs as `nix run .#tagged-law-consumers-check` in the hosted job `tagged-law-consumers`, and its rows that belong to the hosted lanes still on the earlier law are listed as residual, not as passes.

The public conformance command `nix run .#conformance-tests`, run from `conformance/`, executes the live product book as well as its appendix. Use `nix run .#conformance-appendix-tests -- --match "[conformance]"` to filter the Hspec appendix alone. The published book's requirement text and receipt-computed coverage are unchanged by these harness labels.

The evaluation spike's `cleanup-control` uses Tasty, so it is outside this Hspec vocabulary. Naming's direct-GHC codec and drift programs are not Hspec suites either. The Cabal-declared `Conformance.Support.Authenticate` module was already absent from the Hspec entrypoint; it remains inactive so tagging changes neither suite membership nor example counts. No new exclusion is introduced.

## Checks execute unit binaries

From `offchain/`, build the unit checks directly:

```sh
nix build .#checks.x86_64-linux.cage-tests
nix build .#checks.x86_64-linux.record-value-tests
nix build .#checks.x86_64-linux.cage-test-vectors
```

From `conformance/`, `nix build .#checks.x86_64-linux.conformance-tests` executes the Hspec appendix. Each check runs its existing app or binary during the Nix build, fails when that execution fails and retains the output at the check's store path. A cached result represents an earlier successful execution on the same inputs. The vector command generates vectors; it is not an Hspec suite. Record-value checks receive the naming validator blueprint compiled from the current source. Apps and supported package exports remain available.

The development-node suites and the live conformance book stay executable apps. Compiling or listing their examples does not establish live ledger behavior. The inventory discovers the Hspec entrypoints from Cabal, rejects unwrapped spec calls and unknown tag constructors, and exercises removal and unknown-tag controls. It is a source inventory; compiled paths and before-and-after example counts supply the separate runtime evidence.

## Observed selections

On 6 October 2026, the three selections above executed 69, 18 and 341 examples respectively, each with zero failures. Compare a future run's actual summary with this dated measurement; test additions can change the counts.

| Selection | Executed examples | Failures |
|---|---:|---:|
| Time area | 69 | 0 |
| Network-time module prefix | 18 | 0 |
| Provider area, skipping history | 341 | 0 |

The full off-chain suite has 1,037 examples, the conformance appendix 573, the end-to-end suite 69, the contract suite 48 and the compiled record-value suite four. Tagging preserves their example counts. A dry run establishes the census of development-node examples, not execution of their scenarios.
