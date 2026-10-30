# Plan: the application description names its configuration

Issue 799. Follows [the specification](spec.md).

## Approach

The fold library asks the application description, never an application by name. The description gains one pure question
about an output: is this your configuration. Discovery asks it after the key-address check and before the request decoding;
an output the description names as configuration is in neither the pending list nor the skipped list. The open datum
description answers it with the same configuration decoding the booking reader already uses, so the two cannot disagree
about what a configuration output is.

## Slice

One bisect-safe slice, one pull request, because the new field must be set wherever the description is built.

| Part | Change |
| --- | --- |
| Library | the description gains the question; discovery consults it; the module's reasons stay as they are |
| Open datum | the description answers it from the request address and the configuration decoding |
| Tests | the fold specification (stand-in applications), the open datum application specification (real creation output, real requests, lookalikes), the world fixture that builds a description |
| Checks | the observation judge for the configuration holder expects its absence from `skipped`; the refusal journey's independent census compares `skipped` with the holders that are not configuration |
| Pages | the pages that list what discovery skips say what a skip means now |

## Consumers of fold discovery that the gate names at intake

The conformance unit suite, the journey steps that fold late, the printed refusals of the open datum package, the
refusal and observation scripts under `tools/` for batch and termination refusals, the retained receipts that record
`skipped`, and every page that describes the skip list.

## Model position

Below: no change to what is folded, to any transition or to any on-chain script or hash. No wire format changes.
