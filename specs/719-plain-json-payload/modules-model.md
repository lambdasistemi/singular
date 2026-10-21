# Payload written as plain JSON: modules

Responsibilities and the direction of dependencies. Fields are in the
[data model](data-model.md), signatures in the [functions model](functions-model.md).

## New and changed modules

| module | package | responsibility | depends on |
|---|---|---|---|
| `Singular.Registry.PlainJson` (new) | `offchain/lib` | the plain mapping in both directions; the digit limit; the refusal with its path; the detailed-document refusal; the payload schema type; the view that chooses what is printed | `Singular.Registry.Application` for the detailed schema (`datumFromJson`, `datumToJson`) |
| `Singular.CLI.Payload` (new) | `offchain/cli` | the one place that reads a payload file for a command: reads the JSON, applies the schema, refuses with `ClientRefusal` before any node is read | `PlainJson`, the command line's file reader and failure type |
| `Singular.CLI.Command` | `offchain/cli` | the entry arguments gain the payload schema | `PlainJson` for the type |
| `Singular.CLI.Declared` | `offchain/cli` | declares the payload schema flag once | |
| `Singular.CLI.Inspect` | `offchain/cli` | prints `payload` and `payloadSchema` from the holding's payload data | `PlainJson` |
| open-datum `Command`, `Help` | `applications/open-datum` | takes the flag on insert and update; help | `Declared`, `Command` |
| open-datum `Plan`, `Preview`, `Entry` | `applications/open-datum` | read the payload file through `Singular.CLI.Payload`; the update receipt prints the view | `Singular.CLI.Payload`, `PlainJson` |
| keri-stub `Command`, `Register`, `Value` | `applications/keri-stub` | register takes the flag and reads through `Singular.CLI.Payload`; the holding view no longer carries a payload JSON of its own | `Singular.CLI.Payload` |
| `Negative.Run` | `applications/open-datum/negative` | insert and update read the payload file through `Singular.CLI.Payload` | `Singular.CLI.Payload` |

## Direction

`PlainJson` is pure and knows nothing of commands. `Singular.CLI.Payload` is the only module that
reads a payload file. Applications call it; none calls `datumFromJson` or the open-datum
`dataFromJson` on a payload file. The open-datum `dataFromJson` stays for decoding envelopes.

## Promotion

The mapping serves every application that stores data, so it lives in the shared library, beside
the detailed schema it complements, rather than in the open-datum package. `dhPayloadJson` of the
decoded holding is removed when the print moves to `Singular.CLI.Inspect`, because nothing else
reads it; each application keeps providing the payload data (`dhPayload`).
