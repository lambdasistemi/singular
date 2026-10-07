# Protocol narration: tasks

Read the [plan](plan.md) for the module rows. One commit per task, in order.

## Slice: narration

As someone watching a command, I want its protocol steps on stderr as they
happen, from one typed event stream.

- [ ] Narration tests: typed events collected from each of the eight commands
  compared with the receipt (key, edge, request, transaction id, verdict);
  the text renderer as a pure function, indentation included; the receipt on
  stdout unchanged under every tracing flag; the flags refused on unknown
  values. Committed failing.
- [ ] Typed tracer replaces the phase log: provider-level events, a tracer
  argument wherever `phaseLogFromEnv` is read today, the phase-log module
  deleted, and `SINGULAR_LOG` produced byte-compatibly by a renderer at the
  entry point. Existing phase-log tests and Demo 1 assertions unchanged.
- [ ] Protocol events: registry, request, edge and transaction events from
  all eight commands, with the four refusal kinds distinct.
- [ ] Tracing controls and renderers: `--trace`, `--trace-to stderr` and
  `file:PATH`, `--trace-format`, their defaults, the indented text renderer
  and the json renderer.
- [ ] Demo and documentation: the Demo 1 journey runs with
  `--trace how --trace-to stderr`; `docs/singular-node.md` documents the
  flags and the stream, with speech and narration updated.

## Slice: socket sink

As a machine consumer, I want the same events on a Unix socket.

- [ ] Socket sink: a `contra-tracer-contrib` pull request adding the sink,
  the pin bump here, `--trace-to socket:PATH`, and a test that reads the
  socket and asserts the typed events it decodes.
