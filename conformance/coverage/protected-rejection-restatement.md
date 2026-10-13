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
