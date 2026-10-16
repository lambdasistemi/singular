# Release record of the model revision

This record is the release of ticket 494's model to the validator and builder tickets. The release is the merge commit of the ticket's pull request; the record names the model revision that commit contains, the contracts, the digest of every statement they cite, the corpus rows, the constitution version and the limits that remain. It is filled when the work is accepted.

## Story

As the author of a validator or a builder, I find in one place the exact revision of the model I implement, the contract that states what each action must satisfy, the statements that prove it, the cases that exercise it, and what is not yet true of the deployed code, so that nothing I rely on is an inference.

## The model revision

| Field | Value |
|---|---|
| Model revision | `4254a3073fe0457946eba0a68d974c999c930ebf`, the last commit of the branch that changes `lean/`; every later commit of the pull request leaves the Lean tree unchanged |
| Compiler | Lean 4.27.0 (`lean-toolchain`) |
| Statements | 87 records in `lean/theorem-debt.json`, all `PROVED`, debt `none`, standard axioms only (`propext`, `Classical.choice`, `Quot.sound`; `lake env lean tools/axioms.lean`) |
| Constitution | version 1.18.0 (`.specify/memory/constitution.md`): its sync-impact entry states the economic rows and the ruled economic translation; the legacy driver table is unchanged |
| Contracts | [the economic contract](economic-contract.md) for booking, rejection by reference read, retraction and the fold; [the rejection evidence contract](rejection-evidence-contract.md) for the first stage, which the model keeps as a named legacy path |

## Statement digests

Each line is the qualified name and the SHA-256 digest of the statement text, as recorded in `lean/theorem-debt.json`. A change of a statement changes its digest and is detected by the model check.

First stage, named in the [functions model](../functions-model.md) (the batch statements of the mixed batch and the restated window statement are not in the register: the first were withdrawn with the mixed batch, the second is a lemma):

```text
Singular.Statements.expiry_after_reclaim  f6c06a2ce273ed86fb655a9f25ff1c8b7cc756cba76aff6f866d223db67bd952
Singular.Statements.rejection_admitted_iff  cdd9b2e62391bc21750ed601e8e3045ce271467db5af493c8925ca2037091350
Singular.Statements.live_compatible_request_protected  bc7f7681634a2db1d3c5f0b149fcdab99bfe82bed17d56bcb00afae67b8f6047
Singular.Statements.rejection_without_evidence  56e1fe9ed8e1ee23a77d9fe19e42d7ec9e6963993637860464727e96df5d1d1c
Singular.Statements.protected_rejection_effects  91c17bc708609880f867eb88efca930630f4eb91d2d25c618686a81b1a32e66f
Singular.Statements.admitted_exit_is_the_exit  ef8187d635d0ed65365eae4fbdfe85c44fa423a8fa5ebcc03d3e95f4886762fd
Singular.Statements.admission_refuses_first  a021ed02814e177fa37fa6996054ca8a5ed0413e8a3093129e7be5960b0010eb
```

Economic stage, named in the [economic contract](economic-contract.md):

```text
Singular.Statements.booked_request_has_exact_contents  acb9e2740ce102e35037d43f6e0a8fa9a151619e6e95cb9334d4545675dd19a2
Singular.Statements.booked_request_tags_commit_to_own_fields  853adf4e311c11d60e1669151869a39a7b2e0c8bdf93ca23afc288e9c804b09c
Singular.Statements.booked_time_is_interval_end  86d8a38ebe2a03232e278407a4deb3f51ad82f4d942140d8b5c86990ef50ef65
Singular.Statements.booked_time_not_before_inclusion  63ebcb7a3f9d8bf326674e19c297fc13187eade456c13637641a1e8e34a0bdb3
Singular.Statements.booking_width_within_limit  5d12a9178a46bc78852ba4af63ee95a28713b278e2c9b7e37d1c8c5ac32e1c49
Singular.Statements.termination_booking_has_exact_contents  4140eb588853fe8b1a019d906b5d83a36bf07987c97d5c5c90e4574340d9c448
Singular.Statements.termination_request_carries_genuine_token  fb922d86fb9583f36711401337968e922d9da0a58a01c90e6ed7dfb8a36b5559
Singular.Statements.booked_termination_tag_commits_to_own_operation  c688ac7857bc9d8cf5cd72fc46cf9cc5e9aad1af27ac912239865e2e9d4951e8
Singular.Statements.trie_ready_tag_is_not_state_token  40491b5e7c054d21394ffce4536dabb8ecd82ca97e797126ff63a4848368b2e1
Singular.Statements.rejection_requires_referenced_state  fbb3aa5eedd31136dd1b85d6cb07eddab84788f51d8f9fcbea7bb4e6b9ee9b48
Singular.Statements.rejection_leaves_registry_untouched  b5d255df884ced7075f14be0f55e1af9d430071b5e316910287172a8548d649d
Singular.Statements.rejection_cannot_invalidate_fold  cffe076d8bff5f852e836c65718f61890f72ec3343d641426f9892aa5178fd30
Singular.Statements.rejection_batch_members_distinct  35e715d8a167ea2e3858a92b6cfabad2cca93b8fb5b29291daab622f6486c161
Singular.Statements.live_request_not_rejected  1529635d1e8c9cd27cae709b38c7843b8118cf64988e7b25a07c30f2deb7235d
Singular.Statements.termination_unrejectable  1a80126b456ce1f2f32cae58401d9f3fcce6a15bffeeb67d9b3102ba7dbe7096
Singular.Statements.sweep_leaves_pool_untouched  ddd73703885e3b3a52bf612184af6ba1cde863c0f1936dc4288c0517c3d05496
Singular.Statements.rejection_refund_floor  0b04d3309b5b8ead87768ad939df7aed1eb7885eea53d43ea3140110092076d4
Singular.Statements.retraction_refund_floor  cf61ca08b5c5cedb781bd9db1d8f8f94a77633b2abd01858b0923e4f8c9d4f23
Singular.Statements.registration_cost_returned_on_exit  020c88bd1d8c402bb794b60ca62e53480afea63e0c4b966f840aed776428a507
Singular.Statements.refunds_sum_per_address  b8a00f6d2f28d71a36e3a8cac3bce94c845ce6c2bd3acda57be7e10e49072d18
Singular.Statements.retraction_pays_only_the_refund_and_the_fee  84312f008c3afd8626c096225c9f1005509dc3c10eb66b50e3ce8878d48c4406
Singular.Statements.pending_registration_can_be_retracted  b325b874b8caeb1b42f555091840ec34b030982e8352b4a5e0621d7b2fd64091
Singular.Statements.fold_donates_registration_cost  73acdb292ac4e0c3e60f20c815b78f9fde51710353ecc22978f3945b1e517e1a
Singular.Statements.fold_routes_every_amount  4c377fad0618583e7667f9d111a7e83280caa0698669ba8e6c35d237df98ce23
Singular.Statements.processors_take_at_most_the_tips  5b27c934a9e7d8d597709bf6f2e44a331ac2994413d5d45b6d5698b79e1ba1ac
Singular.Statements.only_booked_terminations_fold  51218f6e6e8d072ae07b854064b0f8e23e2097cc398a0fad68c15cca9f46414c
Singular.Statements.booked_termination_foldable  bfd1f032ef8ac47f9dee010a5838f3d1f1b6a71ef6dd3cad05a5e37dc61dfe28
Singular.Statements.parameters_preserved_by_fold  6da6cfc86b1fe02a09fa5534189674a4a9db43e21db1cd8d779dcaeda12e5854
Singular.Statements.zero_donation_omits_field  5fa265d9c485578f30de49ba67268bb1d27a5af1fbae91d5a2758fefdc39b291
Singular.Statements.tag_supplies_equal_pending  0700e6a117d38944ee1896f4276cc5e0147d76162f59ccc6613f8c6393a68ec0
Singular.Statements.world_supply_sync  677482a96629adb878cea08b3d4d76db1fccf65ee06e8622a3abd67a1deb4d14
Singular.Statements.at_most_one_pending_termination  fc59d58c6b0f3723b28f48a68a51abca044a10b3a34554fa734d6c8b6e48d6c2
```

## Corpus rows

The accepting and refusing cases are exported by the model runner and replayed by the model check, the simulator check and the application replay.

| Where | Rows |
|---|---|
| `lean/corpus.json`, sections `registrationBookings`, `terminationBookings`, `rejectionReadsState`, `economicRefunds`, `economicRetractionFunding`, `economicFolds`, `economicControls` | 49, 37, 41, 31, 43, 45, 19 |
| `lean/driver-corpus.json` | 75 rows; the rejection truth table (13 rows) and the expiry positions (4), the historical scenario (`historical-unguarded-rejection`), the batch and refusal rows |

## The historical scenario, run on the unchanged base

The scenario of a valid live request rejected without justification (the insertion of key 5 for owner 42, booked at 10000, a signerless rejection witness) was run against the base model before any change, on 13 October 2026, on the pre-slice base `2d447ec2dd066b56af4e0e10e52739d29878d14f` of the branch as it was then. The run printed

```text
ACCEPTED stateSame=true mintEmpty=true paidOk=true
```

that is: the base accepted the rejection, left the registry state unchanged, minted nothing and paid only the deposit. The failing control that followed (the corpus row expecting the outcome refused and the reason `reject-evidence-missing`) failed on the base for those two reasons. The row is preserved as `historical-unguarded-rejection` in `lean/driver-corpus.json`, where the changed model refuses it. The commits of that stage were squashed when the branch was linearized, so their hashes are not part of the pushed history; the receipt is quoted here because the repository holds no other record of the base's behaviour.

## What stays true after this release

- No validator, no transaction builder and no command is changed by this ticket. The deployed validators and builders still follow the earlier rules: the live conformance rows that exercise them are published as unmet, with a tripwire that turns red when they change, and nothing counts the earlier behaviour as meeting the ruled design.
- The model is the authority. Where a validator disagrees with it, the validator follows.
- The model has no Merkle proof bytes, no wallet-ownership observation, no ledger minimum for any output, no native-asset funding and no fee market; the [economic contract](economic-contract.md) lists what is left to the implementation.
- Measured values of the registration cost, the minimum tip and the booking width are not decided.
- No dependent ticket (validators, builders, connected acceptance, the separate rejection command, the request-tag mint) is accepted by this release; each is scoped to this contract.
