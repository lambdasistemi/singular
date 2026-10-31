# Plan: the booking reads the key before it builds

Issue 486. Follows [the specification](spec.md).

## Approach

The open datum insert command already acquires a view of the chain before it builds the booking. Inside that step, before the
booking is built, it reads the key's state through the reader that `inspect --key` uses, and turns an active or terminated answer
into a named client refusal. The refusal is raised in the build step, which both signing modes share, so a signed submission and a
staged bundle are refused alike and nothing is recorded. An unknown key, an unavailable state and an unrecognised state policy
all fall through to the booking as it is built today.

## Slice

One slice and one pull request: the refusal and its wording, the read in the booking step, the tests, the journey and refusal
scripts, the conformance row and the pages.

| Part | Change |
| --- | --- |
| Command layer | the booking step of the open datum registration reads the key and refuses; the refusal type gains the two named cases and their wording |
| Tests | the command-level examples that book an occupied key move to the refusal; a new example per answer of the reader; the occupied-key fold example keeps its fold-side assertion by booking before the registration |
| Journeys | the registration journey's re-registration leg asserts the refusal at the booking; the registration, batch, hand-built and termination refusal scripts that booked a key already registered book it before the registration instead, so the fold's refusals stay shown |
| Conformance and pages | a new comparison row beside the retained one, the generated evidence page, the command and node pages and their narration |

## Consumers the gate names at intake

The open datum command and request tests, the help snapshot of insert, the parser corpora, the registration journey, the
registration, batch, termination and hand-built refusal scripts, the batch measurement, the recovery partitions (an insert now
makes one more read), the installed journey and the release verification that replay the registration journey, and the
conformance job with its frozen row lists.

## Model position

Below: a client policy ahead of a booking the application decides to admit; the transition table is unchanged.
