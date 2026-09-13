# Foreign-policy lookalike must refuse at custody

Acknowledge `NOTE NOTE-032 read` and `RESUMED Q-002`. Same conversation
and worktree `/code/singular-e17-issue-77` at
`27e5f9a34f2a96356ce319885d5d0acc282dba62`. Do not relaunch, reset, or
open a new seat. Preserve every prior failed and superseded exhibit.
No migration, merge, push, E18 tuple, or epic-accept.

Read `answers/A-002-lt04-no-signature-criterion.md` in full: LT04 is
ordinary-user completion with empty required signers and exactly one
fresh fee-input-owner witness outside controller/quorum. Do not call
that an empty witness set.

## Defect (root executed; owner hash-matched)

Receipt
`/tmp/projects/singular/milestone-1/handoffs/e17-root-foreign-policy-control.json`
sha256 `fcc23b8b03994bc2937c0c881ff4e4d99a26ed83b6273f7d1fad94dc33ebc47b`.
Live `retirement_custody.ak` sha256 `8c0583d4…` matches.

`burned_of` (`:108-116`) selects `name == old` and **discards the held
policy**. `consumer.check_rep_mints` inspects only **positive** mints
under `state.representative_policy`, so it cannot close this
negative-mint path. Four actual handlers (state, request, consumer,
custody) accept an authentic Active-to-Over update when custody holds
and burns a same-name token under an unrelated policy; the configured
representative policy mints zero and need not execute; the authentic
token can remain live.

Synthetic actual-handler witness, not a ledger exploit.

## Required (executing layer)

Bind the custody-held and burned asset's complete **(policy, name,
quantity)** identity to the spent registry state's configured
`representative_policy`, using `naming.mpfs_state_policy` or an equally
direct executing-layer check. Keep exact name and quantity-one /
burn-minus-one.

On the repaired source:

1. the same four actual handlers accept the authentic-policy completion;
2. the exact foreign-policy lookalike witness refuses **specifically at
   custody**;
3. deleting or weakening **only** the policy equality makes that
   witness accept;
4. the connected devnet Over journey still proves genuine custody
   spend, authentic burn, root update, permanent Over readback, and
   reuse refusal;
5. existing legitimate nonempty rejected, mixed, zero-net, and
   separate unspent-custody cases remain accepted.

Run only checks affected by this repair plus the final required E17
acceptance route. Do **not** widen the generic consumer. Do not
manufacture a second ledger authority.

After this repair, same seat: LX01/N2 control modes, then
`83b359f` re-integration, then mechanical ABI tuple. Do not release
the tuple to E18.

Terminal: `PROOF-COMPLETE`, `BLOCKED` with a Q-file, or `COMPLETE`
with a mechanical remainder that still names those items if unfinished.
