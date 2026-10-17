# Data model for open-datum signing

## Signer

Issue 641's signer, unchanged: the key file, the external signer (the address as given, and the bundle file), and, from issue 641's vault slice, the vault (the vault file and an optional passphrase descriptor). The write settings carry it. open-datum adds no variant and no field.

## Which command takes which signer

| command | key file | external signer | vault |
|---|---|---|---|
| create | yes | when the registry's create does | when the registry's vault mode lands |
| insert, update, terminate, fold | yes | from slice 1 | from slice 3 |
| inspect | refused | address only, to locate a journal; the bundle file refused | refused |
| every preview | refused | address only; the bundle file refused | refused |

## Receipt fields under expected

In the external mode, and in the vault mode until the whole bundle is found on chain, open-datum's own fields sit under issue 641's expected section, beside the bundle's hash, paths and per-transaction effects: the booking, the request, the fold deadline, the live output and the root. Once every member is found on chain by identity they are stated as fact, as today.

## Narration events

The booked, updated and root-seen events carry whether their transaction is staged or landed; a staged one is never narrated as done.
