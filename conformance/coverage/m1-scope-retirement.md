# M1 scope retirement

As a coverage reader, I need to distinguish obligations retired by the operator
from requirements the current implementation has not demonstrated.

The scope ruling of 8 October 2026 removes excluded M2 success
behavior from the active M1 model. The existing baseline-move
process is used without changing the coverage gate. The following exact identities are
retired from M1 scope by operator ruling; archived for M2. They receive no
coverage credit and are not counted as covered. Their sources and receipts
remain at `preserve/m2/pre-m1-source-removal` (`a098408e`).

| Historical exact identity | Disposition |
| --- | --- |
| `Singular.NamingStatements.naming_retract_only_inserter@8f7cded95e2061d0cf550914228bd42416d62b0e7093894d568fbf40d81484b4` | Retired from M1 scope by operator ruling; archived for M2 |
| `Singular.Statements.delete_absent_inversion@b040a97d18406c2a0be100516a5f9f5ea3f7c1bcc606a0c26eab4eb38828bce5` | Retired from M1 scope by operator ruling; archived for M2 |
| `Singular.Statements.delete_active_inversion@39b91a52340027b5062725a24c38ee9cb5e568518b6c44727946556be0a903f8` | Retired from M1 scope by operator ruling; archived for M2 |
| `Singular.Statements.insert_absent_inversion@b2ca14e3aa29caef0841c246964e5e64b600eef9ff64c0865677a1219d31525d` | Retired from M1 scope by operator ruling; archived for M2 |
| `Singular.Statements.readAt_true_iff@69c6c811a286c3436e0b230319f762de5c3c89e977a8a1d075859159e87d5916` | Retired from M1 scope by operator ruling; archived for M2 |
| `Singular.Statements.read_changes_nothing@0a53256f91fbd4e8d4de2e8e2b9add39fc6a04ad10327d594d3f74acabdb6120` | Retired from M1 scope by operator ruling; archived for M2 |
| `Singular.Statements.terminal_mint_only_by_read@287bddd3ed1888a07b163f247fb4bdda6a4de049f26d815c5d52be9c82617639` | Retired from M1 scope by operator ruling; archived for M2 |
| `Singular.Statements.terminal_witness_plural@68beea77527a148a61f7f055d065aec3d1d2c3acdb25231c5c8db851a747efff` | Retired from M1 scope by operator ruling; archived for M2 |
| `Singular.Statements.update_active_inversion@038b9a1c9fb903c12d79f42f263709291ecd1573919f33b85906ae5a2ed78bae` | Retired from M1 scope by operator ruling; archived for M2 |
| `Singular.Statements.witness_terminal_inversion@744464d451c58730a0619747bab570700e5ad4bf29e005e36f8302b980d3cabf` | Retired from M1 scope by operator ruling; archived for M2 |
| `Singular.applyEdge_deleteAbsent@a6fb1400d1a031a4bfdeb00d6b6528d504079978bded08ab59e16aa393ddc63c` | Retired from M1 scope by operator ruling; archived for M2 |
| `Singular.applyEdge_deleteActive@c0aa4996b3378241d35b3430c7b93e7c2ad11d87866500ecaf8f863416d8d098` | Retired from M1 scope by operator ruling; archived for M2 |
| `Singular.applyEdge_insertAbsent@417c95cf7676686867fcf50abf7ad06b339ded8f57eb3e48963fbacbd3c7396f` | Retired from M1 scope by operator ruling; archived for M2 |
| `Singular.applyEdge_updateActive@eb7edd5822ee89da096e65ca5d2238af67b32c6160026283b2f7b4391c33e558` | Retired from M1 scope by operator ruling; archived for M2 |
| `Singular.applyEdge_witnessTerminal@35def00f59ff3da5acf9ecbcc6e75d7580ccdebcce66f8cb9fe5a443cd5970e9` | Retired from M1 scope by operator ruling; archived for M2 |

The following signatures are restated for the supported M1 behavior. Old receipts
are invalid for their new identities; new identities start uncovered.

| Old identity | Current identity |
| --- | --- |
| `Singular.NamingStatements.naming_nm4_admissions@9ceae1055a1f5e64cc5f6a70e0b3f602d495b38b7b386da4a9ad367d8a194eed` | `Singular.NamingStatements.naming_nm4_admissions@58634bf3e3a405d46b8b2dc725dd568f02f72bc18e0642c945b704d299f6df38` |
| `Singular.Statements.no_tree_change_without_approval@a2fa6756fc4504f0ee55be8013dfb05cf94fde2ae06777cf62c25cfd5352ca1b` | `Singular.Statements.no_tree_change_without_approval@675ac9aa1522c14f7f620861bbea5194b21721f612e594c6aa48fe9b753f248b` |
| `Singular.Statements.occupancy@f73130188c3bb9170d2a56dfaa4c965d1cd7ea93b31077d5b13f0c6b136aa876` | `Singular.Statements.occupancy@b6760b43f9a243015d269f18ac4932eaf9a3887571df7d6637ef63bb4a7e4b40` |
| `Singular.Statements.termination@daae0dd7f3dbce91850f546e619f4247a3a7688fbdaf6018f96e7213b5f91027` | `Singular.Statements.termination@99a39dc2ba8581b8d2ea5d9c5dfad152d1a506551706eedf14ec36087e1e8bc2` |
| `Singular.refusal_none_iff@2b5f639e5292d87b8f2cd0b229da076411f31a1840e2f4e5eeb8183849b0a85c` | `Singular.refusal_none_iff@8a9f01a60a43bdc131ca3c541439b35540ac2d0f6485147e07dde2263dcfd299` |

The active discovery is 121 obligations: 67 manifest-bound and 54 unclassified.
The generic manifest changes from 46 to 36 declarations. Naming, lifecycle, wire
and the ten M1 admission declarations remain separately counted. Public consumer
requirement rows, rejection, retraction, refunds and public-fold debts remain
visible and uncovered wherever no qualifying receipt exists. The ratchet still
refuses the removal of an additional active declaration.

## Within-batch holding rule

The fold inversion now requires the created-holding scan to succeed, after the
steps and keyed mint. Its previous identity is replaced below; no receipt is
reused as evidence for the stronger statement. No public consumer row changes
state. The three new public statements and eight helper lemmas enter the
discovered population without claiming implementation coverage.

| Previous identity | Current identity |
| --- | --- |
| `Singular.Statements.fold_batch_cons@9e8c6a06d60361ae94b24f50f014c7830bfdd5d22aa8b7a62a8ca9230f689153` | `Singular.Statements.fold_batch_cons@a0992d97ae5b6f86503bdc5247b4b2602ec74a5516713e274c4919aa53d5d26f` |

Discovery now reports 132 obligations: 70 manifest-bound and 62 unclassified.

## Fold admission through each request's deadline

The operator's fold-window ruling restates the three identities below. Their
old receipts are not evidence for the new signatures. The six new statements
enter the population uncovered; no public consumer requirement gains coverage.
Only identities already in the protected baseline are replaced there.

| Previous identity | Current identity |
| --- | --- |
| `Singular.Statements.admission_refuses_first@c7ed5cabec1c955cf43772cdabcb547307d9c7023fc45dac90d347f45b61bcc7` | `Singular.Statements.admission_refuses_first@e0fa0ecb9342d5d641283ccb9aa79dcf301bafff268773e85f1e8508b48bc5b4` |
| `Singular.Statements.admitted_exit_is_the_exit@3182f6fcacacf71f257ba4ddd17ec276302e04ba5342726b4833a8be51d68c38` | `Singular.Statements.admitted_exit_is_the_exit@d676fedbea60c9da158ec41e9285e3d929d780dce4e0424d214a670ea0735516` |
| `Singular.Statements.fold_batch_of_one_is_step@09dc61dcbe8e7a4a68b170944bb42cdcf6ece9af9fc006af96135cfab1185f87` | `Singular.Statements.fold_batch_of_one_is_step@b6226a82c352b27b0fac2034592963f240da8696a44e088baeaca770d9e7c665` |

Discovery now reports 138 obligations: 76 manifest-bound and 62 unclassified.
