# Tasks

Retroactive record, written 2026-09-15 from PR #112 merged at
`b4a36eaf72d8a355d9048a00081a8f999c195e27`.

The tasks are the PR's commits in order, each done with its sha.

- [x] T110-1 `0a75b764d17f79893e64facfa79567df865f0d53` feat: bind
  representative policies to their registry.
- [x] T110-2 `bea5e36a3ce5d823575a11417b0c5da7b0ffb18c` feat: derive
  representatives from spelling and witness retirement registry.
- [x] T110-3 `900936f948441c9dbbbcd48c08660bdf065c629a` fix: exercise
  registry refusal and follow accepted retirement evidence.
- [x] T110-4 `83da8c6e228df7c2c19bc1d4be2bc35f1ac841e8` docs:
  distinguish Over from an unclaimed spelling.
- [x] T110-5 `d796fdabff43be7f74045f242754f6e9423aa58f` feat: deploy
  and verify registry-bound representative policies.
- [x] T110-6 `64b005363f1f201a4593616d4b5420bbd96590ab` fix: verify
  attached request identity without a local boot.
- [x] T110-7 `279d14191c892218719235a0b031668eb28a79eb` fix(ci):
  keep checks out of the build gate.
- [x] T110-8 `e8079e4fbe25c974a8078674e1a4b4f8dddb87e3`
  fix(offchain): preserve reference publications when funding
  bootstrap.
- [x] T110-9 `7e49825a6c6a52dde674ef57d3052d917a923776` fix(ci): run
  every required check on all pull requests.

## Slice

Computable representative name with registry-bound policy and
witnessed retirement. Gate as shipped: `just ci` green, Aiken
135/135 and 145/145, consumer 145/145, Haskell 104/104,
script-identity builds, devnet name and refusal observations.
