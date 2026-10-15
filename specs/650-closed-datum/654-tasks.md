# Closed mode: tasks

The story, requirements and rulings are in the closed mode specification;
decisions, shape and hosted checks are in the plan; the files this work may change
are in the touch list.

## Slice: the closed mode of the open-datum executable

- [ ] mode-and-closed-value-defined: `Value.hs` defines the mode, its titles and
  the application value for a mode; the open constant keeps its name and every
  field, and the closed value differs in the pin title alone.
- [ ] closed-switch-at-create-only: `--closed` parses at create (also with
  `--preview`), is refused by name on every other command, is not mistaken for a
  key's text, and the usage text names it on the create lines only.
- [ ] closed-create-pins-closed-datum: create loads the closed code and names the
  application `open_datum.closed_datum` with the switch, and the open one without.
- [ ] mode-read-from-the-chain: a state recording the closed derivation reads as
  closed and one recording the open derivation reads as open, each datum built from
  the boot-side functions.
- [ ] unreadable-or-unrecognised-mode-is-not-guessed: a recorded policy that is
  neither derivation and a missing state are refused by the mode read; run
  through the dispatch, each ends in the command's own named refusal with its
  text unchanged, builds and signs nothing first, and never asks the loader for
  the closed code after the mode read.
- [ ] later-commands-follow-the-registry: insert, terminate, fold and inspect load
  the code of the registry's mode, shown by a loader that records its requests.
- [ ] loader-decides-the-code: a closed registry resolves through the open-titled
  value.
- [ ] update-on-a-closed-registry-stops-before-building: update and its preview on
  a closed registry name the closed registry, exit 10, and read no key.
- [ ] open-registries-behave-as-today: the existing open-datum suites pass with
  only the constructor arity changed.
- [ ] help-and-pages-carry-the-switch: the help, the settings table and the run
  page say what the switch does; the documented-flags check passes.
- [ ] pages-and-speech-stamped: every changed page carries current speech, and
  the site page its clips.
- [ ] local-legs-green: the cheap local commands in the plan pass on the final
  head.
- [ ] hosted-jobs-green: every job in the plan's table is green on the pushed
  head, and the acceptance walk records each job's run.
