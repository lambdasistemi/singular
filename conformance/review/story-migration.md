# Case migration receipt

Baseline: `4108173` (the old executable cases are unchanged from `d92f35b`).
39 product cases were walked by an executable comparing each old receipt
expression to the new operational program's folded receipt, then running both
through the real loader. Each verdict predicate was also compared on `Left`,
`Right 0`, `Right 1` and `Right 2`. File paths in refusal diagnostics were
normalized; the refusal diagnostic following the path was compared exactly.
The ten supporting cases below retain byte-identical bodies and run in the suite.

**49 cases; differing inputs: 0; differing predicates: 0.**
The clause/name hygiene check is additional machinery, moved to Story.BindingControl.
The report cases now live in the appendix; live product stories occupy `Edge.*` and `Fold.*`. The original titles remain below as historical identities; the next column gives the current stakeholder-facing title. Only titles changed after the recorded sweep; the case programs and assertions are unchanged.

| Original case | Current title | New module | Old predicate = new predicate |
|---|---|---|---|
| one active token at the key, at the address the request named | A registration report is accepted when the requested address receives one active token for the key | `Support.RegistrationReport` | loader returns exactly Right 1 |
| no token delivered | A registration report is rejected if no active token is delivered | `Support.RegistrationReport` | loader returns Left |
| two tokens delivered at the key | A registration report is rejected if two active tokens are delivered for the same key | `Support.RegistrationReport` | loader returns Left |
| a token delivered under the open policy instead of the active one | A registration report is rejected if the delivered token comes from the wrong minting policy | `Support.RegistrationReport` | loader returns Left |
| a token whose asset name is not the key | A registration report is rejected if the token names a different key | `Support.RegistrationReport` | loader returns Left |
| a token observed at an address the request did not name | A registration report is rejected if the token goes to the wrong address | `Support.RegistrationReport` | loader returns Left |
| a mint that is not exactly one token at the key | A registration report is rejected if no active token was created for the key | `Support.RegistrationReport` | loader returns Left |
| an open application that declares a parameter | A registration report is rejected if the open application declares a parameter | `Support.RegistrationReport` | loader returns Left |
| a fold that paid a refund | A registration report is rejected if applying the request also pays a refund | `Support.RegistrationReport` | loader returns Left |
| a fold that required a signer | A registration report is rejected if applying the request requires a signer | `Support.RegistrationReport` | loader returns Left |
| a request whose lovelace does not cover the tip | A registration report is rejected if the request cannot pay the processing tip | `Support.RegistrationReport` | loader returns Left |
| a destination binding the approval does not carry | A registration report is rejected if the approval does not match the delivery address | `Support.RegistrationReport` | loader returns Left |
| a fold that moved a non-root configuration pin | A registration report is rejected if applying the request changes the maximum fee | `Support.RegistrationReport` | loader returns Left |
| a configuration observation that lost a pin | A registration report is rejected if the original settings are missing | `Support.RegistrationReport` | loader returns Left |
| a leg whose trace the ledger did not surface is accepted | Evidence of a rejected duplicate registration is accepted without a script log | `Support.RegistrationReport` | loader returns exactly Right 1 |
| a leg whose control is the transaction it refused | Rejects duplicate-registration evidence that calls the same transaction both rejected and successful | `Support.RegistrationReport` | loader returns Left |
| a leg naming no failing script | Rejects duplicate-registration evidence that does not identify the script that failed | `Support.RegistrationReport` | loader returns Left |
| a leg naming an empty failing script | Rejects duplicate-registration evidence with a blank identifier for the failing script | `Support.RegistrationReport` | loader returns Left |
| a duplicate leg naming two keys | Rejects duplicate-registration evidence naming two keys instead of the one already registered | `Support.RegistrationReport` | loader returns Left |
| a duplicate leg naming a key the fold did not insert | Rejects duplicate-registration evidence naming a key this run never registered | `Support.RegistrationReport` | loader returns Left |
| a duplicate leg carrying mint arithmetic | Rejects duplicate-registration evidence mixed with token allocation data from the separate batch example | `Support.RegistrationReport` | loader returns Left |
| a refused transaction that also landed as a fold | Rejects duplicate-registration evidence if the rejected transaction also appears among successful transactions | `Support.RegistrationReport` | loader returns Left |
| a control that never landed a fold | Rejects duplicate-registration evidence if the successful comparison transaction is absent from the run | `Support.RegistrationReport` | loader returns Left |
| a leg whose distinguisher is empty | A batch rejection report must explain what differs from the successful comparison | `Support.BatchReport` | loader returns Left |
| a keyed-mint leg reusing the duplicate's transaction | A batch rejection report cannot reuse the transaction from the duplicate-registration example | `Support.BatchReport` | loader returns Left |
| two legs sharing one accepting control | The batch and duplicate-registration examples must each identify their own successful comparison transaction | `Support.BatchReport` | loader returns Left |
| a keyed-mint leg naming one key | A report about a two-key batch is rejected if it lists only one key | `Support.BatchReport` | loader returns Left |
| a keyed-mint leg naming the same key twice | A report about a two-key batch is rejected if it lists the same key twice | `Support.BatchReport` | loader returns Left |
| a keyed-mint leg naming three keys | A report about a two-key batch is rejected if it lists three keys | `Support.BatchReport` | loader returns Left |
| a keyed-mint leg naming an empty key | A report about a two-key batch is rejected if either key is blank | `Support.BatchReport` | loader returns Left |
| a keyed-mint leg reusing the fold's own key | A batch rejection report cannot borrow a key from the separate single-registration example | `Support.BatchReport` | loader returns Left |
| a keyed-mint leg whose claim also disagrees per kind | Rejects a report that claims the total is correct while listing three tokens where two are required | `Support.BatchReport` | loader returns Left |
| a keyed-mint leg whose claim agrees per key as well | A report claiming a wrong allocation is rejected if each key actually receives its required token | `Support.BatchReport` | loader returns Left |
| a keyed-mint leg claiming a mint at neither named key | A batch rejection report is rejected if the claimed tokens name a key outside the batch | `Support.BatchReport` | loader returns Left |
| a keyed-mint leg entailing a mint at neither named key | A batch rejection report is rejected if the required tokens name a key outside the batch | `Support.BatchReport` | loader returns Left |
| a keyed-mint leg with no claimed mint at all | A batch rejection report must say which tokens the rejected transaction tried to create | `Support.BatchReport` | loader returns Left |
| a keyed-mint control that minted the refused claim | A successful comparison must correct the allocation, not put both tokens at the first key again | `Support.BatchReport` | loader returns Left |
| a keyed-mint control that minted at another key | A successful comparison must allocate its tokens to the two keys in the batch | `Support.BatchReport` | loader returns Left |
| an absent keyed-mint leg is refused | A registration run report is rejected if the required batch-rejection example is missing | `Support.BatchReport` | loader returns Left |
| names every field of the observation before mutating one | Checks that the example report contains all the fields used by the missing-data tests | `Support.Observation` | 20 edge fields; exact duplicate/keyed field extents |
| refuses a receipt that carries no observation at all | Rejects a report with no registration evidence | `Support.Observation` | loader returns Left |
| refuses the observation with any single field absent | Rejects a registration report whenever any required top-level field is missing | `Support.Observation` | loader returns Left for every discovered mutation |
| refuses either refusal leg with any required field absent | Rejects either rejection example whenever any required detail is missing | `Support.Observation` | loader returns Left for every discovered mutation |
| refuses a landed fold whose root did not move | Rejects a report saying a successful registration left the registry contents unchanged | `Support.Observation` | loader returns Left |
| refuses a second fold proved against the boot root | Rejects a report whose second transaction starts from the initial registry instead of the first transaction's result | `Support.Observation` | loader returns Left |
| refuses a committed root that disagrees with the chain's | Rejects a report whose recorded registry state disagrees with its reported transaction result | `Support.Observation` | loader returns Left |
| refuses an empty landed-fold sequence | Rejects a report that lists no successful request-processing transactions | `Support.Observation` | loader returns Left |
| refuses a fold transaction absent from the landed sequence | Rejects a report whose registration transaction is missing from its list of successful transactions | `Support.Observation` | loader returns Left |
| refuses edge evidence on a row carrying another identity | Rejects registration evidence submitted under a different requirement | `Support.Observation` | loader returns Left |

The new configuration edit preserves string-valued pins, matching the original
receipt input exactly. Rejection remains `Left`; `Right 2` satisfies neither
acceptance nor rejection. The one-receipt meaning is shared by every case.

The temporary comparison runner was removed after the sweep; it is not a
second shipped implementation. Its captured source and output hashes are:

- `Migration.hs`: `c033e80365bdff4b56c62c71bbb7fb4b439f5a3de0897994745af46c7afb9d7f`
- `migration-final-sweep-3.log`: `181057be015e29e9dab1e71255b4f9aaea4f432d47499de82034cd9503a15ac1`

## Comparator negative control

Observed on the case **two tokens delivered at the key**: changed its new
`activeToken keyHex 2` program to `activeToken keyHex 3`. Both are refused by
the loader, so a comparison of verdict class alone would miss the change.
The captured comparator executed and reported unequal receipt inputs:
expected delivered quantity 2, observed quantity 3. Exit **1**, **1 example /
1 failure**. After discarding the perturbation, the same comparator walked
all 39 product cases and exited **0**, **1 example / 0 failures**.
The temporary runner was again removed; no mutation ships.

- `sweep-control-red.log`: `9882dcfb86bfb6b08ad4e7fa33b4c3c477f2cffb7f44618556090601989c4238`
- `sweep-restored-green.log`: `e27836a9261c4d8f8b9fd3a80bf6d0b4f06b4f48614180c26ef66881caa3153b`
