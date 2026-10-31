# Modules for hand-built transactions refused by the deployed validators

Issue 764, first slice. Responsibilities and the direction of dependency. Fields are in [the data model](data-model.md) and
signatures in [the functions model](functions-model.md).

| Module | Responsibility | Depends on |
| --- | --- | --- |
| Hand-built refusals driver (`tools/no_pin_hand_built_refusals.sh`, new) | Makes the starting registry with the packaged commands, asks the harness for each attempt and control, judges every verdict from the node's answer and the chain's own record, shows each assertion failing on altered input, writes the verdict table and the receipts | the shared development-network rig, the packaged open-datum command, the harness, the chain view |
| Refusals harness (`no-pin-refusals`, existing test-only tool) | Builds one hand-made transaction per case with the repository's transaction builders, from what the ledger provider session reads, with one fact made wrong or restored; submits it; prints one JSON object | the open-datum library builders, the registry bundle and ledger-provider modules |
| Nix app (`no-pin-hand-built-refusals`, new) | Packages the driver, the packaged command, the harness and the chain view for one run | the existing development-network app constructor |
| Workflow job (new, in `registry.yml`) | Runs the app on the hosted runner and keeps the verdict table | the nix app |
| Declared-checks census row | Holds the app as hosted | the workflow job |

## Dependency direction

The driver depends on the harness and on the packaged command; the harness depends on the library; nothing in the library
or the packaged commands depends on the harness or the driver. The packaged commands decline wrong requests before sending,
so the means of building a wrong request stay in the test-only harness and never move into a product command or a library
module.

## Placement

No abstraction is promoted. The shape of a case (build, submit, judge, restore, judge) already lives in the termination
refusals driver and the registration refusals driver; this ticket uses the shared rig for everything the rig holds (the
check-and-control helpers, the chain view, the wallets) and keeps the three judging functions in its own driver. The two
existing drivers are not edited.
