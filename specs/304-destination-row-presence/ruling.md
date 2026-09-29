# Ruling: omit the destination row on folds that deliver nothing

Issue #304. Operator ruling, 2026-09-29, verbatim:

> Omit it: Lean describes only outputs that actually exist; amend Lean before accepting the comparison.

Question it answers: a fold that sends no token to the requester (for example a fresh
absent insertion, which puts the token and deposit in custody) has no output at the
request's destination. The ruling selects: no destination row for such a fold. It does not
select a logical normalization or a new physical carrier.

## Story

As a conformance reader, I fold a fresh absent insertion and receive an output description
of the ledger outputs that actually exist, so that the suite cannot invent a destination
output or its datum to make a comparison pass.

## What changes

- The model's fold transaction carries a destination output only when the fold routes a
  token to the requester; every other fold has none.
- One statement over all seven edges: a fold's built outputs contain a destination output
  exactly when it routes a token to the requester. A mutant that restores the unconditional
  output must fail it.
- The exported driver corpus, its simulator mirror and the constitution's `tx` row follow.

## What does not change

Deposit recipients, phase windows, signer requirements, and the inline datum and commitment
of a delivering fold's destination output.

# Ruling: the delivered output's datum follows the request

Operator ruling, 2026-09-29 ("ok" to option B). The question it answers: the model made every
delivered output inline, while the deployed state script requires no datum when the request
names an empty destination-datum hash, and refuses an inline one (`datumMatches`,
onchain/validators/lib.ak). Adding a datum in the builder alone was refused on chain in an
execution control.

The ruling: amend the model so the delivered output's datum form follows the request. It is
inline, carrying the named datum, when the request names a hash, and none when it names none.
Deposit routing, the commitment where a datum exists, and the presence rule above are unchanged.

## Story

As a conformance reader, I fold an active insertion whose request names no datum, and the
model describes the delivered output with no datum, as the chain holds it. The comparison then
reports the ledger's form rather than one the model invented.

## What changes

- A request records whether it names a datum for its delivered output (`namesDatum`, false
  unless the caller says so). A booking naming an empty hash names none.
- One statement over all seven edges: every delivered output presents an inline datum when its
  request names one, and none otherwise. A mutant that restores an unconditional inline datum
  must fail it.

## Extension: the spent witness

Operator ruling, 2026-09-29 ("ok"), extending the one above:

> The modeled holding keeps the datum form its delivering fold actually carried; a fold spending
> that holding as its burn-source witness reports that form. The spending request's own flag does
> not decide it.

The question it answers: the witness a retirement or a deletion spends is the very output an
earlier fold delivered. The model had every witness inline, and the live retirement of a key
registered without a named datum observed none.

What changes: the state records, with each holding, the datum form its delivery wrote, and a
spent witness presents that form (`witness_input_datum_is_held`, over all seven edges). A mutant
that makes every witness inline must fail. The `held` observation keeps its three fields: a
holding's datum form is observed on the transaction that spends it.
