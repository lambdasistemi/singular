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

Later slices append their own rows to this table and never edit these lines.
