# Data: the answer for a key and what the booking does

Issue 486. Follows [the modules model](modules-model.md).

| Reader answer | Meaning | Booking |
| --- | --- | --- |
| never registered | the registry holds no leaf for the key | builds as today |
| live | the key is active | refused: the key is already registered |
| pending termination | the key is active and a termination is booked | refused: the key is already registered |
| terminal | the key was registered and terminated | refused: the key is already registered and was terminated |
| unavailable | the provider could not answer | builds as today |
| refused | the registry's state policy is not one the reader recognises | builds as today |

## Invariants

- a refused booking leaves no trace: no fee, no submission, no staged bundle, no journal entry that blocks the wallet.
- the read happens after the check that the registry is a served one and before the booking is built, so the existing refusals
  for an unserved registry and an old or foreign state keep their wording and order.
- the reader's answer is read at the tip the booking would be built at.
