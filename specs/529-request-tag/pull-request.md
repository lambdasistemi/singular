## What changed

A registration or a termination is now a tagged request. The booking mints a tag that its request commits to, and the fold finds the booking by that tag instead of by an approval. A termination no longer releases the key's custody to its controller: the booking spends the custody into the request, and the fold burns the key's token and donates the held value less the declared tip to the treasury. `singular registry reject` is retired: it refuses by name before it reads, signs or submits anything, and a booked request leaves the registry through the fold or through its owner's reclaim.

The producers (`open-datum` and `keri-stub`), the command-line journeys, the closed-datum journey, the rehearsal scenes, the two-actors harness, the negative host and the conformance stories read and print the new shape: `transfer` for what a booking moves into its request and `donation` for what a fold gives the treasury, in place of `released` and the deposit return. The reject succeeds nowhere in the journeys; each one that used it now shows the refusal and the owner's reclaim.

## Why

The registry's request carried a deposit that a registry reject could return, and an approval token that the state script had to trust. The ruled design books by a tag the request policy vouches for, never spends the state output on a rejection, and gives a termination's custody to the treasury. This is issue [#529](https://github.com/lambdasistemi/singular/issues/529) of the protected-rejection work, [#498](https://github.com/lambdasistemi/singular/issues/498).

A user who followed the earlier release would have seen a termination return the deposit and a reject clear a stale request. Neither happens now, and the documentation says so wherever it used to say otherwise.

## How to verify

Each check is a hosted job; the jobs run at the exact head of this pull request, and their links are added when it is pushed.

| What is checked | Command | Hosted job |
| --- | --- | --- |
| The consumers of the tagged-request law: statement bindings against the accepted ledger, the negative host, the journeys and the way their helpers read a booking's and a fold's receipt, the retained entrypoints, the pages and these limits | `nix run .#tagged-law-consumers-check` | `tagged-law-consumers` |
| Producer tests of open-datum, including the carrier and the preparation fee | `nix run .#open-datum-tests` in `applications/open-datum/offchain` | `open-datum-tests` |
| Producer tests of keri-stub, including the producers' group | `nix run .#keri-stub-tests` in `applications/keri-stub/offchain` | `keri-stub-tests` |
| The off-chain unit suite | `nix run .#cage-tests` in `offchain` | `journey` |
| The development-node lanes | `nix run .#cage-tests-e2e -- --match "{lane:…}"` | `e2e-part` |
| The conformance stories and their appendix | `nix run .#conformance-appendix-tests` in `conformance` | `conformance-checks` |
| The component builds | `nix build .#component-build` in `offchain`, in `applications/open-datum/offchain` and in `applications/keri-stub/offchain` | `offchain-component-build`, `open-datum-component-build`, `keri-stub-component-build` |
| The conformance stories run against the node | `nix run .#demo1-cli-controls` | `demo1-refusals` |
| The negative host's refusal pairs and mutants | `nix run .#negative-host-part -- PART`, `nix run .#negative-host-mutants` | `negative-host-part`, `negative-host-mutant`, `negative-host-mutant-self-check` |
| Node confinement | `just node-confinement` | `dev-shell-checks` |
| The code inventory | `nix run .#inventory-check` | `inventory` |

## Lean correspondence and constitution

Model revision: `bf43bd1e06d8aee774bc4a9f670de27d2f603ad7`, the commit whose statement ledger is the one in `applications/open-datum/ledgers.json`. The conformance stories read this revision from `conformance/model-revision`. The published evidence page keeps its historical runs bound to the revision they read, `de34300540223ccedf1ca85216b131fd09a148b4`, recorded in the snapshot, and names the current revision in a separate row; it does not relabel a historical run as evidence for the current model.

User story: As a registrant, I book a key and a fold delivers it to the application under my envelope; as its controller, I book its termination and a fold takes the custody in, burns the key's token and donates the held value less the tip; as anyone else, I cannot book it, update it or release it.

Implementation entry points: `bookRegistrationImpl` and `bookTerminationImpl` book; the fold's donation is the transaction's treasury donation; the producers print `transfer` and `donation`. The conformance stories tell two accepted statements from receipts, each under its accepted digest: `update_payload_free` and `update_requires_controller`. Fourteen accepted statements are uncovered and published as such on [the consumer conformance page](../../docs/consumer-conformance.md): `duplicate_refused_by_registry`, `resurrection_refused_by_registry`, `bookInsert_inversion`, `insertion_requires_registry_identity`, `bookTerminate_inversion`, `fold_inversion`, `only_termination_booking_transfers_custody`, `fold_routes_economics` and `termination_fold_donates_held_minus_tip` are told by no clause; `insertion_holding_inline`, `update_keeps_registry`, `update_preserves_custody`, `update_inversion` and `termination_fold_burns_atomically` are observed in part by a clause that claims no statement, because their conclusions have parts no receipt shows (the burns of the key's tag and of the request tags, the delivered output's address and registry tag, the converse of the update step). That page leads each row with the requirement in words and lists, for every told statement, what the receipts show and what they do not.

The mapping of outcomes, authorization, state changes, token identity and custody: a booking is authorized by the controller's signature and spends the custody; the registry's root changes only in the fold; the key's token is burned by the fold; the custody goes to the treasury less the tip and to nobody else. The negative host's short-fold pair expects the registry's state validator to refuse a fold whose donation is one lovelace short, beside the honest fold that donates the held value less the tip; its release pair expects the application's spending contract to refuse a release outside the fold. The hosted run judges both.

No model error, ambiguity or conflict is being accepted as a passing behavior: what the suite cannot tell is published as uncovered, and the rows on the earlier law run as retired booking rows that claim no statement.

- [ ] The change follows the repository constitution; model binding and evidence, or the reason runtime behavior is unchanged, are recorded above.
- [ ] No unresolved model error, ambiguity, contradiction or missing required evidence is being accepted as a passing affected behavior.

## Limits

- **Inclusion and signature conditions the builders cannot verify.** The builders guard what the body and the facts they acquired decide. Six conditions are decided only at inclusion or by a signature and are not verified here: `BadInputsUTxO` (an input spent between the build and the inclusion), the mempool refusal when all inputs are already spent (all inputs spent), `OutsideValidityIntervalUTxO` and `OutsideForecast` (the slot at inclusion against the validity window and the era forecast), and `MissingVKeyWitnessesUTXOW` and `InvalidWitnessesUTXOW` (a required signature that is missing or invalid; the derived witness count does not verify a signature). A folder race and an expired window are ordinary submission outcomes.
- **Typed constructors are forgeable.** The typed booking records can be built by any caller; the tests make no provenance claim for them.
- **Cached builds.** The signed-head checks run through Nix; a cached result stands for an earlier successful execution on the same inputs, not for a fresh build.
- **11 pending.** The registry suite reports 11 pending examples, earlier provider rows that the raw-facts fixture does not support. They are not passes.
- **Fixed application-burn convention.** The fold burns the application's token with the fixed redeemer `Constr 0 []`; the tests do not vary it.
- **Node confinement is source confinement only.** `just node-confinement` shows that no producer path reaches a node interface; it says nothing about behavior against a node.
- **Narration of the edited pages is stale.** The clips of the pages this change edits (the node reference, the Demo 1 pages, the test-selection page, the conformance page and four small pages) are regenerated with the rebase onto current main; until then the narration step of the documentation check reports them stale, missing or orphaned.
- **Nothing here ran against a node.** No devnet, journey, hosted job or fresh Koios read stands behind the local runs; the hosted board at the exact head is the evidence.
- **The journeys and the negative host's new parts were edited, not run.** The Demo 1 journey, the closed journey, the keri-stub journey, the funding script, the rehearsal and the negative host's short-fold part read the new receipts; no node ran them here. The journeys check that all of a custody enters its request and that the fold's donation lies strictly between nothing and the transfer; only the negative host's short-fold pair checks the donation exactly. Unrelated ordinary payments to a controller's address are allowed and are not examined. The journeys read a booking's and a fold's receipt with helpers that tell a registration, which has a processing window, from a termination, which has none and whose receipts print the deadline null; the consumers check runs those helpers over receipts it builds in the producers' shape and damages each helper in a copy to see that it notices. Those receipts are built by the check, not printed by a node.
- **Hosted lanes still on the earlier law.** The development-node specs, `insert-active`, the narrated `journey`, the library's legacy edge builder and the conformance rows that book by hand still use the untagged request and the approval. They are listed as residual by the consumers check and are moved to the tagged-request law before this change merges. Nine retained row runners are not retold, built or verified on the tagged-request law; seven are owned by [#172](https://github.com/lambdasistemi/singular/issues/172), and two were closed as not planned ([#283](https://github.com/lambdasistemi/singular/issues/283), [#282](https://github.com/lambdasistemi/singular/issues/282)).
- **Production node discovery is uncovered.** Production discovery is accepted through the public index only; no public node interface reads the request address.
- **Open rows.** Six public implementation rows of [#498](https://github.com/lambdasistemi/singular/issues/498) stay open; nothing here closes them. Reference-state rejection, generic open custody and keri-stub custody are uncovered by the conformance stories.
