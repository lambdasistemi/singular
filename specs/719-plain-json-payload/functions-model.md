# Payload written as plain JSON: functions

New and changed signatures with argument names. Types are in the [data model](data-model.md),
homes in the [modules model](modules-model.md).

## `Singular.Registry.PlainJson`

| function | arguments | result | constraint |
|---|---|---|---|
| `plainToData` | `document`, the parsed JSON | the data, or a plain refusal | pure; total; terminates on any parsed JSON, including numbers with huge exponents |
| `plainFromData` | `payload`, the data | the JSON, or nothing when the data has no plain reading | pure; `plainToData` of the result is the payload |
| `payloadFromJson` | `schema`, `document` | the data, or the text of the refusal | for the detailed schema it is `datumFromJson` with its refusals unchanged; for the plain schema it refuses a detailed document first, then maps |
| `payloadView` | `payload` | the payload view | `plain` exactly when `plainFromData` returns the JSON |
| `renderPlainRefusal` | `refusal` | text | names the value and its path |
| `schemaName` | `schema` | text | `plain` or `detailed`; the inverse of the flag value |
| `parseSchemaName` | `name` | the schema, or nothing | accepts exactly the two names |

## `Singular.CLI.Payload`

| function | arguments | result | constraint |
|---|---|---|---|
| `readPayloadFile` | `schema`, `path` | the data | reads the file as JSON; any failure is a client refusal naming `path` and `--payload`, raised before the node is read |

## Changed signatures

| function | change |
|---|---|
| the entry arguments record | gains `entryPayloadSchema` |
| the open-datum parser's entry arguments | reads the flag; the default is `plain` |
| the keri-stub parser's register arguments | same |
| `runInspect` output | `payload` and `payloadSchema` come from `payloadView` of the holding's payload data |
| the update receipt | `payload` and `payloadSchema` come from `payloadView` |

## Removed

`readInsertPayload`'s own file reading, the update's own file reading, the preview's own
`document` call for a payload, keri-stub's `readPayload` file reading and the negative host's
direct `dataFromJson` call, each replaced by `readPayloadFile`; the `dhPayloadJson` field when no
reader remains.
