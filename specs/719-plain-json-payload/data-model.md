# Payload written as plain JSON: data

Fields, relationships and validation. The table of the mapping itself is in the
[spec](spec.md); where each type lives is in the [modules model](modules-model.md).

## Types

| name | fields or constructors | invariant |
|---|---|---|
| payload schema | `plain`, `detailed` | the entry arguments carry one; `plain` when the flag is absent; the flag's text is the lower-case name |
| plain refusal | the path of the offending value; the reason | the path is `$` for the document, then `.key` and `[index]`; the reason is one of: a number with a fraction (carrying the number), a number past the digit limit (carrying the number), `null` |
| payload view | the schema printed; the JSON printed | `plain` only when the JSON maps back to the same data; otherwise `detailed` and the JSON is the detailed schema of the data |

## Relationships

- A stored payload is a Plutus data value. The plain mapping is a partial function from JSON to
  data; the plain reading is a partial function from data to JSON.
- Reading after mapping is the identity on accepted JSON, compared as JSON values (numbers by
  value, objects without order). Mapping after reading is the identity on data that has a plain
  reading. Together the image of the mapping and the domain of the reading are the same set.
- The entry arguments carry the schema beside the payload file's path. A command with no payload
  file ignores it.

## Validation

- A number is accepted when its value is a whole number with at most 1000 digits. A number with a
  large exponent is judged by its size before it is expanded.
- A text is accepted whatever it holds; it is stored as its UTF-8.
- An object's keys are sorted by their UTF-8 bytes before the entries are listed.
- With the plain schema a whole document that the detailed schema accepts is refused before the
  mapping runs.

## State

None. No file, journal entry or on-chain value gains a field.
