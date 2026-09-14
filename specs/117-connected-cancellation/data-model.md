# State carried by the connected pair

`Naming.Connected.Registration` is the public immutable receipt binding consumed
seed, registry policy/token, native request output index/address/datum, full
refund address, and unchanged four-field naming datum. The claim and request
are created in the same transaction. Active custody guards prevent pending claim
relocation, preserving the output-origin binding.

Insert and withdrawal certificate names are distinct domain-separated hashes.
The withdrawal certificate binds registry, exact consumed request and refund;
it remains at the refund output after both pending inputs and Insert token die.
Exact encodings and A-003/A-004 authority are in [decisions.md](decisions.md).
