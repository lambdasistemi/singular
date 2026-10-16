# Closed-datum journey: tasks

The story, requirements and rulings are in the specification; decisions, order and
hosted checks are in the plan and the gate; the files this work may change are in the
touch list.

## Slice: the closed-datum journey from the release archive

- [x] verifier-takes-the-journey: the flake's verifier wrapper is parameterised by
  its journey file; the open instance is the open journey, as today.
- [x] closed-check-app-declared: the app `demo1-closed-check` assembles the release
  and verifies it with the closed wrapper.
- [x] helpers-reused-by-name-and-guarded: the closed journey reads the helper
  functions out of the open journey and stops before any node starts when one is
  missing.
- [x] closed-registry-created-with-the-switch: create with the closed switch
  succeeds and names the application `open_datum.closed_datum`.
- [x] closed-mode-is-read-from-the-chain: the page's recorded application hash equals
  the closed hash and the create receipt's, and differs from the open hash.
- [x] registered-name-reads-back-with-its-payload: insert, another wallet's fold and
  inspect read the name active with its payload and deposit.
- [x] update-is-refused-before-anything-is-signed: the update ends in the client
  refusal that names the registry as closed.
- [x] refused-update-submits-no-transaction: the two chain reads are equal across
  the refused update.
- [x] no-transaction-reads-can-see-a-submission: the wallet read differs across the
  termination booking.
- [x] termination-returns-the-deposit: after the fold, inspect reads the name
  terminal and the controller's wallet lists the fold's output of at least the
  deposit.
- [x] every-step-leaves-a-receipt: the journey ends by listing each step's receipt and
  outcome.
- [x] new-job-runs-the-journey-on-every-change: the job "Closed-datum journey from
  the release archive" runs the app beside its sibling.
- [x] open-datum-job-unchanged: the open job, app, journey and verifier script are
  byte-identical to main apart from the wrapper parameter.
- [x] declared-checks-stay-hosted: the two census jobs pass with the new app.
- [x] docs-note-names-the-job: the run page names the job; its speech is regenerated.
- [x] pages-and-speech-stamped: every page of this folder carries current speech.
- [x] local-legs-green: the cheap local commands in the plan pass on the final head,
  and the journey ran once locally on it.
