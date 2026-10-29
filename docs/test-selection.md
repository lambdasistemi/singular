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

The registry and conformance Cabal manifests declare four Hspec suites: `cage-tests`, `e2e-tests` exposed as `cage-tests-e2e`, `contract-tests`, and `conformance-tests` exposed for filtering as `conformance-appendix-tests`. The application separately declares `open-datum-tests`. Contract checks include repeated runs of the same case list against different adapters, each wrapped under its defining module. Development-node evidence descriptions and conformance appendix markers remain inside the module groups.

From `conformance/`, use `nix run .#conformance-appendix-tests -- --match "[conformance]"` to filter the Hspec reader appendix.

The evaluation spike's `cleanup-control` uses Tasty, so it is outside this Hspec vocabulary.

## Checks execute unit binaries

From `offchain/`, build the unit checks directly:

```sh
nix build .#checks.x86_64-linux.cage-tests
```

From `conformance/`, `nix build .#checks.x86_64-linux.conformance-tests` executes the Hspec appendix. Each check runs its existing app or binary during the Nix build, fails when that execution fails and retains the output at the check's store path. A cached result represents an earlier successful execution on the same inputs. Apps and supported package exports remain available.

The development-node suites stay executable apps. Compiling or listing their examples does not establish live ledger behavior. The inventory discovers the Hspec entrypoints from Cabal, rejects unwrapped spec calls and unknown tag constructors, and exercises removal and unknown-tag controls. It is a source inventory; compiled paths and before-and-after example counts supply the separate runtime evidence.

## Observed selections

On 6 October 2026, the three selections above executed 69, 18 and 341 examples respectively, each with zero failures. Compare a future run's actual summary with this dated measurement; test additions can change the counts.

| Selection | Executed examples | Failures |
|---|---:|---:|
| Time area | 69 | 0 |
| Network-time module prefix | 18 | 0 |
| Provider area, skipping history | 341 | 0 |

At that measurement the full off-chain suite had 1,037 examples, the conformance appendix 573, the end-to-end suite 69 and the contract suite 48. These are historical counts; removal of an old subject changes its suite membership. A dry run establishes the census of development-node examples, not execution of their scenarios.
