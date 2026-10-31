# Plan for hand-built transactions refused by the deployed validators

Issue 764, first slice. The story and requirements are in [the specification](spec.md); the gate is in
[the gate page](gate.md).

## Class and model position

The change adds a hosted job, a driver script and test-only harness cases. It changes no product behaviour, no on-chain
script, no script hash, no Lean statement and no wire format. Its model position is Inside as evidence: it exercises, on a
development network, refusals that the aligned models state, and claims nothing beyond the three cases it runs. It is one
slice, one pull request, `Refs #764`.

## Lean binding

Lean is the authority. The check takes the models' words and changes none of them.

| Family | Lake project and library | Statement the refusal is evidence for |
| --- | --- | --- |
| Singular fold | `models/singular-application-held`, `SingularApplicationHeld.Statements` | `registration_inversion`: a registration of a key that is not absent is not an accepted fold |
| Open-datum lifecycle | `models/open-datum-application-held`, `OpenDatumApplicationHeld.RefundLifecycle.Statements` | `liveUpdate_inversion`: a live update needs the controller's signature and recreates the holding with the same control and tokens |
| Money and equivalence | the same project, `OpenDatumApplicationHeld.Money.Statements` | `accepted_update_authority`: who may authorise an accepted update |

A refusal on a development network is evidence over the one input it runs, not a statement about every input. A statement
the code cannot meet, or whose wording the three cases do not match, is a question to the epic owner, never a quiet change
of a case.

## Strategy

The refusals job beside this one already shows the pattern: a driver script makes a registry with the packaged commands, a
test-only harness builds one transaction with one fact wrong and submits it, and the chain's own record decides. This
ticket follows it exactly and adds nothing to a product command.

- The starting state is made by the packaged commands: a registry, a registered key with its holding, and a pending booking
  for a key that is already registered.
- The harness builds each attempt with the repository's transaction builders, from the live holding or fold the ledger
  provider session reads, with exactly one fact made wrong, and builds the control with that fact restored.
- The driver judges each verdict from the node's answer and the chain's record, runs each assertion on altered input to see
  it fail, and writes a verdict table of six rows.
- The nix app, the workflow job and the declared-checks row are in the first commit that adds the driver, so the check is
  hosted from the start.

## Constraints

- Devnet only. No preprod work, no live transaction.
- No change to on-chain scripts, their hashes, the Lean models or a wire format. If the job seems to need one, the commit
  owner files a question first.
- The taken-key attempt uses only the answer the honest registry tree gives for that key.
- The validators are the deployed ones as built from main.
- Every build and test runs in a named, memory-capped scope with a timeout.

## Slice

One slice and one pull request. The work lands in steps by acceptance line: the driver, the nix app, the job and the
declared-checks row first, with the three cases not yet judged; then the taken-key pair; then the update pair; then the
holding pair; then the driver header, which says what the job shows and what it does not. The pushed history is one commit
beside the planning commit.

## Existing consumers to check at intake

A new app and job touch: the declared-checks census, the workflow-commands census, the input-output ownership census, the
node-confinement allowlist, the code inventory and the harness package's component inventory entry, the packaged-scripts
bundle in `flake.nix`, the format and lint invocations for Haskell, shell and workflow files, and the job-name set that the
required checks list is built from.
