# Public fold inputs: tasks

Read the [plan](plan.md) for the module rows. Each slice is pushed when its gate is green.

## Slice: model

As a maintainer, I want the model to fail whenever a fold needs an input the chain does
not hold.

- [ ] Model statements failing: `delivered_datum_is_request_datum`, `fold_inputs_public`
  and `fold_refuses_foreign_datum` stated against the datum value, committed failing.
- [ ] Model datum value: the request, the delivered output and the holding carry the
  datum value; the three statements prove; `namesDatum` is gone.
- [ ] Model consumers: driver corpus, corpus, theorem manifest, application model,
  simulator mirror, conformance transport and coverage records, constitution `tx` row.

## Slice: wire

As Alice, I want my request to carry my datum, so anyone can fold it.

- [ ] Cage refusals failing: Aiken tests for a foreign datum, a datum where none is named,
  none where one is named, and `witnessTerminal`, committed failing.
- [ ] Cage destination: `Request.destination` carries the datum; equality check; derived
  approval hash; naming's mirror; script identities and vectors.
- [ ] Off-chain wire: booking writes the datum into the request; the fold reads it from
  the request the provider returns; oversize bookings refused before submission.
- [ ] Preimage store removed: `Preimage.hs`, `preimages/` and every caller.

## Slice: two actors

As Bob, I want to fold Alice's insertion with none of her files.

- [ ] Two-actor run failing: Bob's fold from a directory without Alice's files is refused
  for the missing envelope on a tree without the wire slice; the receipt is kept.
- [ ] Two-actor run passing on the development network, in the CI job that runs the
  packaged commands.
