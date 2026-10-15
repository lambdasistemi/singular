# Closed datum: tasks

The story, requirements and rulings are in the specification and the ruling page;
decisions and hosted checks are in the plan; the files this work may change are in
the touch list.

## Slice: the closed-datum entry point

- [ ] closed-validator-appended: the closed-datum validator follows the last line
  of `open_datum.ak`, with no other change to the file.
- [ ] closed-spend-refuses-every-update: the suite shows the closed spend refusing
  an update of every payload in its list, in contexts open-datum accepts.
- [ ] closed-refusal-is-the-closed-rule: each such refusal is paired, in the same
  test file, with open-datum's acceptance of the same context.
- [ ] closed-release-follows-open-release: a release in the registry's
  terminating fold is accepted, together with the registry's own validator, and a
  release outside it is refused.
- [ ] closed-booking-follows-open-booking: insertion and termination bookings are
  accepted, and a refused booking is refused with the same verdict as open-datum's.
- [ ] closed-else-refuses: another script purpose is refused.
- [ ] closed-refusal-test-can-fail: the composed-suite check names a closed
  refusal test in its log and refuses a planted copy whose closed `Update` arm
  accepts.
- [ ] closed-identity-pinned-from-the-build: the manifest gains the three closed
  rows from the real blueprint, and the three open-datum rows are unedited.
- [ ] seventeen-validators-in-the-release: the merged blueprint check and the
  release assembler count seventeen.
- [ ] declared-additions-recorded: the record names exactly the three closed
  titles.
- [ ] comparison-admits-only-what-is-declared: the comparison admits the declared
  titles, refuses an undeclared extra validator and a moved declared hash, and
  keeps every base hash byte-identical; both plants run on every invocation.
- [ ] boundary-contexts-unchanged: the permanent boundary still receives four
  application contexts.
- [ ] pages-and-speech-stamped: the pages of this folder carry current speech.
- [ ] local-legs-green: the cheap local commands in the plan pass on the final
  head.
- [ ] hosted-jobs-green: every job in the plan's table is green on the pushed
  head, and the acceptance walk records each job's run.
