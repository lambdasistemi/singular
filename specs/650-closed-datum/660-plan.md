# Closed-datum journey from the release archive: plan

The story, requirements and rulings are in the specification. This page records the
decisions, the order of work, the invariants and the hosted checks that accept the
work. Issue 660, one pull request, one slice, about three hours of writing. Base:
main f23370a7 (with issue 651). The executable half, issue 654 (pull request 657),
merged as 38c2e436 before this pull request was pushed, and the branch was rebased
once onto it.

## Class and team

The change keeps product behaviour: a journey script, a nix app, a workflow job and
a documentation note. It is a new hosted obligation, because it asserts a property
of the product that the presenter relies on, so the epic owner's roster applies:
one independent gate author (who writes the table of hosted checks before any
coding, combined once by the author of this plan), one writer, and a persistent
auditor who answers the checkpoints and is silent toward the writer. The auditor is
an alarm: a block names a concrete failure scenario. No part of the change is
Haskell, Aiken or Lean.

## Decisions

- **The journey reuses the release verifier's seam and edits nothing in it.** The
  verifier `tools/verify_release.sh` takes its journey from an environment variable
  and already does everything around it: the sums, the model revision, the members,
  building `singular`, `open-datum` and the development node from the extracted
  archive, the release-build exclusion check, the wrapped executables and the check
  that only ordinary invocations ran. The flake gives the wrapper that sets the
  variable one parameter, the journey file, and instantiates it twice: the open
  wrapper with the open journey, as today, and a closed wrapper with the closed
  journey. Rejected: copying the verifier (a second oracle for the same release
  checks), editing the script to take a second journey (the published-release
  verification shares it), and copying the 2681-line open journey (two scripts to
  keep equal).
- **Helpers are read out of the open journey by name; only top-level blocks are
  copied.** The open journey is a script that runs when it is loaded, so it cannot be
  sourced, but its helper functions are self-contained. The closed journey reads
  these from the open journey file at run time, by function name, as
  `demo1_cli_check.sh` already does for the archive-layout function: `exit_of`,
  `trace_disagreements`, `trace_agrees`, `run` (one process, its receipt class and
  exit status, its narration agreeing with its receipt), `journal_lines`, `refused`,
  `field`, `hexof` and `holds_envelope`. The script then checks that every name is
  defined, so a rename in the open journey stops the closed journey before any node
  starts, with the missing name. Copied, because they are top-level code, in a
  shorter form: the devnet start with two funded wallets, the stop of the node at
  exit, and the page read that runs the command the create receipt prints. The
  plan states this so the writer does not copy functions that can be read.
- **The closed journey is a sibling file next to the open one**, travelling through
  the same `managedScripts` directory, so it finds `managed_state.sh` and the open
  journey beside it.
- **The mode is proved by a comparison the chain decides.** Before creating, two
  previews of the same wallet and seed, one with `--closed` and one without, derive
  two application hashes that differ. After creating, the page read from the create
  receipt's printed command names the recorded application hash. It must equal the
  closed hash and the create receipt's own, and differ from the open hash. Rejected:
  an `inspect` field (not in issue 654's contract; a Haskell change), and deriving
  the applied hash in the script from the blueprint (re-implements the executable).
- **The no-transaction proof is two chain reads taken twice.** Through
  `open-datum inspect`: the outputs at the controller's wallet address (the
  outputs-at option) and the name's own output with its datum and value. They are
  taken before and after the refused update, and must be equal; the wallet read is
  taken again after the termination booking and must differ, which shows the reads
  can see a submission. A third read, of the outputs at the application address, was
  planned and is dropped: the executable's outputs-at option accepts only a payment
  key address and refuses a script address on every registry, and reading one would
  be a Haskell change. Rejected: the registry directory's
  journal (a local file the executable wrote) as the proof; it may be checked as an
  extra line, never as the evidence.
- **The deposit return is a chain read of the controller's wallet.** After the fold
  settles the termination, the outputs at the controller's address list an output
  created by the fold transaction with at least the deposit. The fold receipt's
  released output and deposit are compared with the booking receipt's and the
  insert's. The on-chain release rule requires the controller to be paid at least the
  deposit in that fold, so the read is the observable consequence.
- **One new job beside its sibling.** The job `demo1-closed-archive` is named
  "Closed-datum journey from the release archive". It waits for the blueprint job,
  runs on the `nixos` runner, reuses the runner's cache and checks out the pull
  request head exactly as the open job does. The concurrency group is the workflow's
  own and covers it. Its timeout is set from the first hosted run, no more than 60
  minutes.
- **A documentation note, not a new page.** One paragraph in the run page
  `onchain-release/DEMO1.md`, after the paragraph issue 654 adds, names the job and
  the app. The run page has no narration clips; its speech companion is regenerated by
  the extraction tool.
- **The new check-run name goes into the ruleset JSON, prepared and not applied.**
  The writer produces nothing for this; the ticket owner fetches the ruleset read-only,
  appends the check and journals the file at merge-ready.

## Order of work

One slice, in this order. Each step leaves the tree green for the jobs it can reach.

1. The flake: give the verifier wrapper its journey parameter, copy the closed
   journey into `managedScripts`, and declare the closed app.
2. The closed check script: assemble the release with the existing
   `release-artifacts` app, verify it with the closed wrapper.
3. The closed journey script, step by step as the specification lists them, with the
   helper guard first.
4. The workflow job and the documentation note with its speech.
5. The cheap local legs below, one local run of the journey on the final candidate,
   then the hand-over for review.

The pull request is a stacked patch series: one patch for the pages, one patch for
the change. No journey commits are pushed.

## Invariants and what makes them fail

| Invariant | Fails when | Proved by |
|---|---|---|
| `journey-runs-from-the-release-archive` | the journey ran another build, or an invocation carried a test input | the verifier's recorded-invocation checks, inside the hosted job |
| `closed-registry-created-with-the-switch` | create succeeds but names another application, or is refused | the journey's create step |
| `closed-mode-is-read-from-the-chain` | the page's recorded hash is the open hash, or differs from the create receipt | the journey's page comparison; red on any base without issue 654 at the first invocation |
| `registered-name-reads-back-with-its-payload` | the name is not active, or carries another payload or deposit | the journey's inspect step |
| `update-is-refused-before-anything-is-signed` | the update succeeds, or is refused with another class or text | the journey's refusal step; red if the registry were open |
| `refused-update-submits-no-transaction` | any read differs across the refused update | the journey's two chain reads |
| `no-transaction-reads-can-see-a-submission` | the reads are equal across the termination booking | the journey's control comparison |
| `termination-returns-the-deposit` | no output of the fold pays the controller at least the deposit | the journey's final chain read |
| `every-step-leaves-a-receipt` | a step has no receipt file or the summary omits it | the journey's closing listing, which reads the files |
| `open-datum-job-unchanged` | the open job, app, journey or verifier script differs from main | the diff of the pull request (touch list) and the open job staying green |
| `declared-checks-stay-hosted` | the new app is not run by any workflow step | the declared-checks census and the workflow-commands census |

## Hosted checks that accept the work

The gate is the continuous integration itself. The table of jobs, their verbatim
commands and the red run cited for each is in the gate page, combined once from the
independent gate author's table. The local leg is the cheap command run before the
push: the shell syntax and lint of the new scripts, the flake evaluation, the
documentation check for the touched pages. The journey itself runs locally at most
once, on the final candidate, inside a memory-capped scope and a timeout, because
the hosted job is the net; no other hosted job is repeated locally.

## Two checks outside the repository

The diff names only files in the touch list, and the files the open job runs
(`tools/demo1_cli_check.sh`, `tools/demo1_cli_journey.sh`, `tools/verify_release.sh`
and the open app in `flake.nix`) are unchanged apart from the wrapper's journey
parameter. These are run by the ticket owner from the runtime record before the push.

## Not touched, by name

The registry contract, the registry library, the `singular` commands, the open-datum
executable and every Haskell file (including wallet preparation: `Entry.hs`,
`Plan.hs`, `Preview.hs`, `Prepare.hs` and their tests, and the signing files),
the on-chain code and identity records, `tools/verify_release.sh`,
`tools/demo1_cli_check.sh`, `tools/demo1_cli_journey.sh`, the negative-host sources
and workflow, and all Lean. The refusal of a hand-built update by the node is the
negative-host ticket.

## Residuals this change leaves, written before the work

- The write-once rule has no Lean statement, by ruling.
- `inspect` does not print the mode; the journey shows it through the page and the
  refusal.
- The outputs at the application address are not read; the proof of a refused update
  is the controller's wallet and the name's own output, which any submitted update
  would change.
- The journey does not prove the validator refuses a hand-built update; that is the
  negative-host ticket.
- The first hosted run sets the job's real time; the timeout is a measurement, not a
  claim about the devnet's speed.
