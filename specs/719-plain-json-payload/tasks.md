# Payload written as plain JSON: tasks

The story and the mapping are in the [spec](spec.md); slices and the gate are in the
[plan](plan.md). One writer, one commit per slice, each commit builds. Every new check is run
failing before it is made to pass and the failing run is kept.

## Slice: plain mapping

- [x] plain-mapping-red: the examples of the spec table, the refusals with their paths, the
  round-trip property over generated JSON, the huge-exponent number and the data without a plain
  reading all fail on the base because the module does not exist.
- [x] plain-mapping-module: `Singular.Registry.PlainJson` with the mapping, the reading, the
  refusals, the schema type and the view.

## Slice: payload schema on the commands

- [x] payload-schema-red: parsing the flag, the default, a bad value, the detailed-document
  refusal, equal data for the same file through insert, update, previews and register, and the
  detailed schema unchanged all fail on the base.
- [x] payload-schema-flag: the entry argument, the flag declaration, help, help snapshots, parser
  corpora, the application settings spec, the flag table.
- [x] one-payload-reader: `Singular.CLI.Payload` and its use in the open-datum commands, previews,
  keri-stub register and the negative host.
- [x] callers-name-the-schema: every shell, python and Haskell caller in the repository that
  writes a payload file in the detailed schema passes the setting.

## Slice: printed payload

- [x] printed-payload-red: inspect and the update receipt print `payload` with `payloadSchema` in
  both forms; fails on the base.
- [x] printed-payload-view: the shared inspect code and the update receipt print the view;
  `dhPayloadJson` removed when unread.
- [x] readers-follow-the-print: every reader of `applicationOutput.payload` and of the update
  receipt's `payload` in scripts, the conformance backend and controls, and tests is moved.

## Slice: hosted evidence

- [x] journey-stores-plain-and-detailed: the Demo 1 journey stores `{"answer": 42}` with no
  setting, reads it back equal with schema `plain`, updates it, and stores a detailed document
  with the setting; the same job refuses a detailed file without the setting and a plain file
  with the setting `detailed`.
- [x] journey-controls-fail-on-the-previous-release: the new steps are shown refusing against the
  0.14.0 binary, where a plain file is not Plutus data.

## Slice: documentation

- [x] payload-page: the page with the table, the worked examples, the refusals, the schema
  setting and what inspect prints; added to the navigation.
- [x] pages-show-the-setting: the flag row in `docs/singular-node.md`, and the pages that show a
  payload file.
- [x] speech-and-narration: companions stamped, narration clips regenerated.
- [x] singular-demo-route: the handoff for the desk.
