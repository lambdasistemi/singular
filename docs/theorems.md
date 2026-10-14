# Theorem manifest

As a proof reviewer, use this register to identify exactly which statements the
registry-mode model supplies, that each one is proved, and from which axioms.
Every declaration keeps its qualified name and a digest of its statement text, so
a changed or missing obligation is detectable rather than merely unlikely.

All 59 declarations of the registry's own statement module are **PROVED**
from the standard axioms — `propext`, `Classical.choice`, `Quot.sound` — and
nothing else. The naming instance adds 7, its lifecycle 9
and its wire encoding 5, for **80** in total, each with its own
manifest and its own compiled gate.

The operator-authorized source removal retires ten declarations about excluded success behavior. Their historical proofs and receipts remain on `preserve/m2/pre-m1-source-removal`; they do not certify permanent contract. The active model retains the applicable invariant, exit, refund, datum and public-fold laws. Public unmet consumer requirements remain uncovered.

## What the eleven promises are

The interface states eleven guarantees the registry makes for *every*
application, and the model proves each one over states reachable from genesis by
folds. Reachability is a hypothesis, not a weakening: over an arbitrary `State`
value the supply laws are simply false.

```mermaid
flowchart TD
    G["Reachable state<br/>(genesis, closed under accepted folds)"] --> C["Consistent:<br/>root commits the map,<br/>supply laws, custody soundness"]
    C --> S3["Supply matches leaf state<br/>Active witness unique<br/>Absent witness unique<br/>Witness kinds exclude"]
    C --> S1["Terminal attestation soundness"]
    S1 --> S2["Terminal attestation permanence"]
    C --> O1["Booking requires an untaken key"]
    O1 --> T1["Terminal key cannot change"]
    C --> P1["Tree change requires approval"]
    C --> L1["Request spent once in order"]
    S1 --> W3["Terminal witnesses may be plural"]
```

Every promise is reached through one invariant — `Consistent` — that the model
proves survives each supported transition. That is why the statements read as
consequences rather than as separate arguments.

## Exact declaration inventory

| Qualified declaration | What it states | Statement SHA-256 | Status |
| --- | --- | --- | --- |
| `Singular.Statements.absent_witness_unique` | absent-witness-unique — the absent witness is unique | `968c72784fe79c81a9296e74e23df3d4afa19f99a3ed616fc73d417f3e24053a` | PROVED |
| `Singular.Statements.active_witness_unique` | active-witness-unique — the active witness is unique | `76745382fd82c31a71125904f0c9e558e2ee4b770df5224ceaf41aac93ef3879` | PROVED |
| `Singular.Statements.admission_refuses_first` | Retraction, before anything is paid — a retraction its admission refuses builds no transaction and is refused with admission's reason whatever it spends and pays: beside a state token, or paying its owner nothing, it still names the admission check it failed; any other exit, and an admitted retraction, is judged as before, by what it spends (`retract-state-spent`) and then what it pays | `a021ed02814e177fa37fa6996054ca8a5ed0413e8a3093129e7be5960b0010eb` | PROVED |
| `Singular.Statements.admitted_exit_is_the_exit` | Retraction, once admitted — an admitted retraction is the retract exit itself: its step and its transaction are exactly the exit's, so it pays what the exit owes, leaves the registry as it was and requires the owner's signature alone; a fold or a reject is unchanged whatever the retraction witness says | `ef8187d635d0ed65365eae4fbdfe85c44fa423a8fa5ebcc03d3e95f4886762fd` | PROVED |
| `Singular.Statements.at_most_one_pending_termination` | At most one pending termination per key, counting occurrences in the pool, not merely distinct values. This follows from supply shared with custody. | `fc59d58c6b0f3723b28f48a68a51abca044a10b3a34554fa734d6c8b6e48d6c2` | PROVED |
| `Singular.Statements.balanced_transaction_conserves_value` | The balance judgement conserves lovelace including explicit fee and donation, all native assets after mint, and every state-token identity present on either side. Only the unspent set supplies spending values. | `6f463431f4a5d5bb1bf32f641b8d820ddb67ec53c04125e97fd896135283621d` | PROVED |
| `Singular.Statements.batch_burns_only_live_holdings` | Every termination in an accepted batch has an active holding in the state from before that batch | `a41747f7a66da028b998e3ce27edf19c4419ee232ce0030092291a0e82009e06` | PROVED |
| `Singular.Statements.batch_cannot_consume_what_it_creates` | After all steps admit and the keyed mint balances, an insertion followed later in the same batch by termination of its key is refused token-missing | `bbefd4458236ec7ab7e28fe8f7f7690a9e05fb31b3d93ae54b524dca7085afad` | PROVED |
| `Singular.Statements.biconditional_supply_sync` | supply-matches-leaf-state — sync: biconditional supply is 1 iff the key is in that token's state | `7f1089607f7d6578eac69fb4b68bb4147853f29c6b6ac4067eb0db9e667f3f68` | PROVED |
| `Singular.Statements.booked_at_most_once` | request-spent-once-in-order — a key is booked at most once at a time; the batch is atomic; a request is spent once | `1c8b3268586a2ca2aaf930c3a45b0f8fde24c061f0ff63bf8962afbb42eb1ec2` | PROVED |
| `Singular.Statements.booked_request_has_exact_contents` | Every pending registration has exact contents, including the minimum tip and full application binding. Both tags were minted with that very request. The carrier is a declared allocation, not a measured ledger minimum. | `ec769c8c86bc37e980a9232ca4757735d50eeb6553c00544c2f3b37223802c1e` | PROVED |
| `Singular.Statements.booked_time_is_interval_end` | The pool keeps the booking transaction's interval, and the pending registration's booked time is exactly its upper end. | `86d8a38ebe2a03232e278407a4deb3f51ad82f4d942140d8b5c86990ef50ef65` | PROVED |
| `Singular.Statements.booked_time_not_before_inclusion` | For every actual inclusion time within the original half-open interval, the booked time is no earlier. Hence the expiry threshold is no earlier than both windows after inclusion. This states the threshold, not exit admission. | `63ebcb7a3f9d8bf326674e19c297fc13187eade456c13637641a1e8e34a0bdb3` | PROVED |
| `Singular.Statements.booking_width_within_limit` | Every pending registration was booked in a nonempty interval whose width is at most the pinned maximum. Empty and reversed intervals cannot exploit natural-number subtraction to pass the width rule. | `5d12a9178a46bc78852ba4af63ee95a28713b278e2c9b7e37d1c8c5ac32e1c49` | PROVED |
| `Singular.Statements.built_transaction_settles` | Every transaction an exit builds pays what the exit owes: for every state, exit, request and lovelace, a transaction the model builds settles the exit's obligations — the deposit at the cage, the named destination or the owner, and a retract's tip | `b5b45e560df2c4d3050466fd00b895dd61280d5b89c834bb2612c52c9b104796` | PROVED |
| `Singular.Statements.delivered_datum_is_request_datum` | #419 — a delivered output carries exactly the datum its request carries, for every successful permanent contract fold: inline with the request's datum when it carries one, no datum when it carries none | `76247fab5884aefffb7639b05675206c16b48c191fb0bd8c63ce87afba58c4a5` | PROVED |
| `Singular.Statements.destination_output_iff_delivers` | #304 — a fold describes a destination output exactly when it routes a token to the requester, for every successful permanent contract fold: a fold that delivers nothing has no destination output, and the state, custody and owner outputs never take that role | `9fd337105c38a57f0413922e5eafc62bac2e388314b290e614d0ea805dd3a38b` | PROVED |
| `Singular.Statements.empty_fold_error` | — | `8bd6ec570fbda5220c7d841d4396605cf637e094bdeb275d7495f7169a4a1f06` | PROVED |
| `Singular.Statements.exit_settles_on_lovelace_received` | Value an exit does not owe is unconstrained, for every exit alike: when each recipient the exit owes that some output of a first list reaches is reached by some output of a second, and receives at least as much from the second as from the first — the summed lovelace of the outputs paying it by role, address and, for a destination, datum, or for a retraction's return bound to its request the largest such output — the second settles whenever the first does: adding outputs or lovelace never unsettles a transaction, and fees and the folder's tip play no part | `efdbcb44050b3bebb5c73d95e04fe8653ebe92e0c8c4a81b7b87347872427a12` | PROVED |
| `Singular.Statements.expiry_after_reclaim` | An admitted expiry rejection begins after every admitted retraction's excluded upper bound for the same booked request, regardless of witness time | `f6c06a2ce273ed86fb655a9f25ff1c8b7cc756cba76aff6f866d223db67bd952` | PROVED |
| `Singular.Statements.fold_batch_claimed_mint_by_kind_key` | the fold's mint guard is per `(TokenKind, Key)`, strictly finer than a per-kind one, witnessed by a reachable state whose equal-per-kind batch is observed to be refused | `9c01e278443498d3488e6671cc1799393f565a2a1c0055c1926a8d3e559da988` | PROVED |
| `Singular.Statements.fold_batch_cons` | — | `a0992d97ae5b6f86503bdc5247b4b2602ec74a5516713e274c4919aa53d5d26f` | PROVED |
| `Singular.Statements.fold_batch_of_one_is_step` | A batch of one folds as its step — for one request whose claimed mint is its own edge's delta, `foldBatch` over that request alone is exactly `step`: refused for the same reason, or accepted with the same state, mint and payments | `09dc61dcbe8e7a4a68b170944bb42cdcf6ece9af9fc006af96135cfab1185f87` | PROVED |
| `Singular.Statements.fold_inputs_public` | #419 — fold inputs are public: the transaction a fold builds is the one any party builds from the public view, the registry state with its holdings and their datums and the request pending at the cage, found by its own output reference | `ece9dd0fd104368b34cf5bf210ed46ffca39a13ba70f05ead901d381a6cb0d1f` | PROVED |
| `Singular.Statements.fold_refuses_foreign_datum` | #419 — a foreign datum is refused: an observed fold delivering a token, whatever the request's deposit, whose every destination output carries a datum other than the request's — another value, a datum where none is carried, none where one is, a datum presented by hash — or that has no destination output at all, is refused `destination`, as the cage refuses a carrier that does not match | `fd23c815f71328cb0595763ea280845bfd28b4aa5b78022080afd43fb12f4aba` | PROVED |
| `Singular.Statements.fold_requires_no_signer` | no fold requires a signer: for either supported edge the transaction the model builds has an empty signer list, and neither the step nor the transaction changes when the approval carries a different signature set | `7c24885ca77300bda88d97830ff54d237ddca2de3e3fdbd93cb1239a51a3eece` | PROVED |
| `Singular.Statements.independent_requests_fold_as_a_batch` | A non-empty batch on pairwise distinct keys is accepted when each request admits alone from the same state and claims its own keyed edge mint | `24f639316fc0122e22647bc7d230a6dfabdacfd4b75c8d28cb4f9b46623f2756` | PROVED |
| `Singular.Statements.insert_active_inversion` | — | `df737501c3c51c4968eb5adcc658f74473984613c591b4886fa092c15e35dc9d` | PROVED |
| `Singular.Statements.insert_active_transaction_row` | the transaction an admitted `insertActive` builds: the whole constructed value — two inputs, two outputs, their datums, addresses and assets, the destination output holding the deposit with the token and carrying exactly the datum the request carries, inline, or none when it carries none, the deposit to the destination as its one payment, the keyed mint, no required signer — plus universal open admission and the duplicate-key refusal | `6073c296c90657ef193368669ef07ce6d97eddaa9d2059771e23fe156b61b868` | PROVED |
| `Singular.Statements.live_compatible_request_protected` | A lifecycle-compatible request cannot be rejected before expiry, regardless of the evidence the processor chooses to supply | `bc7f7681634a2db1d3c5f0b149fcdab99bfe82bed17d56bcb00afae67b8f6047` | PROVED |
| `Singular.Statements.no_exit_strands_the_deposit` | No exit strands a deposit: for every exit and every request, some payment the exit owes is at least the request's deposit | `a2e9655f8a61d303518851ef9907dcfca817d1d05a8071f7104974c2c522230a` | PROVED |
| `Singular.Statements.no_tree_change_without_approval` | tree-change-requires-approval — no tree change without an approval under the pinned policy; the pins never move | `675ac9aa1522c14f7f620861bbea5194b21721f612e594c6aa48fe9b753f248b` | PROVED |
| `Singular.Statements.obligations_read_only_the_request` | What an exit owes is read off the request alone: for every exit, two requests with the same owner, deposit, tip, destination — its address and the datum it carries — and output reference are owed the same payments; the obligations take no registry state as input | `7bafe21aa0e17e85bc8221746fe6f484e6f046fe42d237e55a3cdebe93a4017a` | PROVED |
| `Singular.Statements.occupancy` | booking-requires-untaken-key — a booking edge succeeds only on a key that is not taken | `b6760b43f9a243015d269f18ac4932eaf9a3887571df7d6637ef63bb4a7e4b40` | PROVED |
| `Singular.Statements.occupancy_free_key_succeeds` | booking-requires-untaken-key, converse — a booking edge on an untaken key succeeds | `4ee0061a9b764b5548095be259818f55f9beb79907770d850ab4c082b2bbe350` | PROVED |
| `Singular.Statements.only_retract_owes_the_tip` | Only a retract owes the tip: for every exit, what it owes is unchanged by the tip a request holds exactly when the exit is not a retract | `df27296176ea7a88ac2d8fcaf3047e5521838fe9dabe493183ef26ac21dd624f` | PROVED |
| `Singular.Statements.overlapping_reference_is_spent` | The disjointness premise is necessary: this concrete overlapping input is spent by the raw update, whatever value its output carries. | `25057afc351d9ee2b4a83818544cd1758c3321a3d9610c9e855d8e6ce31a3fd3` | PROVED |
| `Singular.Statements.parameters_preserved_by_batch` | Every successful atomic batch preserves every parameter, including when a later request reads a state produced by an earlier request in that batch. | `f3c594ddec6a8d649e94d442da0ddaafcdf3557989fdaf630b15b0f111e4f76a` | PROVED |
| `Singular.Statements.parameters_preserved_by_fold` | Every successful fold step preserves the registration cost, minimum tip, maximum booking width, registry identity, windows, fee ceiling and policy pins. No relation between the fee ceiling and minimum tip is assumed. | `c73c54081ec6ae72ee73d9bc4d7d178e2af1e5f4f43db5937a1fb8e9f2598f16` | PROVED |
| `Singular.Statements.protected_rejection_effects` | Every admitted rejection preserves the full intermediate state, mints nothing, and pays the existing deposit obligation | `91c17bc708609880f867eb88efca930630f4eb91d2d25c618686a81b1a32e66f` | PROVED |
| `Singular.Statements.reference_inputs_not_consumed` | A referenced output survives the raw update when the transaction's spent and reference inputs are disjoint. Without that premise spending wins; this is a state update, not a transaction admission rule. | `2e125ce1ae73d0f9bdaf0c9ec6de4c940c06ddf60bea10d50934a42f79e8b85f` | PROVED |
| `Singular.Statements.reject_batch_of_one_is_reject` | A batch of one reject judges as the reject — the driver's judgement of a one-request batch of rejects, `settle` over its concatenated obligations, is exactly its judgement of the single reject's transaction over the same outputs, whatever inputs that transaction spends | `9f0e815f13a2ce1e41ecd3d19792aa741ade3187fb951fbce6b3fa4b87b1f42c` | PROVED |
| `Singular.Statements.rejection_admitted_iff` | Rejection is admitted exactly for identity-bound evidence and one of its two positive conditions | `cdd9b2e62391bc21750ed601e8e3045ce271467db5af493c8925ca2037091350` | PROVED |
| `Singular.Statements.rejection_without_evidence` | A missing proof never authorizes rejection, even when refunds are paid | `56e1fe9ed8e1ee23a77d9fe19e42d7ec9e6963993637860464727e96df5d1d1c` | PROVED |
| `Singular.Statements.retract_admitted_iff` | Retraction, when — a pending request's owner can retract it exactly when it inserts a key or reads a terminal one, the owner is among the transaction's signatories, and the validity interval lies inside phase 2: from submission plus the processing time, included, to that plus the retraction time, which the excluded upper bound may reach and not pass. The request script names this rule's refusal `not-phase2`: its exact-outcome tests admit the two endpoints themselves and refuse with that name one unit before the lower bound and one unit past the upper, and for an open interval alike | `30f9c66828032bcc4337dc96e5c7e9c8dec6514b0f5c9ad3c0969846e19ce55c` | PROVED |
| `Singular.Statements.retract_pays_exactly_its_obligations` | An executed retract pays exactly what it owes: for every registry state and request, the retract leaves the state as it was, mints nothing, and pays exactly its obligations, the deposit and the tip to the owner through an output bound to the request; nothing the state holds enters its payments | `a9ec205a3afaf4c62ff1e25f396d035fafbd25b34597e858c5468f6f77403390` | PROVED |
| `Singular.Statements.retract_refusal_first_failing` | Retraction, why not — a refused retraction names the first check it fails, in the request script's order: `withdraw-insert-only` for an update or delete request whoever signed and whenever, then `retract-owner` without the owner's signature inside phase 2 or not, then `not-phase2` | `a91793ff8a3c12a3bf4a12632c53a53f4e0d25ff42f40766443a6e4b1d417f71` | PROVED |
| `Singular.Statements.spent_reference_refused` | A spent reference cannot be read by a later transaction: with a fresh creating identity, the raw update has removed it. The later transaction's spending inputs are present so the refusal specifically names the reference. | `05956cb3b5599c5e49722c67ce1b7f77cf9cd7f7bbfd74513c969c58930138c6` | PROVED |
| `Singular.Statements.terminal_attestation_permanent` | terminal-attestation-permanent — permanence: an attestation holds in every later state | `e133aaa076a248d60fc059e2698069b69485c9ba6f3c5a7aa4a209e224c888e2` | PROVED |
| `Singular.Statements.terminal_attestation_sound` | terminal-attestation-sound — soundness: no attestation of an Active, Absent or Unknown key exists | `9cd4b73c811ee93427ae8eab5a96db956d0934eb20f3558117426f5b740b12ef` | PROVED |
| `Singular.Statements.termination` | terminal-key-cannot-change — a Terminal leaf is never moved, so the key is never re-booked | `99a39dc2ba8581b8d2ea5d9c5dfad152d1a506551706eedf14ec36087e1e8bc2` | PROVED |
| `Singular.Statements.termination_booking_has_exact_contents` | Every admitted termination booking has exact declared contents, mints both request tags with the request, and takes one genuine singular tag from its key's active custody holding. | `15dff9f8e1426baeb35591b5b8fde46c363c6a1d828ef1fbfc39b4175b47861a` | PROVED |
| `Singular.Statements.termination_request_carries_genuine_token` | Every pending termination carries exactly the genuine singular tag of its own key and registry, whose leaf remains active. Its retained custody inputs came from an actual accepted booking of a reachable earlier world. | `fb922d86fb9583f36711401337968e922d9da0a58a01c90e6ed7dfb8a36b5559` | PROVED |
| `Singular.Statements.update_terminal_inversion` | — | `55610f5a33da76d49c9f8e5eee2170af33700b0222530d6548629960133bc470` | PROVED |
| `Singular.Statements.update_terminal_transaction_row` | the transaction an admitted `updateTerminal` builds: three inputs, the third spending the key's one active witness so the burn has a source, presenting the datum its holding carries, in form and value, two outputs — the state and an owner output with no datum returning the deposit and naming the approval it returns — the keyed mint of `-1`, the deposit to the owner as its one payment, no required signer — plus the `terminal-immutable`, `key-unknown`, `not-booked` and `token-missing` refusals, each exhibited | `d2402d0c08b3df1258ddf354ef7e4855ceec1dae5f1fe763e0f0189aacb0b560` | PROVED |
| `Singular.Statements.witness_input_datum_is_held` | #304 — a witness a fold spends presents the datum its holding carries, for every successful permanent contract fold, in its form and its value: the datum the delivering fold wrote, the request's own, so a retirement or deletion spends a witness as the chain holds it | `3ddeb0314193a02c809c78b87719c203760548449f42c538a955617534d1f44c` | PROVED |
| `Singular.Statements.witness_kinds_exclude` | witness-kinds-exclude — the three kinds exclude each other | `7013211d47dd903d511e417866114e9beac7d125ce81f40d3a08efbe996bfd1a` | PROVED |
| `Singular.Statements.world_supply_sync` | In every reachable world, the actual singular tags in custody and pending termination outputs total one exactly for an active key, zero otherwise, and never more than one. Each pending termination contributes exactly one such tag. Registry-level consistency is not assumed of the world component. | `677482a96629adb878cea08b3d4d76db1fccf65ee06e8622a3abd67a1deb4d14` | PROVED |
| `Singular.Statements.zero_donation_omits_field` | Zero donation contributes no field to the list actually serialized by the transaction encoder. Positive donations remain explicit. | `5fa265d9c485578f30de49ba67268bb1d27a5af1fbae91d5a2758fefdc39b291` | PROVED |

The naming, lifecycle and wire declarations are listed in their own manifests:
[naming-theorem-debt.json](../lean/naming-theorem-debt.json),
[lifecycle-theorem-debt.json](../lean/lifecycle-theorem-debt.json) and
[wire-theorem-debt.json](../lean/wire-theorem-debt.json).

## How this register is kept honest

A compiled gate in [Audit.lean](../lean/Singular/Audit.lean) runs while the
library elaborates: it collects the axioms of every theorem in the frozen module
and fails the build if any lies outside the three standard ones. Re-admitting a
single theorem turns the build red, so a `sorry` cannot reach this page.

`tools/check_model.py` then cross-checks three things that are easy to let drift
apart: the source declarations against the manifests, the compiled axiom report
against both, and — added after the drift below was found — **this page against the manifest**.
The last one exists because it was missing: before it, the page claimed 41
declarations while the manifest held 44, and three proved statements appeared
nowhere. The check is set equality, and the total above is derived from the
manifest rather than typed by hand.

## What this establishes, and what it does not

These proofs establish **properties of the model**. They do not establish that
the model is the right model, and no build ever will: that is what the operator's
rulings, the interface and the simulation are for. A theorem can also be true and
narrower than its name, so the column above says what each one states rather than
leaving the name to imply it.

The model is abstract where the chain is concrete. Commitments stand for
collision-free canonical commitments, the trie is a logical authenticated map,
and an approval's asset name is a commitment over the tuple it scopes rather than
a real BLAKE2b digest. The executable consumer supplies the real hashes; the
model fixes the complete preimages.

Retraction admission is stated over a finite validity interval. Its bounds are
read off the request script's `in_phase2` and the ledger's validity interval,
whose lower bound is included and upper bound excluded. The model's bounds are
finite, so an interval open at either end is not a case it can be asked: that
is a named non-goal, not a gap waiting on a ticket, and the chain side is
pinned by the request validator's Aiken exact-outcome tests — they admit an
owner-signed retraction at the window's included lower bound and where its
excluded upper bound reaches the retraction time's end, and refuse it with
the named `not-phase2` one unit before the lower bound and one unit past the
upper, and for an interval with no lower or no upper bound alike. The finite
cases are compared live: the
retraction-window row (retract-outside-window) submits an owner-signed retraction before phase 2
and one after it on a devnet, both refused by the request script and answered
`not-phase2` by the model, which agrees on every step. The deployed validators
are compiled without traces, so this run's live refusals expose no name: they
are attributed to the applied request script, and the name itself is never
described as a live observation
(#287).
