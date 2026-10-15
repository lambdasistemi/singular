# Closed datum: tasks

The story, requirements and rulings are in the specification and the ruling page;
decisions and hosted checks are in the plan; the files this work may change are in
the touch list.

## Slice: the closed-datum entry point

- [x] closed-validator-appended: the closed-datum validator follows the last line
  of `open_datum.ak`, with no other change to the file.
- [x] closed-spend-refuses-every-update: the suite shows the closed spend refusing
  an update of every payload in its list, in contexts open-datum accepts.
- [x] closed-refusal-is-the-closed-rule: each such refusal is paired, in the same
  test file, with open-datum's acceptance of the same context.
- [x] closed-release-follows-open-release: a release in the registry's
  terminating fold is accepted, together with the registry's own validator, and a
  release outside it is refused.
- [x] closed-booking-follows-open-booking: insertion and termination bookings are
  accepted, and a refused booking is refused with the same verdict as open-datum's.
- [x] closed-else-refuses: another script purpose is refused.
- [x] closed-refusal-test-can-fail: the composed-suite check names a closed
  refusal test in its log and refuses a planted copy whose closed `Update` arm
  accepts.
- [x] closed-identity-pinned-from-the-build: the manifest gains the three closed
  rows from the real blueprint, and the three open-datum rows are unedited.
- [x] seventeen-validators-in-the-release: the merged blueprint check and the
  release assembler count seventeen.
- [x] declared-additions-recorded: the record names exactly the three closed
  titles.
- [x] comparison-admits-only-what-is-declared: the comparison admits the declared
  titles, refuses an undeclared extra validator and a moved declared hash, and
  keeps every base hash byte-identical; both plants run on every invocation.
- [x] boundary-contexts-unchanged: the permanent boundary still receives four
  application contexts.
- [x] pages-and-speech-stamped: the pages of this folder carry current speech.
- [x] local-legs-green: the cheap local commands in the plan pass on the final
  head.
