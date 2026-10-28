# Data for reading a key from the registry address

Issue 744. Records the reader introduces or changes, their fields and their rules. Placement is in
[the modules model](modules-model.md).

## Records

| Record | Fields | Rules |
| --- | --- | --- |
| Reading request | network (from the address), registry identity (state policy, state token name), key | taken from the registry address and the key alone; no other input decides the answer |
| Application identity | state policy, application policy, application script, Singular releases, application releases | a row of the release table; one row per applied state policy; a row may have no releases (the current build) |
| Conclusion | one of: live, pending termination, terminal, never registered | live and pending carry the holding output reference, the application identity and the holding's datum; terminal and never registered carry the registry state output reference and the root the leaf was read against |
| Refusal | one of: wrong network (both networks, the provider), unknown state policy (the policy), token outside application custody (where it is), conflicting evidence (what conflicts), unavailable (which read and why) | a refusal is never a conclusion; unavailable is never an absence |
| Query work | per read: name, calls, rows, bytes, elapsed; totals | counted from the provider trace of the reader's own session, not estimated |

## State rules

- The active token's name is computed by the reader from the registry identity and the key; a token under another name
  or policy is not evidence about the key.
- Live and pending require exactly one output holding exactly one active token, at the application's script; anything
  else is a refusal.
- Terminal and never registered require the registry's state recognised under the state policy and the key's leaf read
  against that state's root; a missing token alone decides neither.
