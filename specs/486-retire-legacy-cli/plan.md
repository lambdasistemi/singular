# Plan for retiring the legacy command layer

Issue 486, remainder. This page is for the commit owner, the auditor and the reviewers. The requirements are in
[the specification](spec.md); the census and the verbatim commands are in [the gate](gate.md).

## Class of change

The change keeps behaviour: it deletes code that has no command line route, and it is shown by the unchanged help
snapshots and unchanged parser corpora outside the removed switch. Hosted checks are the gate, one writer, one review of the
deletion list before the push.

## Slice

One slice, one pull request, in this order inside it:

1. Delete the roots: the fold value of the singular program and the code that runs it; the three booking values of the
   open-datum program, their arms in the runner and in the needed-references function; the argument records, the entry mode
   and the create record that only those values used; the fold switch from the shared switch list and from the tokenizer
   test that pins it.
2. Follow the compiler. Trim the export lists of the edited modules, build with the unused-binding warning on, and delete
   every top-level binding that only the deleted code or its tests used; repeat until the warning is silent. Typical
   targets are the booking, update and fold outlay helpers and the helper functions of the plan module that no command
   calls.
3. Delete the tests, corpus rows, help snapshot entries and harness legs whose subject was deleted. Re-record only the
   corpus rows that carried the removed switch; a row outside that set that changes is a defect.
4. Before deleting any test, list the production behaviour it exercised. When the same behaviour has no other test, port
   the test to the production command. The list goes in the pull request.
5. Update the code inventory, the declared checks census and the documentation that named a deleted file or value; restamp
   the speech companion of every edited page.

## Consumers to check

A change to a command flag or value touches the declared flag list, the help snapshots, the parser corpora, the application
settings specification and the documented-flags check. Removed modules or flake checks need their workflow step and the
declared-checks census row in the same commit. Edited pages need their speech companion restamped, and the documentation
check passes under the runner's bare path.

## Auditor question

One mute review of the census and the deletion list, asking only: does any deletion remove the only evidence for a
behaviour a production command still has?
