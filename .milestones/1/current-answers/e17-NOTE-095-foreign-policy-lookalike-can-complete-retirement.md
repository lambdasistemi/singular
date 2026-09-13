# NOTE-095 — foreign-policy lookalike can complete retirement

Issued: 2026-09-13T05:26:00Z
From: M1 owner
To: E17 owner
Disposition: actionable correction; same Grok epic owner and existing lanes only

## Outcome at risk

As a name owner, I need permanent retirement to destroy the authentic
representative for my registry entry, so that a third party cannot mark my name
Over by creating and burning its own lookalike token.

The current candidate 27e5f9a34f2a96356ce319885d5d0acc282dba62
does not yet provide that outcome.

## Executed finding

Root executed the actual current state, request, consumer, and
retirement_custody handler functions in one value-balanced synthetic
transaction context. All four accept an authentic singleton Active-to-Over
update when custody holds and burns a token with the authentic representative
asset name under an unrelated policy. The configured representative policy
mints zero, so the authentic representative policy need not execute and its
token can remain live.

Receipt:
/tmp/projects/singular/milestone-1/handoffs/e17-root-foreign-policy-control.json
SHA256
fcc23b8b03994bc2937c0c881ff4e4d99a26ed83b6273f7d1fad94dc33ebc47b.
The raw focused run is 5/5 at
handoffs/e17-root-foreign-policy-control.log; it includes the authentic-policy
positive and wrong-name, missing-burn, and missing-hook negatives.

The mechanism is exact: retirement_custody.burned_of selects by asset name
and discards the held policy. consumer.check_rep_mints considers only
positive mints under state.representative_policy, so it cannot close this
negative-mint path.

## Required correction and falsifiable evidence

Commission the existing E17 implementation lane to bind the custody-held and
burned asset's complete (policy, name, quantity) identity to the spent
registry state's configured representative_policy, using the existing
naming.mpfs_state_policy decoder or an equally direct executing-layer check.
Keep exact name and quantity-one/burn-minus-one checks.

Require all of the following on the repaired source:

1. the same four actual handlers accept the authentic-policy completion;
2. the exact foreign-policy lookalike witness above refuses specifically at
   custody;
3. deleting or weakening only the policy equality makes that witness accept;
4. the connected devnet Over journey still proves the genuine custody spend,
   authentic burn, root update, permanent Over readback, and reuse refusal;
5. existing legitimate nonempty rejected, mixed, zero-net, and separate
   unspent-custody cases remain accepted.

Preserve every prior failed and superseded exhibit. Run only checks affected by
this repair plus the final required E17 acceptance route; do not manufacture a
second ledger authority or widen the generic consumer.

## LT04 ruling

Treat LT04 as the user outcome “any ordinary user can complete retirement
without controller or quorum approval.” The completion transaction must have
zero required signers and exactly one fresh fee-input-owner witness outside
every controller/quorum route. That ordinary input witness is ledger
conservation mechanics and is allowed. Do not describe the evidence as an
empty witness set or “no signature of any kind.”

Route this ruling through the ticket owner to close its Q-002 durably.

## Remaining E17 handback

After this repair, finish the already named remainder in the same epic:
LX01/N2 control modes, integration and acceptance of the 83b359f lone-fork
fix, and the final applied/unapplied ABI tuple. Hand back one consolidated
E17 candidate with source identities, executed controls, actual journey
evidence, and explicit ticket/story dispositions. Do not release the tuple to
E18, merge, push, or claim epic acceptance before the M1 cross-contract review.

No new seats, model changes, Claude use, reset, retry campaign, Scalus work,
later epic, release, or M2 work.
