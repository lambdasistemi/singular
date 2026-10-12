# keri-stub

A second application against the Singular registry library and
`registry-cli`, living in its own tree. The author of cardano-keri
starts from this stub to see what a second application needs and
copies it.

## What the stub is

- One always-succeeding Plutus V3 script, a constant of this package
  (`Singular.Application.KeriStub.Script`). It is both the approval
  minting policy and the spending script of the holdings the stub
  creates. No Aiken project, no blueprint.
- One holding datum (`Singular.Application.KeriStub.Datum`): a key,
  a controller key hash, a deposit in lovelace and an opaque
  identifier prefix as payload.
- One application value (`Singular.Application.KeriStub.Value`):
  name `keri-stub`, executable `keri-stub`, pin by hash of the
  script, decoder and holding rules over the holding datum.
- One command line (`keri-stub create|register|fold|status`): create,
  fold and status are thin calls to `runCreate`, `runFold` and
  `runInspect` of `registry-cli` with the stub's value; `register` is
  the entry command this package owns — it books one `insertActive`
  under the stub's policy, with `--fold` folding it in the same command.
  `convict` arrives in a later brief and is an unknown command for now.

## How to start an application from it

Copy this tree to the new application's tree, rename the package,
the module prefix and the value, replace the holding datum with the
new application's own datum, and keep the dependency direction: the
application depends on the registry packages only
(`../../../offchain`), never the other way round, and it names no
other application.

## Where its script comes from

The script's bytes are built by the stub itself: the serialised
always-succeeding UPLC program in `Script`. Nothing outside this
tree holds or names it. If the stub ever needs a real validator, it
gets its own Aiken project in its own tree.
