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
The old 49 case identities are retained, so the case text is the old-to-new key.

| Case (old EdgeSpec to new asset) | New module | Old predicate = new predicate |
|---|---|---|
| one active token at the key, at the address the request named | `Edge.Register` | loader returns exactly Right 1 |
| no token delivered | `Edge.Register` | loader returns Left |
| two tokens delivered at the key | `Edge.Register` | loader returns Left |
| a token delivered under the open policy instead of the active one | `Edge.Register` | loader returns Left |
| a token whose asset name is not the key | `Edge.Register` | loader returns Left |
| a token observed at an address the request did not name | `Edge.Register` | loader returns Left |
| a mint that is not exactly one token at the key | `Edge.Register` | loader returns Left |
| an open application that declares a parameter | `Edge.Register` | loader returns Left |
| a fold that paid a refund | `Edge.Register` | loader returns Left |
| a fold that required a signer | `Edge.Register` | loader returns Left |
| a request whose lovelace does not cover the tip | `Edge.Register` | loader returns Left |
| a destination binding the approval does not carry | `Edge.Register` | loader returns Left |
| a fold that moved a non-root configuration pin | `Edge.Register` | loader returns Left |
| a configuration observation that lost a pin | `Edge.Register` | loader returns Left |
| a leg whose trace the ledger did not surface is accepted | `Edge.Register` | loader returns exactly Right 1 |
| a leg whose control is the transaction it refused | `Edge.Register` | loader returns Left |
| a leg naming no failing script | `Edge.Register` | loader returns Left |
| a leg naming an empty failing script | `Edge.Register` | loader returns Left |
| a duplicate leg naming two keys | `Edge.Register` | loader returns Left |
| a duplicate leg naming a key the fold did not insert | `Edge.Register` | loader returns Left |
| a duplicate leg carrying mint arithmetic | `Edge.Register` | loader returns Left |
| a refused transaction that also landed as a fold | `Edge.Register` | loader returns Left |
| a control that never landed a fold | `Edge.Register` | loader returns Left |
| a leg whose distinguisher is empty | `Fold.KeyedMint` | loader returns Left |
| a keyed-mint leg reusing the duplicate's transaction | `Fold.KeyedMint` | loader returns Left |
| two legs sharing one accepting control | `Fold.KeyedMint` | loader returns Left |
| a keyed-mint leg naming one key | `Fold.KeyedMint` | loader returns Left |
| a keyed-mint leg naming the same key twice | `Fold.KeyedMint` | loader returns Left |
| a keyed-mint leg naming three keys | `Fold.KeyedMint` | loader returns Left |
| a keyed-mint leg naming an empty key | `Fold.KeyedMint` | loader returns Left |
| a keyed-mint leg reusing the fold's own key | `Fold.KeyedMint` | loader returns Left |
| a keyed-mint leg whose claim also disagrees per kind | `Fold.KeyedMint` | loader returns Left |
| a keyed-mint leg whose claim agrees per key as well | `Fold.KeyedMint` | loader returns Left |
| a keyed-mint leg claiming a mint at neither named key | `Fold.KeyedMint` | loader returns Left |
| a keyed-mint leg entailing a mint at neither named key | `Fold.KeyedMint` | loader returns Left |
| a keyed-mint leg with no claimed mint at all | `Fold.KeyedMint` | loader returns Left |
| a keyed-mint control that minted the refused claim | `Fold.KeyedMint` | loader returns Left |
| a keyed-mint control that minted at another key | `Fold.KeyedMint` | loader returns Left |
| an absent keyed-mint leg is refused | `Fold.KeyedMint` | loader returns Left |
| names every field of the observation before mutating one | `Support.Observation` | 20 edge fields; exact duplicate/keyed field extents |
| refuses a receipt that carries no observation at all | `Support.Observation` | loader returns Left |
| refuses the observation with any single field absent | `Support.Observation` | loader returns Left for every discovered mutation |
| refuses either refusal leg with any required field absent | `Support.Observation` | loader returns Left for every discovered mutation |
| refuses a landed fold whose root did not move | `Support.Observation` | loader returns Left |
| refuses a second fold proved against the boot root | `Support.Observation` | loader returns Left |
| refuses a committed root that disagrees with the chain's | `Support.Observation` | loader returns Left |
| refuses an empty landed-fold sequence | `Support.Observation` | loader returns Left |
| refuses a fold transaction absent from the landed sequence | `Support.Observation` | loader returns Left |
| refuses edge evidence on a row carrying another identity | `Support.Observation` | loader returns Left |

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
