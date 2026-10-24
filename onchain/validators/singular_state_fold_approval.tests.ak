//// The approvals of the registration fold of the new Singular line, against
//// the model's `change` and `exactPairing` (statements `registration_inversion`
//// and `batch_inversion`, bound at the revision of the epic branch that
//// landed the model): each change consumes the one approval of exactly that
//// change, recomputed from the change and its holding output, and burns it.
////
//// The guards are tested one function each. Every refusal row has a passing
//// control that differs from it in the one guard under test; the names a row
//// compares are obtained from the producers at run time.

use aiken/builtin
use aiken/collection/list
use cardano/address.{Address, Script, from_script}
use cardano/assets.{add, from_lovelace, zero}
use cardano/transaction.{
  DatumHash, InlineDatum, Input, NoDatum, Output, OutputReference,
}
use singular_state/fold.{
  Change, Register, Terminate, application_datum, approval_for, change_approval,
  change_approval_burn, change_approval_shape, change_reference, fold_pairing,
}
use singular_state/preimage.{
  RegistryIdentity, active_token_name, approval_name, initial_datum_hash,
  registration_preimage, state_token_name,
}
use singular_state_fixtures.{
  application_policy, other_policy, other_script, root_datum, seed_a, seed_b,
  seeds, spent, state_policy,
}
use singular_state_fold_fixtures.{
  Registration, Scenario, approval_of, changes_of, holding_index, holding_output,
  holding_stake, key_a, key_b, key_c, key_d, key_e, key_f, minted,
  registration_a, registration_b, registration_c, registration_d, registry_of,
  request_input, three_registrations, transaction_of,
}

fn scenario() -> Scenario {
  three_registrations()
}

fn registry() -> RegistryIdentity {
  registry_of(seed_a)
}

fn registrations() -> List<Registration> {
  [registration_a(), registration_b(), registration_c(), registration_d()]
}

// ---------------------------------------------------------------------------
// The names an approval and a registered key are given
// ---------------------------------------------------------------------------

test the_names_of_the_roles_are_32_bytes() {
  let registration = registration_a()
  and {
    builtin.length_of_bytearray(active_token_name(registry(), key_a)) == 32,
    builtin.length_of_bytearray(approval_of(registry(), registration)) == 32,
    builtin.length_of_bytearray(initial_datum_hash(registration.datum)) == 32,
    builtin.length_of_bytearray(
      approval_name(
        registration_preimage(
          key_a,
          registry(),
          registration.holding_address,
          initial_datum_hash(registration.datum),
          registration.deposit,
        ),
      ),
    ) == 32,
  }
}

test the_active_names_differ_by_key_and_by_registry() {
  let registries =
    [
      registry_of(seed_a),
      registry_of(seed_b),
      RegistryIdentity { policy: other_policy, name: state_token_name(seed_a) },
    ]
  let names =
    list.flat_map(
      registries,
      fn(registry) {
        list.map(
          [key_a, key_b, key_c, key_d, key_e, key_f],
          fn(key) { active_token_name(registry, key) },
        )
      },
    )
  list.length(names) == 18 && list.length(list.unique(names)) == 18
}

test an_active_name_is_never_a_state_name() {
  list.all(
    seeds,
    fn(seed) {
      list.all(
        [key_a, key_b, key_c],
        fn(key) {
          builtin.length_of_bytearray(active_token_name(registry_of(seed), key)) == 32 && active_token_name(
            registry_of(seed),
            key,
          ) != state_token_name(seed)
        },
      )
    },
  )
}

fn approval_with(
  key: ByteArray,
  registry: RegistryIdentity,
  holding_address: Address,
  datum: Data,
  deposit: Int,
) -> ByteArray {
  approval_name(
    registration_preimage(
      key,
      registry,
      holding_address,
      initial_datum_hash(datum),
      deposit,
    ),
  )
}

test an_approval_name_commits_each_field_of_the_registration() {
  let registration = registration_a()
  let base =
    approval_with(
      registration.key,
      registry(),
      registration.holding_address,
      registration.datum,
      registration.deposit,
    )
  let others =
    [
      approval_with(
        key_b,
        registry(),
        registration.holding_address,
        registration.datum,
        registration.deposit,
      ),
      approval_with(
        registration.key,
        registry_of(seed_b),
        registration.holding_address,
        registration.datum,
        registration.deposit,
      ),
      approval_with(
        registration.key,
        RegistryIdentity { policy: other_policy, name: registry().name },
        registration.holding_address,
        registration.datum,
        registration.deposit,
      ),
      approval_with(
        registration.key,
        registry(),
        from_script(other_script),
        registration.datum,
        registration.deposit,
      ),
      approval_with(
        registration.key,
        registry(),
        Address {
          payment_credential: registration.holding_address.payment_credential,
          stake_credential: Some(address.Inline(Script(holding_stake))),
        },
        registration.datum,
        registration.deposit,
      ),
      approval_with(
        registration.key,
        registry(),
        registration.holding_address,
        builtin.i_data(12),
        registration.deposit,
      ),
      approval_with(
        registration.key,
        registry(),
        registration.holding_address,
        registration.datum,
        registration.deposit + 1,
      ),
    ]
  list.length(others) == 7 && list.all(
    others,
    fn(other) { other != base && builtin.length_of_bytearray(base) == 32 },
  ) && list.length(list.unique([base, ..others])) == 8
}

test an_approval_name_is_not_the_active_name_of_its_key() {
  list.all(
    registrations(),
    fn(registration) {
      approval_of(registry(), registration) != active_token_name(
        registry(),
        registration.key,
      )
    },
  )
}

test the_hash_of_an_initial_datum_differs_by_datum() {
  let hashes =
    list.map(
      [
        builtin.i_data(0),
        builtin.i_data(1),
        builtin.b_data(#""),
        builtin.b_data(#"00"),
        builtin.constr_data(0, []),
        builtin.constr_data(1, []),
        builtin.list_data([]),
      ],
      initial_datum_hash,
    )
  list.length(hashes) == 7 && list.length(list.unique(hashes)) == 7 && list.all(
    hashes,
    fn(hash) { builtin.length_of_bytearray(hash) == 32 },
  )
}

// ---------------------------------------------------------------------------
// The datum of a holding
// ---------------------------------------------------------------------------

test an_inline_datum_is_an_application_datum() {
  list.all(
    [
      builtin.i_data(11),
      builtin.b_data(#"aa"),
      builtin.constr_data(1, [builtin.b_data(#"aa")]),
      builtin.constr_data(0, [builtin.i_data(5)]),
      builtin.constr_data(0, [builtin.b_data(#"aa"), builtin.b_data(#"bb")]),
      builtin.constr_data(0, []),
      builtin.list_data([builtin.b_data(#"aa")]),
      // the shape of a state datum is no reason to refuse a holding
      builtin.constr_data(0, [builtin.b_data(#"aa")]),
      builtin.constr_data(
        0,
        [
          builtin.b_data(
            #"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
          ),
        ],
      ),
    ],
    fn(data) { application_datum(InlineDatum(data)) == Some(data) },
  )
}

test no_datum_and_a_datum_hash_are_no_application_datum() {
  application_datum(InlineDatum(builtin.i_data(1))) == Some(builtin.i_data(1)) && application_datum(
    NoDatum,
  ) == None && application_datum(
    DatumHash(
      #"00000000000000000000000000000000000000000000000000000000000000aa",
    ),
  ) == None
}

// ---------------------------------------------------------------------------
// every-change-has-its-one-approval: the approval a change commits to
// ---------------------------------------------------------------------------

fn outputs() -> List<Output> {
  transaction_of(scenario()).outputs
}

fn first_change() -> Change {
  expect Some(change) = list.head(changes_of(scenario()))
  change
}

fn change_with_holding(change: Change, holding: Int) -> Change {
  expect Register { request, key, deposit, proof, .. } = change
  Register { request, key, holding, deposit, proof }
}

fn change_with_key(change: Change, key: ByteArray) -> Change {
  expect Register { request, holding, deposit, proof, .. } = change
  Register { request, key, holding, deposit, proof }
}

fn change_with_deposit(change: Change, deposit: Int) -> Change {
  expect Register { request, key, holding, proof, .. } = change
  Register { request, key, holding, deposit, proof }
}

fn replace_output(index: Int, output: Output) -> List<Output> {
  list.indexed_map(
    outputs(),
    fn(at, kept) {
      if at == index {
        output
      } else {
        kept
      }
    },
  )
}

fn holding_of_first() -> Output {
  expect Some(output) = list.at(outputs(), holding_index(0))
  output
}

test the_approval_is_recomputed_from_the_change_and_its_holding() {
  list.map(
    changes_of(scenario()),
    fn(change) { approval_for(registry(), outputs(), change) },
  ) == [
    Some(approval_of(registry(), registration_a())),
    Some(approval_of(registry(), registration_b())),
    Some(approval_of(registry(), registration_c())),
  ]
}

test the_recomputed_approval_depends_on_the_key_of_the_change() {
  let base = approval_for(registry(), outputs(), first_change())
  let changed =
    approval_for(registry(), outputs(), change_with_key(first_change(), key_b))
  base != None && changed != None && changed != base
}

test the_recomputed_approval_depends_on_the_deposit_of_the_change() {
  let base = approval_for(registry(), outputs(), first_change())
  let changed =
    approval_for(
      registry(),
      outputs(),
      change_with_deposit(first_change(), registration_a().deposit + 1),
    )
  base != None && changed != None && changed != base
}

test the_recomputed_approval_depends_on_the_registry() {
  let base = approval_for(registry(), outputs(), first_change())
  list.all(
    [
      registry_of(seed_b),
      RegistryIdentity { policy: other_policy, name: registry().name },
    ],
    fn(other) {
      let changed = approval_for(other, outputs(), first_change())
      base != None && changed != None && changed != base
    },
  )
}

test the_recomputed_approval_depends_on_the_holding_the_change_names() {
  let base = approval_for(registry(), outputs(), first_change())
  let changed =
    approval_for(
      registry(),
      outputs(),
      change_with_holding(first_change(), holding_index(1)),
    )
  base != None && changed != None && changed != base
}

test the_recomputed_approval_depends_on_the_address_of_the_holding() {
  let base = approval_for(registry(), outputs(), first_change())
  let holding = holding_of_first()
  list.all(
    [
      from_script(other_script),
      Address {
        payment_credential: holding.address.payment_credential,
        stake_credential: Some(address.Inline(Script(holding_stake))),
      },
    ],
    fn(address) {
      let changed =
        approval_for(
          registry(),
          replace_output(holding_index(0), Output { ..holding, address }),
          first_change(),
        )
      base != None && changed != None && changed != base
    },
  )
}

test the_recomputed_approval_depends_on_the_datum_of_the_holding() {
  let base = approval_for(registry(), outputs(), first_change())
  let holding = holding_of_first()
  let changed =
    approval_for(
      registry(),
      replace_output(
        holding_index(0),
        Output { ..holding, datum: InlineDatum(builtin.i_data(12)) },
      ),
      first_change(),
    )
  base != None && changed != None && changed != base
}

test the_recomputed_approval_ignores_the_value_of_the_holding() {
  let holding = holding_of_first()
  let changed =
    approval_for(
      registry(),
      replace_output(
        holding_index(0),
        Output { ..holding, value: from_lovelace(99_000_000) },
      ),
      first_change(),
    )
  changed == approval_for(registry(), outputs(), first_change()) && changed != None
}

test no_approval_is_recomputed_for_a_holding_that_does_not_exist() {
  list.all(
    [list.length(outputs()), list.length(outputs()) + 7, -1],
    fn(holding) {
      approval_for(
        registry(),
        outputs(),
        change_with_holding(first_change(), holding),
      ) == None
    },
  )
}

test no_approval_is_recomputed_for_a_holding_without_an_application_datum() {
  let holding = holding_of_first()
  list.all(
    [
      NoDatum,
      DatumHash(
        #"00000000000000000000000000000000000000000000000000000000000000aa",
      ),
    ],
    fn(datum) {
      approval_for(
        registry(),
        replace_output(holding_index(0), Output { ..holding, datum }),
        first_change(),
      ) == None
    },
  )
}

test no_approval_is_recomputed_for_a_termination() {
  approval_for(
    registry(),
    outputs(),
    Terminate { request: registration_a().request, key: key_a, proof: [] },
  ) == None
}

// ---------------------------------------------------------------------------
// every-change-has-its-one-approval: guard changeReference
// ---------------------------------------------------------------------------

test one_input_that_spends_the_request_is_the_request_input() {
  let inputs = transaction_of(scenario()).inputs
  list.all(
    changes_of(scenario()),
    fn(change) {
      expect Register { request, .. } = change
      change_reference(inputs, request)
    },
  )
}

test no_input_that_spends_the_request_is_no_request_input() {
  let request = registration_a().request
  !change_reference([], request) && !change_reference(
    [spent(registration_b().request), spent(registration_c().request)],
    request,
  )
}

test two_inputs_that_spend_the_request_are_no_request_input() {
  let request = registration_a().request
  !change_reference([spent(request), spent(request)], request) && !change_reference(
    [spent(request), spent(registration_b().request), spent(request)],
    request,
  )
}

test an_input_that_differs_from_the_request_in_one_part_is_not_the_request_input() {
  let request = registration_a().request
  !change_reference(
    [
      spent(
        OutputReference { ..request, output_index: request.output_index + 1 },
      ),
      spent(OutputReference { ..request, transaction_id: #"aa" }),
    ],
    request,
  )
}

// ---------------------------------------------------------------------------
// every-change-has-its-one-approval: guard changeApprovalShape
// ---------------------------------------------------------------------------

fn request_output(registration: Registration) -> Output {
  request_input(registry(), registration).output
}

test a_request_that_carries_one_application_token_has_the_shape() {
  list.all(
    registrations(),
    fn(registration) {
      change_approval_shape(application_policy, request_output(registration))
    },
  )
}

test other_tokens_beside_the_application_token_do_not_change_the_shape() {
  let output = request_output(registration_a())
  change_approval_shape(
    application_policy,
    Output {
      ..output,
      value: output.value
        |> add(other_policy, #"01", 5)
        |> add(state_policy, #"02", 1),
    },
  )
}

test a_request_without_an_application_token_has_no_shape() {
  let output = request_output(registration_a())
  list.all(
    [
      from_lovelace(5_000_000),
      from_lovelace(5_000_000)
        |> add(other_policy, approval_of(registry(), registration_a()), 1),
      zero,
    ],
    fn(value) {
      !change_approval_shape(application_policy, Output { ..output, value })
    },
  )
}

test a_request_with_the_application_token_at_another_quantity_has_no_shape() {
  let output = request_output(registration_a())
  list.all(
    [2, 5],
    fn(quantity) {
      !change_approval_shape(
        application_policy,
        Output {
          ..output,
          value: from_lovelace(5_000_000)
            |> add(
                application_policy,
                approval_of(registry(), registration_a()),
                quantity,
              ),
        },
      )
    },
  )
}

test a_request_with_two_application_tokens_has_no_shape() {
  let output = request_output(registration_a())
  !change_approval_shape(
    application_policy,
    Output {
      ..output,
      value: output.value
        |> add(application_policy, approval_of(registry(), registration_b()), 1),
    },
  )
}

// ---------------------------------------------------------------------------
// every-change-has-its-one-approval: guard changeApproval
// ---------------------------------------------------------------------------

test the_application_token_the_request_carries_is_the_approval_of_its_change() {
  list.all(
    registrations(),
    fn(registration) {
      change_approval(
        application_policy,
        request_output(registration),
        approval_of(registry(), registration),
      )
    },
  )
}

test the_approval_of_another_change_is_not_the_approval() {
  list.all(
    registrations(),
    fn(registration) {
      list.all(
        registrations(),
        fn(other) {
          registration.key == other.key || !change_approval(
            application_policy,
            request_output(registration),
            approval_of(registry(), other),
          )
        },
      )
    },
  )
}

test the_approval_of_another_registry_is_not_the_approval() {
  let registration = registration_a()
  !change_approval(
    application_policy,
    request_output(registration),
    approval_of(registry_of(seed_b), registration),
  )
}

test the_approval_name_under_another_policy_is_not_the_approval() {
  let registration = registration_a()
  let output = request_output(registration)
  let name = approval_of(registry(), registration)
  !change_approval(
    application_policy,
    Output {
      ..output,
      value: from_lovelace(5_000_000) |> add(other_policy, name, 1),
    },
    name,
  ) && !change_approval(
    application_policy,
    Output { ..output, value: from_lovelace(5_000_000) },
    name,
  )
}

// ---------------------------------------------------------------------------
// every-change-has-its-one-approval: guard changeApprovalBurn
// ---------------------------------------------------------------------------

test the_approval_is_burned_when_the_mint_removes_exactly_one() {
  let name = approval_of(registry(), registration_a())
  list.all(
    registrations(),
    fn(registration) {
      change_approval_burn(
        application_policy,
        approval_of(registry(), registration),
        minted(Scenario { ..scenario(), registrations: registrations() }),
      )
    },
  ) && change_approval_burn(
    application_policy,
    name,
    zero |> add(application_policy, name, -1) |> add(other_policy, #"01", 3),
  )
}

test the_approval_is_not_burned_by_any_other_mint() {
  let name = approval_of(registry(), registration_a())
  list.all(
    [
      zero,
      zero |> add(application_policy, name, 1),
      zero |> add(application_policy, name, -2),
      zero |> add(other_policy, name, -1),
      zero
        |> add(
            application_policy,
            approval_of(registry(), registration_b()),
            -1,
          ),
    ],
    fn(mint) { !change_approval_burn(application_policy, name, mint) },
  )
}

// ---------------------------------------------------------------------------
// every-change-has-its-one-approval: guard foldPairing
// ---------------------------------------------------------------------------

fn inputs() -> List<Input> {
  transaction_of(scenario()).inputs
}

fn carrier(index: Int, value: assets.Value) -> Input {
  Input {
    output_reference: OutputReference {
      transaction_id: #"cc",
      output_index: index,
    },
    output: Output {
      address: from_script(other_script),
      value,
      datum: NoDatum,
      reference_script: None,
    },
  }
}

fn paired(inputs: List<Input>) -> Bool {
  fold_pairing(application_policy, changes_of(scenario()), inputs)
}

test every_input_that_carries_an_application_token_is_a_request_of_a_change() {
  paired(inputs()) && fold_pairing(
    application_policy,
    changes_of(Scenario { ..scenario(), registrations: [registration_a()] }),
    transaction_of(Scenario { ..scenario(), registrations: [registration_a()] }).inputs,
  )
}

test inputs_that_carry_no_application_token_are_not_paired() {
  paired(
    list.concat(
      inputs(),
      [
        carrier(1, from_lovelace(9_000_000)),
        carrier(2, from_lovelace(1) |> add(other_policy, #"01", 4)),
        spent(OutputReference { transaction_id: #"dd", output_index: 0 }),
      ],
    ),
  )
}

test a_fold_that_changes_nothing_pairs_with_no_input() {
  fold_pairing(application_policy, [], [spent(registration_a().request)]) && !fold_pairing(
    application_policy,
    [],
    [carrier(1, from_lovelace(1) |> add(application_policy, #"01", 1))],
  )
}

test an_extra_input_with_an_application_token_is_refused() {
  list.all(
    [
      carrier(1, from_lovelace(1) |> add(application_policy, #"01", 1)),
      carrier(
        2,
        from_lovelace(1)
          |> add(
              application_policy,
              approval_of(registry(), registration_a()),
              1,
            ),
      ),
    ],
    fn(extra) { !paired(list.concat(inputs(), [extra])) },
  )
}

test a_request_that_is_missing_is_refused() {
  let request = registration_b().request
  !paired(
    list.filter(inputs(), fn(input) { input.output_reference != request }),
  )
}

test a_request_that_carries_no_application_token_is_refused() {
  let request = registration_b().request
  !paired(
    list.map(
      inputs(),
      fn(input) {
        if input.output_reference == request {
          Input {
            ..input,
            output: Output { ..input.output, value: from_lovelace(5_000_000) },
          }
        } else {
          input
        }
      },
    ),
  )
}

test a_token_on_another_input_does_not_stand_for_a_request() {
  // the count of carriers matches the changes, but one carrier is no request
  let request = registration_b().request
  !paired(
    list.map(
      inputs(),
      fn(input) {
        if input.output_reference == request {
          Input {
            ..input,
            output_reference: OutputReference {
              transaction_id: #"cc",
              output_index: 5,
            },
          }
        } else {
          input
        }
      },
    ),
  )
}

test a_request_that_carries_two_application_tokens_still_counts_once() {
  let request = registration_a().request
  paired(
    list.map(
      inputs(),
      fn(input) {
        if input.output_reference == request {
          Input {
            ..input,
            output: Output {
              ..input.output,
              value: input.output.value
                |> add(application_policy, #"02", 1),
            },
          }
        } else {
          input
        }
      },
    ),
  )
}

test the_state_input_and_the_funding_input_are_not_requests() {
  let all = inputs()
  list.length(all) == 5 && paired(all)
}

// ---------------------------------------------------------------------------
// every-change-has-its-one-approval: the category of an output is its role in
// the fold. The output that carries the state token is the model's `root`
// category and has no approval; every other output is an `application` output
// whatever its address or the shape of its datum.
// ---------------------------------------------------------------------------

fn state_shaped(root: ByteArray) -> Data {
  builtin.constr_data(0, [builtin.b_data(root)])
}

test the_recomputed_approval_of_a_holding_shaped_as_a_state_datum_commits_that_datum() {
  let holding = holding_of_first()
  let registration = registration_a()
  list.all(
    [#"aa", #"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"],
    fn(root) {
      approval_for(
        registry(),
        replace_output(
          holding_index(0),
          Output { ..holding, datum: InlineDatum(state_shaped(root)) },
        ),
        first_change(),
      ) == Some(
        approval_with(
          registration.key,
          registry(),
          registration.holding_address,
          state_shaped(root),
          registration.deposit,
        ),
      )
    },
  )
}

test the_recomputed_approval_of_a_holding_at_the_state_script_commits_that_address() {
  let holding = holding_of_first()
  let registration = registration_a()
  let at_state = from_script(state_policy)
  approval_for(
    registry(),
    replace_output(holding_index(0), Output { ..holding, address: at_state }),
    first_change(),
  ) == Some(
    approval_with(
      registration.key,
      registry(),
      at_state,
      registration.datum,
      registration.deposit,
    ),
  )
}

test no_approval_is_recomputed_for_the_output_that_carries_the_state_token() {
  // the continuing state output, and a holding that also carries the state
  // token; the same holding without it has an approval
  let holding = holding_of_first()
  let carrying =
    Output {
      ..holding,
      value: holding.value
        |> add(state_policy, state_token_name(seed_a), 1),
    }
  approval_for(registry(), outputs(), change_with_holding(first_change(), 1)) == None && approval_for(
    registry(),
    replace_output(holding_index(0), carrying),
    first_change(),
  ) == None && approval_for(registry(), outputs(), first_change()) != None
}
