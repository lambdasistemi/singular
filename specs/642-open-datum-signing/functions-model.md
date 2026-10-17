# Functions model for open-datum signing

Only changed signatures; every other function keeps its type.

## open-datum command line

- The entry, fold and create argument readers keep their types. Their refusal of the address outside a preview takes the presence of the bundle file into account on insert, update, terminate and fold, and keeps create's behaviour equal to the registry's create.
- The preview reader keeps its type and refuses the bundle file.
- The inspect reader keeps its type and refuses the bundle file and the vault.
- The usage text keeps its type and gains the signer lines.

## open-datum entry commands

- No changed signature in slice 1. In slice 2, a receipt or narration function that states a staged fact takes the staged-or-landed distinction from issue 641's write mode as an argument, if issue 641's mechanism does not already carry it.
