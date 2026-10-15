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

## Termination booking

The world supply, pending uniqueness, custody provenance and exact booking statements are new identities. Each starts uncovered. They count the actual tags in pending requests as well as custody; the registry-level laws remain unchanged. These model proofs do not establish validator, builder or application conformance.

| Statement | Old identity | New identity | Slice | Coverage after |
|---|---|---|---|---|
| `Singular.Statements.termination_booking_has_exact_contents` | none (new declaration) | `15dff9f8e1426baeb35591b5b8fde46c363c6a1d828ef1fbfc39b4175b47861a` | termination booking | uncovered |
| `Singular.Statements.world_supply_sync` | none (new declaration) | `677482a96629adb878cea08b3d4d76db1fccf65ee06e8622a3abd67a1deb4d14` | termination booking | uncovered |
| `Singular.Statements.at_most_one_pending_termination` | none (new declaration) | `fc59d58c6b0f3723b28f48a68a51abca044a10b3a34554fa734d6c8b6e48d6c2` | termination booking | uncovered |
| `Singular.Statements.termination_request_carries_genuine_token` | none (new declaration) | `fb922d86fb9583f36711401337968e922d9da0a58a01c90e6ed7dfb8a36b5559` | termination booking | uncovered |

## Rejection keeps its own admission

Constitution 1.18.0 supersedes the unconditional rejection statement in main's 1.17.0 amendment. A rejection uses its own evidence admission; the fold deadline does not govern it. The replacement starts uncovered. Model proofs do not establish validator or builder conformance. Earlier rows remain historical.

| Statement | Old identity | New identity | Change | Coverage after |
|---|---|---|---|---|
| `Singular.Statements.reject_reads_no_time` | `363f4561b6c460a270bb0322b4fe66a959a3b7b69862107e5386c45f4c9f41fc` | none (retired) | replaced by rejection's own admission | retired; no coverage transferred |
| `Singular.Statements.rejection_uses_its_own_admission` | none (new declaration) | `7f313cb7eafa046f11d12f5ab4c2f293f16db2718caee95df7bba57d7718f023` | rejection's own admission | uncovered |

The regenerated inventory contains 65 generic statements and 86 statements across the four main families. Coverage discovers 160 obligations: 96 manifest-bound and 64 unclassified. These counts describe the discovered population, not fulfilled implementation promises.

## Request tags bind their own commitments

A registration holds its own trie-ready and application commitments, each computed with its one nonce. A termination holds its singular tag and its own trie-ready commitment, with no application tag. Every commitment value has a trie-ready identity distinct from the state token. These are model statements; application policy execution, concrete hashes, validators, builders and ledger acceptance remain outside this evidence.

The previous syntax-tag statements are restated below. Unchanged statement headers retain their identities; their proofs still compile over the changed booking definitions. No historical row is edited and no implementation coverage is claimed.

| Statement | Old identity | New identity | Slice | Coverage after |
|---|---|---|---|---|
| `Singular.Statements.booked_request_has_exact_contents` | `ec769c8c86bc37e980a9232ca4757735d50eeb6553c00544c2f3b37223802c1e` | `acb9e2740ce102e35037d43f6e0a8fa9a151619e6e95cb9334d4545675dd19a2` | request tag commitments | uncovered |
| `Singular.Statements.trie_ready_tag_is_not_state_token` | `none (new declaration)` | `40491b5e7c054d21394ffce4536dabb8ecd82ca97e797126ff63a4848368b2e1` | request tag commitments | uncovered |
| `Singular.Statements.booked_request_tags_commit_to_own_fields` | `none (new declaration)` | `853adf4e311c11d60e1669151869a39a7b2e0c8bdf93ca23afc288e9c804b09c` | request tag commitments | uncovered |
| `Singular.Statements.termination_booking_has_exact_contents` | `15dff9f8e1426baeb35591b5b8fde46c363c6a1d828ef1fbfc39b4175b47861a` | `4140eb588853fe8b1a019d906b5d83a36bf07987c97d5c5c90e4574340d9c448` | request tag commitments | uncovered |
| `Singular.Statements.booked_termination_tag_commits_to_own_operation` | `none (new declaration)` | `c688ac7857bc9d8cf5cd72fc46cf9cc5e9aad1af27ac912239865e2e9d4951e8` | request tag commitments | uncovered |

## One minimum tip in the existing state field

The registry pins one minimum tip, encoded under the existing `maxFee` key. Booking checks that floor; a fold preserves it. The two transaction statements now prove their remaining conclusions for every input lovelace amount, without the old premise that merely repeated their tip-cover conjunct. The proofs use only the standard axioms. These model statements do not establish validator, builder or ledger implementation; exact processor take is subsequent fold work.

Every changed identity below starts uncovered. No previous row is edited.

| Statement | Old identity | New identity | Coverage after |
|---|---|---|---|
| `Singular.Statements.parameters_preserved_by_fold` | `c73c54081ec6ae72ee73d9bc4d7d178e2af1e5f4f43db5937a1fb8e9f2598f16` | `6da6cfc86b1fe02a09fa5534189674a4a9db43e21db1cd8d779dcaeda12e5854` | uncovered |
| `Singular.Statements.parameters_preserved_by_batch` | `f3c594ddec6a8d649e94d442da0ddaafcdf3557989fdaf630b15b0f111e4f76a` | `c510d2694f9b450b6e357f4991c59980130d000854e0cc3e5a7d80cd05e2d46d` | uncovered |
| `Singular.Statements.insert_active_transaction_row` | `6073c296c90657ef193368669ef07ce6d97eddaa9d2059771e23fe156b61b868` | `d1c937f62f959c54a332841fe20c817a930e08aaab678dcbb749eb28a3645fb6` | uncovered |
| `Singular.Statements.update_terminal_transaction_row` | `d2402d0c08b3df1258ddf354ef7e4855ceec1dae5f1fe763e0f0189aacb0b560` | `f21126bbaa702ea79d379d7ea755ca49f322c9006105f56dc52af4319e1cfe74` | uncovered |

Retired definitions and controls are named separately from theorem identities:

| Retired identity | Disposition |
|---|---|
| `Singular.Config.maxFee` | The Lean field is replaced by `Singular.Config.minimumTip`; the wire key `maxFee` remains. The separate serialized `minimumTip` field is retired. |
| `Singular.lovelaceCoversTip` | Retired; the fold transaction model never enforced this echo as admission. |
| `insert_active_transaction_row.hfee` and its `by simpa [lovelaceCoversTip] using hfee` proof | Premise, echoed conjunct and its proof retired together. No separately named tip-cover lemma exists at the bound base. |
| `update_terminal_transaction_row.hfee` and its `by simpa [lovelaceCoversTip] using hfee` proof | Premise, echoed conjunct and its proof retired together. |
| `transactionRowJson.tip`, `transactionRowJson.lovelaceCoversTip`, `retirementRowJson.tip`, `retirementRowJson.lovelaceCoversTip` | Retired top-level annotations only; request tips and all transaction fields remain. |
| The corpus runner's “Transaction correspondence tip not covered” assertion | Retired; below-pin transaction construction is exercised without this obsolete assertion. |
| “the old fee pin does not constrain booking” | Replaced by registration floor acceptance and below-floor refusal under the one pin. |
| “the old fee pin is independent of the minimum tip” | Replaced by termination floor acceptance and below-floor refusal under the one pin. |

## Reference-read rejection helpers and retained legacy adapters

The named legacy adapters equal their original functions by reflexivity. They name the superseded state-spending path; they do not satisfy the reference-read design. The economic helper describes the admitted world effect. Every new helper remains unclassified and uncovered; existing statement identities are unchanged.

| Declaration | Old identity | New identity | Coverage after |
|---|---|---|---|
| `Singular.LegacyRejection.judgeSurface_original` | none (new declaration) | `50ed6e5af8dd704b408c86427cfe8a3228cf9b35377e9a280fc3ce336b54b7ae` | uncovered |
| `Singular.LegacyRejection.observedRefusal_original` | none (new declaration) | `96ea0a6bacc20c3ea70d70bf6e7aa27c0642fca46cc504d7c427c058aa8e2f6b` | uncovered |
| `Singular.LegacyRejection.rejectBatchStep_original` | none (new declaration) | `1210355809b77d5a473ac3e79667c942eaf6673ed47ca9bef5a732f2d16e9719` | uncovered |
| `Singular.LegacyRejection.runRejectBatch_original` | none (new declaration) | `aa5729a34331030a0a3927ec8873892be81fb44fe65de10235e6dbd5a1d714cf` | uncovered |
| `Singular.LegacyRejection.runSurface_original` | none (new declaration) | `446b128c6d28362bc1b7fba3443c93a1d9ac35f1e452b705739d94f657ab7361` | uncovered |
| `Singular.LegacyRejection.step_original` | none (new declaration) | `7e8888836cb05a690c7e564eb8b6c8e81448b18ba8a9906146d925fd69b978f8` | uncovered |
| `Singular.LegacyRejection.transaction_original` | none (new declaration) | `91745d371b7b5aaa2f5bf5a3ca63570cec7ca2394cdbc2ddb2402aef286cc755` | uncovered |
| `Singular.rejectionAccepted_effect` | none (new declaration) | `757461a103f73e7a765a1b7d5e3e2cc0ea7cdeff9eb8b5969b9c174e3b1643a3` | uncovered |

## Rejection reads the state in reachable worlds

Seven new public statements prove the reference-read rule over reachable worlds and observed transactions using only the standard axioms. Their helper identities remain in the discovered denominator. All new identities start uncovered; no existing identity or historical row changes, and no validator, builder or ledger coverage is inferred from the model proofs.

| Declaration | Old identity | New identity | Coverage after |
|---|---|---|---|
| `Singular.Statements.live_request_not_rejected` | none (new declaration) | `1529635d1e8c9cd27cae709b38c7843b8118cf64988e7b25a07c30f2deb7235d` | uncovered |
| `Singular.Statements.rejection_batch_members_distinct` | none (new declaration) | `35e715d8a167ea2e3858a92b6cfabad2cca93b8fb5b29291daab622f6486c161` | uncovered |
| `Singular.Statements.rejection_cannot_invalidate_fold` | none (new declaration) | `cffe076d8bff5f852e836c65718f61890f72ec3343d641426f9892aa5178fd30` | uncovered |
| `Singular.Statements.rejection_leaves_registry_untouched` | none (new declaration) | `b5d255df884ced7075f14be0f55e1af9d430071b5e316910287172a8548d649d` | uncovered |
| `Singular.Statements.rejection_requires_referenced_state` | none (new declaration) | `fbb3aa5eedd31136dd1b85d6cb07eddab84788f51d8f9fcbea7bb4e6b9ee9b48` | uncovered |
| `Singular.Statements.sweep_leaves_pool_untouched` | none (new declaration) | `ddd73703885e3b3a52bf612184af6ba1cde863c0f1936dc4288c0517c3d05496` | uncovered |
| `Singular.Statements.termination_unrejectable` | none (new declaration) | `1a80126b456ce1f2f32cae58401d9f3fcce6a15bffeeb67d9b3102ba7dbe7096` | uncovered |
| `Singular.economicLookup_mem` | none (new declaration) | `ad21f1dfbeffa2112e403af6f328c75124f0ac1660e3d6349d3ba0f43d2fdcc5` | uncovered |
| `Singular.observed_registration_unique` | none (new declaration) | `cab5f12c269ff73b22fdf19fc1fbac3cfd7cbca17a47de7f69cff489f3e4a1b9` | uncovered |
| `Singular.observed_request_kinds_disjoint` | none (new declaration) | `5ee4cbad403fbaa111fcecda84f3286b346d5105afe04ae6b27e09041b7a938a` | uncovered |
| `Singular.rejectionAccepted_checks` | none (new declaration) | `60c4b7ac4b73d887342480830383e017ccc8c182b60dcb32cef272abf6f343c4` | uncovered |
| `Singular.rejectionInputs_facts` | none (new declaration) | `0e42fbbb4d5ade7aa390fd3af60e7daddbed624fce92558b16084a901aaa86d2` | uncovered |
| `Singular.rejectionObservation_world` | none (new declaration) | `da338e56003fd95929a5f7e0679ae218422a81ccb30fcbdcd6ce395366d4f458` | uncovered |
| `Singular.rejectionState_facts` | none (new declaration) | `1262983030f402228eaa91eb076d0eee375f422104b65730e803f4c71ed05901` | uncovered |
| `Singular.rejection_state_not_spent` | none (new declaration) | `1f1ff8e7cb2e49e580ceb8640b9563f41639df20dc5397c33df6168c738e51ee` | uncovered |

## Economic retraction effect

These new economic declarations have no implementation coverage. Every earlier identity remains unchanged; no legacy conformance claim is evidence for these refunds.

| Declaration | Old identity | New identity | Coverage after |
|---|---|---|---|
| `Singular.retractionAccepted_effect` | none (new declaration) | `1a18084b164f142d843cae9035033d525e197902b7aa4e2cccd707c6779ec6a3` | uncovered |

## Economic refund statements

These new economic declarations have no implementation coverage. Every earlier identity remains unchanged; no legacy conformance claim is evidence for these refunds.

| Declaration | Old identity | New identity | Coverage after |
|---|---|---|---|
| `Singular.RefundProof.allocations` | none (new declaration) | `13eca6de769145c07f75ecc3178154bfa62b7436abe476b71498532c2a128d68` | uncovered |
| `Singular.RefundProof.costs_le_owed` | none (new declaration) | `6edb35721782319baa12b27fad24c5a9073bb4cd0ebf080eb91d92f22954b1cc` | uncovered |
| `Singular.RefundProof.mem_addresses` | none (new declaration) | `86f4e70a634fe4fe29237e01e8392175e27195a88dcb87548cf725386f8e4ade` | uncovered |
| `Singular.RefundProof.refund_floor` | none (new declaration) | `570f333a83058db0c2a08f36643e72f3a16c62b08872def46333215430894338` | uncovered |
| `Singular.RefundProof.rejection_refunds` | none (new declaration) | `bb7f27d30495d0e666a09a6f941fccb2d22d269d48dfd67c4981734620c94ff7` | uncovered |
| `Singular.RefundProof.retraction_checks` | none (new declaration) | `0165c893a6482e47d3eefbc350c1612613998af3b2688b014233111bdeff520a` | uncovered |
| `Singular.RefundProof.retraction_no_state` | none (new declaration) | `e26f016288207342a3f289d312eeb35e58f8b9583ae05805c356c9d16244d063` | uncovered |
| `Singular.RefundProof.retraction_request` | none (new declaration) | `c6162a4c12b5c456956deeeba6de08d2f8e5c20638cd22c635fa76cfb4b72b30` | uncovered |
| `Singular.RefundProof.selected_members` | none (new declaration) | `6d4b9a7def805c819252df80c92ff2d4c704489c2f8e0d30f7fac8be9a5a5e8b` | uncovered |
| `Singular.RefundProof.selected_pending` | none (new declaration) | `2dda1d7d8ce5063e0bb1828ddae7123179317d87a9a7a49a657bc11bbf154ea1` | uncovered |
| `Singular.RefundProof.unique_addresses` | none (new declaration) | `fd1339a51b94c34b98e48f74448ce6d8aa301e8915d8214fc7a5938f6b16aee6` | uncovered |
| `Singular.Statements.refunds_sum_per_address` | none (new declaration) | `b8a00f6d2f28d71a36e3a8cac3bce94c845ce6c2bd3acda57be7e10e49072d18` | uncovered |
| `Singular.Statements.registration_cost_returned_on_exit` | none (new declaration) | `b989571d70a36354c46600639d3aeefeee6cf0ea7fba55bfb2ca67c2ad24598d` | uncovered |
| `Singular.Statements.rejection_refund_floor` | none (new declaration) | `0b04d3309b5b8ead87768ad939df7aed1eb7885eea53d43ea3140110092076d4` | uncovered |
| `Singular.Statements.retraction_refund_floor` | none (new declaration) | `2eb1d47fa80f28d8629703cc318886288ded65b8379a42ccfef3156c5c4b4783` | uncovered |
