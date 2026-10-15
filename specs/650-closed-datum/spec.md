# Closed datum: the open-datum application with every update refused

The release archive carries one application, open-datum, in which the controller
of a name can update the name's payload. This ticket adds a second on-chain entry
point to that same application, in which the payload is written once at
registration and every update is refused on chain. It is the on-chain half of
issue 650; the executable's `--closed` choice at create is the next ticket.
Issue 651.

## Story

As the presenter of Demo 1, I need the release archive to carry a closed-datum
application. It is the same open-datum code from the same release, except that a
name's payload is written once at registration and every update is refused on
chain. Registration and termination, with the deposit back, behave as in
open-datum. When a person with the archive reads its blueprint, they find the
closed-datum validator beside the open-datum one, with its own pinned identity,
and open-datum's identity is exactly the one every earlier rehearsal ran.

Nothing is runnable by a person yet. The executable gains the choice in the next
ticket of issue 650, and a real node refuses a crafted update in the ticket after
it. This ticket proves the validator in the Aiken suite and pins it in the
release.

## What is established

Read on main at cfe78df1 and measured on 15 October 2026 in a scratch copy of the
tree that was never pushed.

- The open-datum validator is `validator open_datum(registry)` in
  `applications/open-datum/onchain/validators/open_datum.ak`. Its spend handler
  has two paths: an update, which keeps the key's token at the same address with
  the same control and lets the payload change, and a release, which is allowed
  only inside the registry's fold that terminates the key and burns its token.
- Aiken refuses a validator module that imports another validator module, unless
  the importing module is a test module. A second file `closed_datum.ak` that
  calls the open-datum handlers fails the production build with
  `aiken::check::illegal::import`: "I discovered an attempt to import a validator
  module in a library: 'open_datum'". Its help text says to move shared code into
  a library module, or to import a validator only for testing.
- A second validator block placed in the same module builds, and calls the first
  validator's handlers by name. Built that way, the blueprint holds
  `open_datum.open_datum.{mint,spend,else}` with hash
  `cdc67586fd5391249e862338e88120ec5921d3fc9f4cd84b8cce7c33`, equal to the
  committed identity rows, and `open_datum.closed_datum.{mint,spend,else}` with a
  hash of its own. Aiken compiles each validator from the code it reaches, so a
  sibling validator does not enter open-datum's program; the equal hash is the
  control for that statement.
- A test module that imports a validator may not export `pub` definitions, so
  the existing fixtures of `open_datum.tests.ak`, all private, cannot be imported
  by a second test file.

## Requirements

- `closed-spend-refuses-every-update`: the closed-datum spend handler refuses the
  `Update` redeemer, with the trace label `closed-datum-update`, for every payload
  the suite already quantifies over, in a context that open-datum accepts. No
  context, signer or output shape turns an update into an acceptance.
- `closed-refusal-is-the-closed-rule`: every context that closed-datum refuses as
  an update is accepted by open-datum's spend in the same test file, so the refusal
  is the closed rule and not a broken fixture.
- `closed-release-follows-open-release`: the closed-datum spend handler passes
  `Release` to open-datum's spend handler. A release inside the registry's
  terminating fold, with the controller paid, is accepted, and the same
  transaction is accepted by the registry's state validator. A release outside
  that fold is refused, as open-datum refuses it.
- `closed-booking-follows-open-booking`: the closed-datum mint handler is
  open-datum's mint handler. Booking an insertion and booking a termination are
  accepted, and a booking that open-datum refuses is refused with the same
  verdict.
- `closed-else-refuses`: the closed-datum handler for any other script purpose
  fails, as open-datum's does.
- `closed-refusal-test-can-fail`: the application's Aiken check proves that the
  closed rows ran and can fail. Its log names a closed refusal test, and a planted
  copy of `open_datum.ak` whose closed spend accepts `Update` makes the suite
  fail, naming that test. The plant confirms it applied before the suite runs.
- `open-datum-identity-unmoved`: the open-datum rows of
  `applications/open-datum/onchain/script-identity.json` are byte-identical to
  main, and the identity job passes. The edit to `open_datum.ak` is an append of
  the new validator after its last line: no line of the file changes and no import
  changes.
- `closed-identity-pinned-from-the-build`: the manifest gains the three closed
  rows, generated from the real blueprint and never typed; the identity job
  compares both directions.
- `seventeen-validators-in-the-release`: wherever the merged validator count is
  asserted, 14 becomes 17: the merged deployment blueprint in the application's
  flake and the release assembler.
- `base-hash-comparison-admits-only-what-is-declared`: the split-blueprint
  comparison keeps every base hash byte-identical, admits exactly the three
  declared closed-datum validators, and refuses any other extra validator and any
  declared validator whose hash differs from the manifest. Each refusal is shown
  by a plant that runs on every invocation.
- `registry-untouched`: no change to the registry contract, its script hashes, the
  registry library or the `singular` commands.
- `no-lean-statement`: the write-once rule has no Lean statement, by operator
  ruling (see the ruling page). It is not in the conformance suite or the theorem
  register, and nothing here claims otherwise.

## Why a second validator inside open_datum.ak

Three ways to make closed-datum "a flag over open-datum" were weighed.

| Choice | Open-datum hash | Registry library | Verdict |
|---|---|---|---|
| A parameter on `open_datum` | moves, because any new parameter recompiles it | must apply a second parameter; `applyPin` applies exactly one | refused |
| A second file that imports and calls open-datum's handlers | not applicable | none | does not build (Aiken import rule above) |
| A second validator in the same module that calls open-datum's handlers | measured unmoved | none, the code is found by blueprint title | chosen |
| Move the open-datum logic into a plain module, both validators thin | unmeasured; moving code between modules can change the compiled program | none | not chosen: a six hundred line move for no gain |

The chosen shape keeps three things. Open-datum's compiled hash and identity rows
do not move, so every open-datum test, record and hosted job passes untouched.
The registry library is not changed, because it loads application code by
blueprint title and applies the one registry parameter, so the title
`open_datum.closed_datum` works through the same path. And the difference between
the two applications is the one place the spend handler names `Update`.

## Stated limits

- The write-once rule has no Lean statement. Lean remains the authority for every
  rule the closed-datum application shares with open-datum, which it reaches by
  calling open-datum's handlers.
- This ticket evaluates the closed-datum validator in the Aiken suite only. The
  permanent compiled-code boundary keeps its four open-datum application
  contexts; running the compiled closed-datum code over a ledger is the later
  negative-host ticket of issue 650.
- The executable's `--closed` choice, the client's refusal of an update before it
  signs, the devnet journey from the release archive and the negative-host part
  are the later tickets of issue 650.
- Nothing runs on preprod.
