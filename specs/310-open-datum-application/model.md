# Open-datum application: executable model and intended statements

Phase: MODEL + STATEMENTS + INVERSIONS; occurrence-safe re-cut `310-occurrence-001` on the preserved first repair. All 32 statements are **stated, unproved** (`sorry`). Nothing here is a validator, a compiled identity, a builder or ledger evidence.

## Where it lives and how it builds

- `applications/open-datum/` is an isolated Lake project. `lakefile.lean` requires the unchanged root project (`require singular from "../.."`). It has no `lean-toolchain` of its own: the root `application-model` recipe checks the selected `lean --version` against the root pin `leanprover/lean4:v4.25.0`. The Lean-DSL manifest is used because the repository inventory classifies `lakefile.toml` and `lean-toolchain` only at the root.
- Library `OpenDatumApplication`: `Model` (the law), `Statements` (statements and inversions) and `Driver` (codecs, corpus, ledgers, checks). The executable `open-datum-application` has these modes:
  - `write DIR` writes the corpus and the ledgers;
  - `check DIR` regenerates both and compares them with the committed files, and replays every scenario;
  - `check DIR` also runs its own controls: a changed recorded outcome must be noticed by replay and by the corpus comparison, a dropped theorem row by the ledger comparison, and each of three definition mutants of the law (no update signer check, no registry-asset check, per-floor instead of additive settlement) must run at least one scenario differently;
  - `run appStep` runs one scenario from standard input.

## The law

- **Book an insertion.** The controller signs. The application serves the registry whose full state asset (policy and name) the world actually carries, and the envelope names that same asset. The destination is this contract with the envelope's hash. The protected deposit is the request's deposit.
- **Book a termination.** The controller signs an `updateTerminal` approval for the key its live output holds, naming no destination. Token and deposit stay locked.
- **Book any other edge.** Refused: this application certifies only insertions and terminations.
- **Update.** The controller signs. Exactly one proposed output carries the token, at this contract, with the same control and assets and at least the deposit. The payload is free.
- **Fold.** Any selection of booked requests is folded by the registry's own `foldBatch`:
  - insertions create this contract's outputs, re-checking their envelope binding and registry;
  - terminations spend their keys' outputs and release their deposits;
  - the whole payment duty — each selected request's `Singular.obligations` by its edge, plus every release — settles through the unchanged `Singular.settle`, against the outputs plus the created deliveries;
  - the world records the fold's own mint.
- **Reject.** The registry's reject of one booked request, refund settled. Application outputs are untouched.
- **Withdraw.** Every other spend is refused.

## Finding dispositions (review 310-model-001)

- **F310-001 (unrestricted-world statements).**
  - Properties that depend on consistency now take `Reachable w`. `AppConsistent` states that consistency, and three obligations cover every constructor: `genesis_consistent`, `appStep_preserves_consistent` and `reachable_consistent`.
  - Single-step guard properties and the exact inversions still hold over any world, and say so.
  - Over unrestricted worlds, `update_preserves_custody` and `release_burns_atomically` are false for a world holding two outputs of one key; `AppConsistent` excludes it, the law does not. A booked insertion whose envelope never bound its request is no longer such a counterexample: the fold re-checks the binding in `selectRow` and refuses `fold-envelope-binding`.
  - Re-cut `310-occurrence-001` (finding F310-R1-001): the previous uniqueness clause compared output values, so an inventory holding one identical output twice, `[o, o]`, satisfied it; an accepted update erases only the first copy and appends a new reference, leaving two different outputs of one key, which made the preservation obligation false as typed. `AppConsistent` now also requires the references to be pairwise distinct, so every output occurrence is held once. Preservation is stated per accepted constructor (`bookInsert`, `bookTerminate`, `update`, `fold`, `reject`) over every consistent world; `bookOther` and `withdraw` accept nothing. `erase`, the law and the root model are unchanged.
- **F310-002 (additive rows).** `fold_settles_additively` binds the rows to exactly what `selectRow` chose (`sel.mapM (selectRow …) = .ok rows`). Each release is the spent output's own protected deposit to its own controller. Every recipient receives at least the sum of its floors.
- **F310-003 (registry identity).**
  - Booking requires the application's registry and the envelope's to equal the world's actual state asset. The fold re-checks both for insertions and terminations.
  - Controls:
    - `registry-asset-other-name` (50/52) and `registry-asset-other-policy` (60/51) are refused at booking;
    - `envelope-names-other-registry` is refused;
    - `lifecycle` accepts the same identity.
- **F310-004 (burn).** `release_burns_atomically` states that the fold's own mint equals the registry's summed delta of the selected requests and holds exactly −1 of each released key's active token. The key is Terminal and its spent output gone after the fold. The world publishes `lastMint`. Concrete policy and burn-source enforcement remain later, compiled evidence.

## Correspondence limits (implementation boundary)

- **Settlement.** Settlement covers the selected requests' registry obligations and the releases; the fold may mix insertions and terminations (`mixed-batch-one-controller`). A request's tip goes to the folder and fees and minimum-output funding are the transaction's; the model states them nowhere, and a protected deposit is never counted toward them because every release is a separate floor.
- **Retraction.** A retraction's admission (`Singular.retractAdmission`) is not exposed by this application; only `reject` is.
- **Representation.**
  - `PlutusData` and FNV `envelopeHash` stand in for CBOR and blake2b-256; no byte agreement is claimed.
  - `App.policy` is both the policy and the address.
  - A destination is `address · 2^64 + envelopeHash`.
  - A termination names no destination (`output = 0`). The generic model's destination row for a non-delivering fold is #304's held question.

## Coverage

- Every statement is bound to at least one of 27 scenarios or 2 boundary worlds. Each scenario publishes the world after every accepted step: registry, outputs, bookings with their required signers, and the last mint. Intermediate conclusions are therefore observable, not only final worlds.
- The corpus exercises one controller, keys 5 and 6 and fixed amounts. It exhibits the statements and does not cover their domains.
- The three definition mutants move 1, 3 and 3 scenarios respectively. They are controls on the checks, not a mutation campaign over the law.

## Invariant boundary (310-occurrence-001)

- `appConsistentB` observes `AppConsistent` conjunct by conjunct, the registry through the root driver's own `Singular.Driver.consistentB`; its exact correspondence is the stated obligation `appConsistentB_iff`, unproved.
- Every scenario publishes the observation at genesis and after every accepted step. `check` requires it true for all of them, and requires an accepted step for each accepting constructor: `bookInsert`, `bookTerminate`, `update`, `fold` (insert, terminate and mixed) and `reject`.
- The corpus publishes two boundary worlds:
  - `ordinary-after-insert`, reached: consistent; the signed update is accepted and its successor is consistent;
  - `identical-duplicate-occurrence`, the same world with its output held twice, not reached: not consistent; the same update is accepted and leaves two different outputs of key 5, the previous counterexample now outside the preservation domain.
- Control: the observation without its occurrence clause admits the duplicate world, so the clause is what excludes it.
- These are bounded executed observations of the published worlds, not proofs of the universal statements.
