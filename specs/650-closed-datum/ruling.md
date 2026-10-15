# Closed datum: the rulings in force

The constitution requires a ruling that settles a story to be recorded in the
repository with the story it affects. This page records the rulings that bound
issue 651, in the words they were given, and says what each one changes and what
it leaves alone.

## No Lean statement for the write-once rule

On 15 October 2026 the operator ruled: "We do not need lean here. This is just
for demo one, and then we decide if to formalize it."

The affected story is the Demo 1 presenter's closed-datum registration: the
payload is written once and every update is refused on chain. The ruling declares
a limit. The write-once rule has no Lean statement, no theorem, no corpus row and
no simulator case. The conformance suite and the theorem register do not mention
it, and no document in this change claims that Lean governs it.

What the ruling does not do. It does not change any Lean statement about the
registry or about open-datum. It does not permit a closed-datum rule that
contradicts clear Lean: the closed-datum validator reaches every other rule by
calling open-datum's handlers, so those rules stay as they are. Whether to
formalize the write-once rule is a later decision of the operator, taken after
Demo 1.

## One application, one flag

On 15 October 2026 the operator ruled: "Make sure you refactor the open datum
application enough so that closed datum is just a flag over it."

The affected story is the same. The ruling decides that closed-datum is not a
second implementation of the application: it shares open-datum's code and
differs from it only by the refusal of an update. The shape that satisfies it is
the one the specification explains: a second validator in the same module as
open-datum, which calls open-datum's mint and spend handlers and refuses only the
`Update` redeemer.

## Open-datum's identity does not move

On 15 October 2026 the milestone ruling for issue 650 chose a second entry point
that delegates to open-datum's handlers over a parameter on the open-datum
validator. A parameter recompiles open-datum and moves its compiled hash, and the
registry library applies exactly one parameter. The purpose of the ruling is that
open-datum's compiled program, its hash and its three identity rows do not move,
so that the open-datum scenes of Demo 1 run the application that every earlier
rehearsal ran.

## The entry point sits inside open_datum.ak

On 15 October 2026, after the measurement in the specification showed that a
validator in its own file cannot import another validator in a production build,
the ruling for issue 650 chose the second validator inside `open_datum.ak` as a
pure append. The titles are `open_datum.closed_datum.{mint,spend,else}`. The
closed-datum tests join the existing `open_datum.tests.ak`, beside the
open-datum rows they mirror. The registry, the registry library, the `singular`
commands and the open-datum executable are not changed by this ticket.

## What these rulings leave open

The executable's `--closed` choice at create, the client's refusal of an update
before signing, the devnet journey from the release archive and the node-level
refusal are later tickets of issue 650. Scene 5 on preprod needs a registry
created with `--closed`, which is a separate decision of the operator.
