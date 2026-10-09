# M1 scope retirement

As a coverage reader, I need to distinguish obligations retired by the operator
from requirements the current implementation has not demonstrated.

NOTE-005 (8 October 2026), "ok, now, big delete", removes excluded M2 success
behavior from the active M1 model. A-003 authorizes the existing baseline-move
process without changing the coverage gate. The following exact identities are
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
