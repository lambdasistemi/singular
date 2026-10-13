# A write asks the wallet for what it costs

Every write command refuses a wallet that holds under 100 ada, whatever the
operation costs, and reports the refusal as a node failure. This page records the
cause, what changes and how it is proved. Issue 526.

## Story

As Alice with 20 ada in two outputs, I run `registry insert --preview` and see a
total of 6 198 411 lovelace within my `--max-outlay` of 8 000 000. I then run the
same `registry insert` with my key and it goes through, because my wallet covers
what the operation costs. When a wallet does not cover it, the command refuses
before signing anything with the outcome `client-refusal`, names the wallet, what
it holds, what the operation needs and the shortfall, and the preview of the same
wallet refuses with the same figures.

## What is established

Observed on preprod on 8 October 2026 (main e48e3098) and read again on main
af16bad4:

- `withWritesObserved` in `offchain/koios-http/src/Singular/Registry/Terminal.hs`
  calls `checkFunding` with `defaultFundingFloor` (100 ada held, 5 ada of it in
  one ada-only output) after the provider is reached and before any command body
  runs. The floor is fixed; the operation is not measured.
- The call runs while the command session is still opening, so `withSession` in
  `offchain/cli/src/Singular/CLI/Session.hs` sees an exception before its body
  started and reports it `node-unavailable`, "the provider … could not be used".
  The provider had answered.
- The preview never opens a write session, so it never meets the floor. It builds
  the real booking from the wallet's own outputs and states its outlay.

## Requirements

- `no-fixed-floor-before-the-operation-is-known`: opening a write session reads
  the provider and applies no wallet threshold. No lovelace amount fixed in
  source decides whether a command may start.
- `booking-wallet-judged-on-the-measured-outlay`: `insert` and `terminate` (and
  their previews) judge the wallet where they judge `--max-outlay`: after the
  booking is built and before it is signed, the wallet must hold at least the
  measured outlay (the booking's fee, the lovelace its request locks and the bound
  on the fold that follows). A booking is the one write whose cost includes a
  reserve for a later transaction, which a successful build does not prove.
- `wallet-below-the-fold-reserve-refused-before-building`: before the booking is
  built, a wallet holding less than the bound on the fold that follows it (known
  from the network's parameters and the reference scripts the fold reads) is refused: nothing can cover a booking
  that cannot cover that.
- `empty-wallet-refused-before-building`: for `insert`, `terminate` and `update`,
  a wallet with no ada-only output to fund from, or with the output named by
  `--fund-input` not among its ada-only outputs, is refused before the
  transaction is built.
- `shortfall-is-a-client-refusal-that-names-the-wallet`: the refusal is outcome
  `client-refusal` (exit 10), its reason states "(client policy)", and its fields
  carry the wallet address, `held`, `required` and `shortfall` in lovelace, the
  UTxO count held and `policy: client`. It is never `node-unavailable`.
- `preview-and-write-judge-the-same-wallet`: preview and write call the same
  judgements at the same points, on the outputs of the same address and the body
  their one builder returns, so for one wallet and one registry they accept
  together or refuse with the same figures.
- `wallet-policy-stays-labelled-client-policy`: the Lean model has no wallet
  threshold. The judgement is the client's, says so in its reason and receipt, and
  changes no transition, token, deposit, refund or on-chain check.
- `conformance-harness-floor-unchanged`: the conformance runner keeps its own
  fixed floor for its own scenarios (`Conformance.Run`, `CsRows`, `ForkProbe`).
  Nothing under `conformance/` changes.

## Stated limits

- `update`, `reject`, `reclaim`, the standalone `registry fold` and `registry
  create` are no longer refused by the floor. Each already builds from the wallet's
  funding output, and a build that succeeds proves the wallet pays the fee. A
  wallet too small for that build is still reported in the builder's own words, not
  in the named wallet fields above (`update` is covered only for the empty wallet).
  Naming it there needs a typed shortfall from the transaction builders in files
  that other open lanes are changing (`TxBuilder/Edges.hs` under #406, the fold
  under #518 pull request 3). That is a follow-up owned by the milestone owner, not
  a claim made here.
- The judgement is necessary, not sufficient: it counts the wallet's total. The
  booking's single funding output is proved by the builder succeeding; the fold's
  own funding and collateral are proved when the fold is built, as today. A wallet
  of many small outputs can pass the total and still fail the builder.
- No transaction is submitted on a live network by this work. The preprod
  reproduction is the issue's; this change is proved by hosted tests over the
  in-memory chain and the scripted provider.
