# What creating a registry costs

As a registry creator, you can compare what the first and a later registry cost under the previous design and the application-held design. The figures below are measured from transactions included on a development network; fees are spent ADA, while ADA locked in reference outputs remains in those outputs.

The two legs run the previous design's last release and this line's release of open datum. Their validators differ: this compares two creation workflows, rather than one release run twice. Within each design, both creations use the same executable and deployment blueprint.

## Measured creations

The previous design sent 5 transactions for its first creation and 4 for its later creation. The issue's four-then-two claim does not match these measured counts. The application-held design sent 3 and 1 respectively.

The first creation starts without a live copy of any script it needs. Later creations have the earlier shared copies available. Under the previous design only the state script is shared; request, witness and application scripts are specific to the new registry. The application-held design reuses both the state and application scripts.

| Design | Creation | Transactions | Transaction bytes | Outputs created | Fees (lovelace) | Reference outputs | Reference script bytes | ADA locked in reference outputs (lovelace) |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| previous | first | 5 | 28296 | 10 | 4695626 | 4 | 26557 | 122012110 |
| previous | later | 4 | 16801 | 8 | 3695371 | 3 | 15293 | 71576410 |
| candidate | first | 3 | 19118 | 7 | 2136465 | 2 | 17625 | 77773950 |
| candidate | later | 1 | 999 | 3 | 1028555 | 0 | 0 | 0 |

## Witness publication overhead

The previous design publishes an active witness policy for each registry. That publication is unused by the permanent two-edge contract. Its fee and its reference-output capital are included above and separated below; they must not be added twice. The application-held design publishes no witness policy.

| Design | Creation | Witness publication transactions | Witness publication fees (lovelace) | Witness reference ADA (lovelace) |
|---|---|---:|---:|---:|
| previous | first | 1 | 1000000 | 9038150 |
| previous | later | 1 | 1000000 | 9038150 |
| candidate | first | 0 | 0 | 0 |
| candidate | later | 0 | 0 | 0 |

## Transactions and reference outputs

Every creation transaction is listed in submission order. Spent and read inputs are output references decoded from that transaction. Each reference output lists the hash computed from its carried script, the script's byte length and its locked lovelace.

### Previous design

Release: `open-datum 0.16.0 (commit 0c0ab880df982a728b6b89a1e80fc1308144d616)`. Revision: `0c0ab880df982a728b6b89a1e80fc1308144d616`. Deployment blueprint SHA-256: `ac43d782181121dcdedfd4a9c48b89fb6fa77dd69e7c9f5619110ca8efb0688b`.

**First creation**

| Step | Transaction | Bytes | Fee (lovelace) | Created outputs | Spent inputs | Read inputs |
|---|---|---:|---:|---:|---|---|
| publish-state | `f6a3dd2366f5831f89aba7b6b0ab1656a2953dde74fe066e6f091aba9c68e959` | 11511 | 1000000 | 2 | `eaf23b6df2aaf1c004154f759502547774c7be4aa85e66402bfe02f986c12eda#0` | none |
| boot | `d6bb9a2c52f192407789855b1d3fd2dac31e51e5da851946741f0b02b76267e6` | 751 | 695626 | 2 | `eaf23b6df2aaf1c004154f759502547774c7be4aa85e66402bfe02f986c12eda#1`, `f6a3dd2366f5831f89aba7b6b0ab1656a2953dde74fe066e6f091aba9c68e959#1` | `f6a3dd2366f5831f89aba7b6b0ab1656a2953dde74fe066e6f091aba9c68e959#0` |
| publish-request | `cc1dc74a34bcf41b14e22b8ca8273f74bcb80afe4890efc4ff074bd422896605` | 3955 | 1000000 | 2 | `d6bb9a2c52f192407789855b1d3fd2dac31e51e5da851946741f0b02b76267e6#1` | none |
| publish-witness-active | `e8aaceac35b3a97a5b1f0791f6635571ce06668b15df129ab0c4be82e163ffbd` | 1906 | 1000000 | 2 | `cc1dc74a34bcf41b14e22b8ca8273f74bcb80afe4890efc4ff074bd422896605#1` | none |
| publish-application | `d5e743cf06b0c4502a8a24fc367f83f24db162886afb5880cfec983a169e8387` | 10173 | 1000000 | 2 | `e8aaceac35b3a97a5b1f0791f6635571ce06668b15df129ab0c4be82e163ffbd#1` | none |

| Reference output | Script hash | Script bytes | Locked lovelace |
|---|---|---:|---:|
| `f6a3dd2366f5831f89aba7b6b0ab1656a2953dde74fe066e6f091aba9c68e959#0` | `9a84eabb747716a3092996049b5003a97954fa272902f0bf8f744a98` | 11264 | 50435700 |
| `cc1dc74a34bcf41b14e22b8ca8273f74bcb80afe4890efc4ff074bd422896605#0` | `8f7c44a26696c225c8e692875083de8082ec8ac6bcd72514caacb4f9` | 3708 | 17869340 |
| `e8aaceac35b3a97a5b1f0791f6635571ce06668b15df129ab0c4be82e163ffbd#0` | `3f4b0f8405beaf9865ad93d01f18fa2a7709fab2ca23dd59ae849831` | 1659 | 9038150 |
| `d5e743cf06b0c4502a8a24fc367f83f24db162886afb5880cfec983a169e8387#0` | `4c76918bbbbb1b99331ee670f1a20ca4c00e0311c88c04c3272f36f1` | 9926 | 44668920 |

**Later creation**

| Step | Transaction | Bytes | Fee (lovelace) | Created outputs | Spent inputs | Read inputs |
|---|---|---:|---:|---:|---|---|
| boot | `1a656e2dabf600c722453c949097f87b8188e02d1eb432271f3ad7b37adba171` | 755 | 695371 | 2 | `d5e743cf06b0c4502a8a24fc367f83f24db162886afb5880cfec983a169e8387#1`, `eaf23b6df2aaf1c004154f759502547774c7be4aa85e66402bfe02f986c12eda#2` | `f6a3dd2366f5831f89aba7b6b0ab1656a2953dde74fe066e6f091aba9c68e959#0` |
| publish-request | `d9ff76efb3d132ca4ca30b5f7998e57a8bebe28b6ccf593a0ea6861eb647481e` | 3959 | 1000000 | 2 | `1a656e2dabf600c722453c949097f87b8188e02d1eb432271f3ad7b37adba171#1` | none |
| publish-witness-active | `26cb61f8b0447ecce8395c14245eba5c9750b1dbe0314b42d15982b072971858` | 1910 | 1000000 | 2 | `d9ff76efb3d132ca4ca30b5f7998e57a8bebe28b6ccf593a0ea6861eb647481e#1` | none |
| publish-application | `f70d808a828ea2c4dd479ad2ac30fe01c0d8171f9784106b877515919ca77670` | 10177 | 1000000 | 2 | `26cb61f8b0447ecce8395c14245eba5c9750b1dbe0314b42d15982b072971858#1` | none |

| Reference output | Script hash | Script bytes | Locked lovelace |
|---|---|---:|---:|
| `d9ff76efb3d132ca4ca30b5f7998e57a8bebe28b6ccf593a0ea6861eb647481e#0` | `b1c8f3537b0de68bb38f37064458404badb7e030b888f59f2f70bb6f` | 3708 | 17869340 |
| `26cb61f8b0447ecce8395c14245eba5c9750b1dbe0314b42d15982b072971858#0` | `fe69e0430375e06e3e34f3791e57bef024e393a06c938f795b80f8c2` | 1659 | 9038150 |
| `f70d808a828ea2c4dd479ad2ac30fe01c0d8171f9784106b877515919ca77670#0` | `5657c576b7c9d57d27482d024af225de93a8e11e75bc6c8ef37092f7` | 9926 | 44668920 |

### Candidate design

Release: `open-datum 0.17.0 (commit ede9f7992c4936474d3ed86f890ffa2e6fddf625)`. Revision: `ede9f7992c4936474d3ed86f890ffa2e6fddf625`. Deployment blueprint SHA-256: `6ad16a3194cff51f0600edfe0eb95917ed0679693e1e4b6f332ad1072c07d3d1`.

**First creation**

| Step | Transaction | Bytes | Fee (lovelace) | Created outputs | Spent inputs | Read inputs |
|---|---|---:|---:|---:|---|---|
| publish-state-script | `b71205fb81942079ee39fd824a1a4cb2bcd76d6814a39245a19ff2ff1717b32c` | 8031 | 508701 | 2 | `eaf23b6df2aaf1c004154f759502547774c7be4aa85e66402bfe02f986c12eda#0` | none |
| publish-application-script | `6e5a2bb572a556068fa9556699377e6f3a614153977d3ac2206d2816e09963b1` | 10088 | 599209 | 2 | `eaf23b6df2aaf1c004154f759502547774c7be4aa85e66402bfe02f986c12eda#1` | none |
| create | `9bf4cbd3d7d2b2ced415e6e0883e0592f3e9ea04f577c16ab658fd06a9e40bb5` | 999 | 1028555 | 3 | `eaf23b6df2aaf1c004154f759502547774c7be4aa85e66402bfe02f986c12eda#2` | `6e5a2bb572a556068fa9556699377e6f3a614153977d3ac2206d2816e09963b1#0`, `b71205fb81942079ee39fd824a1a4cb2bcd76d6814a39245a19ff2ff1717b32c#0` |

| Reference output | Script hash | Script bytes | Locked lovelace |
|---|---|---:|---:|
| `b71205fb81942079ee39fd824a1a4cb2bcd76d6814a39245a19ff2ff1717b32c#0` | `499291dbc77fb84b590e4f2d728788aa06191627a2c5c95b6bc4d679` | 7784 | 34454140 |
| `6e5a2bb572a556068fa9556699377e6f3a614153977d3ac2206d2816e09963b1#0` | `67bb50e5aab678b9955e1d8981050a14e0f93da912b3a8b4a7161ca7` | 9841 | 43319810 |

**Later creation**

| Step | Transaction | Bytes | Fee (lovelace) | Created outputs | Spent inputs | Read inputs |
|---|---|---:|---:|---:|---|---|
| create | `db5cc53eaa3112fc736d44d6cb03264328dd4265efd85c2de51bc70941413e6b` | 999 | 1028555 | 3 | `eaf23b6df2aaf1c004154f759502547774c7be4aa85e66402bfe02f986c12eda#3` | `6e5a2bb572a556068fa9556699377e6f3a614153977d3ac2206d2816e09963b1#0`, `b71205fb81942079ee39fd824a1a4cb2bcd76d6814a39245a19ff2ff1717b32c#0` |

| Reference output | Script hash | Script bytes | Locked lovelace |
|---|---|---:|---:|
| none | none | — | — |

## Can creation carry its scripts

The measuring tool built 5 registry-creation forms with the real genesis and application configuration builders, on one fresh development network with the same frozen protocol parameters as the comparison above. Each form creates a fresh registry with the same configuration; only script placement changes. The normal referenced form is the reference point. These are experiments, and the production command keeps its shared publications.

Both live copies were available for this controlled experiment. A form carrying a script deliberately ignores that script's live copy. A form creating reference outputs also carries witnesses: a transaction cannot read its own new outputs as reference inputs.

The state-carried form has 8764 complete signed bytes and the application-carried form has 10821. The node accepted and confirmed both mixed forms. Each still needs the other script's live reference output.

Carrying both scripts in witnesses has 18567 complete signed bytes; carrying them in witnesses and new reference outputs has 36292. The node refused both for maximum transaction size: it counts 18566 and 36291 bytes respectively, against a limit of 16384. The complete signed transaction length and the length the ledger counts are different figures; the ledger count here is one byte less. Both appear below.

| Creation form | Complete signed bytes | Ledger-counted bytes | Fee (lovelace) | Evaluated memory | Evaluated steps | Node outcome | Limiting parameter |
|---|---:|---:|---:|---:|---:|---|---|
| Both scripts read from live reference outputs | 1008 | 1007 | 1028951 | 625441 | 245125425 | accepted and confirmed | none |
| Both scripts carried in witnesses | 18567 | 18566 | 1026047 | 625441 | 245125425 | refused | maximum transaction size |
| Both scripts carried in witnesses and new reference outputs | 36292 | 36291 | 1808361 | 656209 | 253987129 | refused | maximum transaction size |
| State script carried; application script referenced | 8764 | 8763 | 1027719 | 625441 | 245125425 | accepted and confirmed | none |
| Application script carried; state script referenced | 10821 | 10820 | 1027719 | 625441 | 245125425 | accepted and confirmed | none |

A fit requires successful execution, size within the ledger limit, and the development node's acceptance and confirmation. The execution figures are the ledger evaluator's final results on the actual chain inputs and equal the signed execution budgets. The oversized forms were evaluated locally, then refused by the node's size check before its script-execution phase; their execution figures do not claim node execution. A size comparison alone is never reported as a fit.

### Frozen limits and fee parameters

Every form used maximum transaction size 16384, maximum transaction execution memory 140000000 and maximum transaction execution steps 10000000000. The parameters and their hash are read from the independent chain record, rather than supplied by the measuring command.

| Parameter | Chain-read value |
|---|---:|
| Maximum transaction bytes | 16384 |
| Maximum transaction execution memory | 140000000 |
| Maximum transaction execution steps | 10000000000 |
| Fee per byte (lovelace) | 44 |
| Fixed fee (lovelace) | 155381 |
| Execution price per memory unit | 0.0577 |
| Execution price per step | 7.21e-05 |
| Initial reference-script fee per byte (lovelace) | 44 |

The experiment holds the application's configuration fixed across forms. These explicit experimental values do not change command defaults.

| Application configuration | Value |
|---|---:|
| Registration cost (lovelace) | 3000000 |
| Minimum tip (lovelace) | 1000000 |
| Processing window (milliseconds) | 60000 |
| Reclaiming window (milliseconds) | 180000 |
| Booking width (milliseconds) | 60000 |

### What the result gives a creator

Each fitting mixed form still needs one prior publication. When a first creation finds no live copy, it cannot skip both publications by carrying: the both-witness form that needs no live reference is refused for size. A fitting mixed form creates no reference output for the script it carries. If a first creation published only the other script, a later registry using the unchanged production command would still have to publish the carried script. Carrying defers that publication; it does not remove it.

The production workflow remains as measured: the first creation sends 3 transactions, and the later creation sends 1 transaction by reusing the shared publications. The measured carrying outcomes are reported without recommending or adopting a mixed form.

### Measurement appendix

The [carrying receipt](https://github.com/lambdasistemi/singular/blob/main/specs/745-shared-publications/evidence/carrying.json) records the test-only producer, its exact source changes and executable hash, the signed transactions, local execution results and independent node answers. The experiment has its own recorded genesis and start time; its protocol parameters match the earlier creation comparison. The receipt checker recomputes lengths, fees, script hashes, placements and execution budgets, binds each transaction to the independent node submission, and requires identical included bytes for every fit. Every refusal must reproduce the node's limiting parameter and figures. Missing forms, missing execution, altered figures and false fits are refused by the hosted documentation check. The test harness is outside the released command's source and changes no production builder or shared receipt.

## Matched conditions and evidence

The legs use separate fresh development networks from the same frozen genesis, the same protocol parameters, the same generated wallet funding and the same processing and reclaim windows. Each network is read independently. The receipts include the complete chain-read protocol parameters and the tool versions.

| Shared condition | Value |
|---|---|
| shelleyGenesisSha256 | `fe73bc3cbe2fdda6252a502907910a417a6940dd436c320e56b0e30f034ecaf2` |
| byronGenesisSha256 | `7ce284b6929a13c51de05453b6b81942f99daffe3d9b00be43b38adfd24580b8` |
| protocolParametersCborSha256 | `9f9a1e07d4db2441bed128d468ebab7c2ee4e271c5ba358a0afc3271e42bdeb8` |
| protocolParametersSha256 | `135d40e7b1461697bb6690105bf71aedf638696cbced6f0b53a1ccb8a87bf5d7` |
| creations | ['first', 'later'] |
| fundingOutputs | 8 |
| fundingLovelacePerOutput | 2000000000 |
| processingMilliseconds | 60000 |
| reclaimingMilliseconds | 180000 |

The [committed receipts and chain records](https://github.com/lambdasistemi/singular/tree/main/specs/745-shared-publications/evidence) preserve the transactions, their complete bytes and the network observations. The documentation check recomputes every figure from those bytes, checks the two workloads and regenerates this entire page for comparison. Altered figures and mismatched legs are refused. The hosted registration journey writes the candidate receipt in the same schema and compares its transaction counts and script hashes; fees may differ between runs.

## Limits

These are development-network measurements, not fee quotes for another network. Reference-output capital is reported separately from fees; this page does not claim it is spent. The measured transactions do not establish public reference discovery for everyone, batch limits or release acceptance. Those remain the work of issues 355 and 473, issue 746 and issue 747 respectively. Existing uncovered registration comparisons remain uncovered.

Creation behavior remains bound to the application-held model's genesis and recognition inversions, creation money statement, configuration creation inversion and immutable configuration statement. This measuring tool changes no validator, model or wire format, and the measurements do not establish new model conformance. The trie library's proofs are assumed sound.
