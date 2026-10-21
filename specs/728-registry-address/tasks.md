# Tasks: a registry has an address in the style of a Cardano address

## The address

- [x] Tests: fixed addresses and fingerprints for the four networks, the CIP-14 published vectors, the round-trip property, the reading refusals in order
- [x] Tests: the registry given to a command from each of the three forms, with a state token and a network magic that agree and that disagree, and the renamed-flag refusal gone
- [x] Tests: `create` receipts and the line on standard error, `describe` and `inspect` receipts, a network without a prefix
- [x] Tests: `registry address` from an address and from a state token with a network magic, and its refusals
- [x] Tests: the table lookup for a hash of a known release, of a change not released yet, and of no known release
- [x] The address module and the shared reading of the registry for the three programs
- [x] `--registry` on every command that takes a state token, in the three forms
- [x] The address, the asset id and the fingerprint in `create`, `describe` and `inspect`
- [x] The command `registry address`
- [x] The table, filled from the published release assets by a script kept as a tool, packaged and shipped in the release bundles
- [x] The foreign-release refusal that names the release and where to get it
- [x] Help snapshots, parser corpora, the application settings spec and the `keri-stub` suite
- [x] Hosted checks: the journey that uses the address alone, the table holding the hash being built, the bundled program finding its table
- [x] Documentation of the address, the table and the settings, with regenerated narration
- [x] The note for the tutorial's owner

## The key reached by its witness token

- [ ] Intake: what `inspect` does today with a key, stated in the pull request
- [ ] Tests: a key reached by its witness token from a fresh state directory; a key never registered answered as today
- [ ] `inspect --key` by the witness token
- [ ] A hosted check that reaches a key from the address and a fresh state directory
- [ ] Documentation of the key's reach, with regenerated narration
