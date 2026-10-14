# Protected rejection restatement record

As a reader of the coverage record, I see which statements changed identity
under protected rejection and which stayed covered, so that no obligation is
silently dropped and every restated identity is judged uncovered until claimed
again.

Slice one changes only the retraction window to read the booked request time.
No statement is added and none is removed. The three statements below changed
wording and therefore identity; each starts uncovered and must be claimed again
by the corpus rows that exercise it. All other obligations keep their identity
and their coverage.

| statement | old identity | new identity | slice | coverage after |
|---|---|---|---|---|
| `Singular.inPhase2_iff` (coverage inventory identity) | `5666f0fb9a79bbebe4585a631eb3ffbd72ec947da8cbffe35d4eee21901120a2` | `72d002db3d46f401a9a900d72f968bf9d159f2cb9663bb7acd9904ad3e5c6837` | one booked clock | uncovered until the retraction rows replay |
| `Singular.Statements.retract_admitted_iff` | `6c9c65f00e1b9054319ae2151908af4336717df5642f31aace963aa80cb29f57` | `30f9c66828032bcc4337dc96e5c7e9c8dec6514b0f5c9ad3c0969846e19ce55c` | one booked clock | uncovered until the admitted retraction rows replay |
| `Singular.Statements.retract_refusal_first_failing` | `506966483299dfa897bb988c179646373d3dfcf7a1a20728fdf0cae217197ffc` | `a91793ff8a3c12a3bf4a12632c53a53f4e0d25ff42f40766443a6e4b1d417f71` | one booked clock | uncovered until the refused retraction rows replay |
| `Singular.Statements.rejection_admitted_iff` | none (new declaration) | `cdd9b2e62391bc21750ed601e8e3045ce271467db5af493c8925ca2037091350` | rejection needs evidence | uncovered until the truth-table, time and binding rows replay |
| `Singular.Statements.live_compatible_request_protected` | none (new declaration) | `bc7f7681634a2db1d3c5f0b149fcdab99bfe82bed17d56bcb00afae67b8f6047` | rejection needs evidence | uncovered until the compatible protection rows replay |
| `Singular.Statements.rejection_without_evidence` | none (new declaration) | `56e1fe9ed8e1ee23a77d9fe19e42d7ec9e6963993637860464727e96df5d1d1c` | rejection needs evidence | uncovered until the historical refused rows replay |
| `Singular.Statements.protected_rejection_effects` | none (new declaration) | `91c17bc708609880f867eb88efca930630f4eb91d2d25c618686a81b1a32e66f` | rejection needs evidence | uncovered until the effects rows replay |
| `Singular.Statements.expiry_after_reclaim` | none (new declaration) | `f6c06a2ce273ed86fb655a9f25ff1c8b7cc756cba76aff6f866d223db67bd952` | rejection needs evidence | uncovered until the expiry rows replay |
| `Singular.Statements.admitted_exit_is_the_exit` | `3182f6fcacacf71f257ba4ddd17ec276302e04ba5342726b4833a8be51d68c38` | `ef8187d635d0ed65365eae4fbdfe85c44fa423a8fa5ebcc03d3e95f4886762fd` | rejection needs evidence | uncovered until the admitted exit rows replay |
| `Singular.Statements.admission_refuses_first` | `c7ed5cabec1c955cf43772cdabcb547307d9c7023fc45dac90d347f45b61bcc7` | `a021ed02814e177fa37fa6996054ca8a5ed0413e8a3093129e7be5960b0010eb` | rejection needs evidence | uncovered until the refusal order rows replay |

Later slices append their own rows to this table and never edit these lines.

## Parameters and transaction vocabulary

Every new or restated identity starts uncovered; no execution evidence is inherited. The two full transaction equations now name the state token carried by the produced state output.

| Statement | Old identity | New identity | Slice | Coverage after |
|---|---|---|---|---|
| `Singular.Statements.balanced_transaction_creates_no_value` | none (new declaration) | `68f5c013cc475fa92dee1482ccadc9306627ff270d524d05a0e85aacf3c9fc24` | parameters and transaction vocabulary | uncovered |
| `Singular.Statements.insert_active_transaction_row` | `3c8d7b9bd9092b29d2bbb58ebbca15b008dc9b9396899d9d67d55ea66e1f6070` | `6073c296c90657ef193368669ef07ce6d97eddaa9d2059771e23fe156b61b868` | parameters and transaction vocabulary | uncovered |
| `Singular.Statements.overlapping_reference_is_spent` | none (new declaration) | `25057afc351d9ee2b4a83818544cd1758c3321a3d9610c9e855d8e6ce31a3fd3` | parameters and transaction vocabulary | uncovered |
| `Singular.Statements.parameters_preserved_by_batch` | none (new declaration) | `f3c594ddec6a8d649e94d442da0ddaafcdf3557989fdaf630b15b0f111e4f76a` | parameters and transaction vocabulary | uncovered |
| `Singular.Statements.parameters_preserved_by_fold` | none (new declaration) | `c73c54081ec6ae72ee73d9bc4d7d178e2af1e5f4f43db5937a1fb8e9f2598f16` | parameters and transaction vocabulary | uncovered |
| `Singular.Statements.reference_inputs_not_consumed` | none (new declaration) | `2e125ce1ae73d0f9bdaf0c9ec6de4c940c06ddf60bea10d50934a42f79e8b85f` | parameters and transaction vocabulary | uncovered |
| `Singular.Statements.spent_reference_refused` | none (new declaration) | `07ae6b51c77261364c3d5aff546b6fb3522be49fc3f699ba1c52281db58938ad` | parameters and transaction vocabulary | uncovered |
| `Singular.Statements.update_terminal_transaction_row` | `4806b33d0b74c975981c8905ceb8aab758efbe5d780eca50f59e68202ea2a4bf` | `d2402d0c08b3df1258ddf354ef7e4855ceec1dae5f1fe763e0f0189aacb0b560` | parameters and transaction vocabulary | uncovered |
| `Singular.Statements.zero_donation_omits_field` | none (new declaration) | `5fa265d9c485578f30de49ba67268bb1d27a5af1fbae91d5a2758fefdc39b291` | parameters and transaction vocabulary | uncovered |
| `Singular.foldActions_config_root` | none (new declaration) | `209661c772a9e03b951d80cdf93220b923801c714c5e6e6d482addf1864b88cc` | parameters and transaction vocabulary | uncovered |
| `Singular.step_config_root` | none (new declaration) | `dfa6943275884be44fa845fa11235e938a49965a7eaee4b64584438044ea1bc7` | parameters and transaction vocabulary | uncovered |

## Names clarified without restatement

The following names change without changing a proposition, proof or executable body. Every header and proof is identical after the listed name substitutions; the coverage mappings and their uncovered state are retained. Earlier rows remain historical.

| Old qualified name | New qualified name | Reason |
|---|---|---|
| `Singular.Statements.balanced_transaction_creates_no_value` | `Singular.Statements.balanced_transaction_conserves_value` | The judgement conserves value including fees and donations. |
| `Singular.inputNames` | `Singular.inputsContainReference` | The Boolean asks whether inputs contain a reference. |
| `Singular.inputsPresent` | `Singular.inputPresenceRefusal` | The result is an optional refusal reason. |

| Old statement identity | New statement identity | Coverage after |
|---|---|---|
| `Singular.Statements.spent_reference_refused@07ae6b51c77261364c3d5aff546b6fb3522be49fc3f699ba1c52281db58938ad` | `Singular.Statements.spent_reference_refused@05956cb3b5599c5e49722c67ce1b7f77cf9cd7f7bbfd74513c969c58930138c6` | unchanged: uncovered |
| `Singular.Statements.balanced_transaction_creates_no_value@68f5c013cc475fa92dee1482ccadc9306627ff270d524d05a0e85aacf3c9fc24` | `Singular.Statements.balanced_transaction_conserves_value@6f463431f4a5d5bb1bf32f641b8d820ddb67ec53c04125e97fd896135283621d` | unchanged: uncovered |

## Registration booking

The four booking statements are new identities. Each starts uncovered; their Lean proofs and executable model controls do not establish implementation coverage. Carrier ada is the declared allocation, with no claim about the ledger minimum.

| Statement | Old identity | New identity | Slice | Coverage after |
|---|---|---|---|---|
| `Singular.Statements.booked_request_has_exact_contents` | none (new declaration) | `ec769c8c86bc37e980a9232ca4757735d50eeb6553c00544c2f3b37223802c1e` | registration booking | uncovered |
| `Singular.Statements.booked_time_is_interval_end` | none (new declaration) | `86d8a38ebe2a03232e278407a4deb3f51ad82f4d942140d8b5c86990ef50ef65` | registration booking | uncovered |
| `Singular.Statements.booked_time_not_before_inclusion` | none (new declaration) | `63ebcb7a3f9d8bf326674e19c297fc13187eade456c13637641a1e8e34a0bdb3` | registration booking | uncovered |
| `Singular.Statements.booking_width_within_limit` | none (new declaration) | `5d12a9178a46bc78852ba4af63ee95a28713b278e2c9b7e37d1c8c5ac32e1c49` | registration booking | uncovered |
