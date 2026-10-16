# Tasks for signing a bundle

## Slice: codec and witness

- [x] bundle-codec: the bundle types, the JSON codec with its version field, the transaction and witness envelopes; round trip on several transactions in order; unknown version, missing field and malformed envelope refused.
- [x] bundle-consistency-check: identity equals the body hash, deadline equals the body's bound, required signers covered, duplicate identities refused, each naming both sides.
- [x] detached-witness: the witness helper; the signature verifies against the body hash and the key hash is the signer's.
- [x] bundle-fixture: the synthetic unsigned body committed as data and rebuilt by a spec that fails on any difference.

## Slice: sign verb

- [x] wallet-sign-verb: `singular wallet sign` with the vault, the bundle, the passphrase descriptor and the output directory; refuses provider and registry options; documented flags equal `--help`.
- [x] witness-files: one witness per transaction named by its identity, created exclusively, paths on standard output and the summary on standard error.
- [x] sign-documentation: the command reference and its narration clips.
- [x] packaged-sign-controls: the real binary through a descriptor: sign, tampered body refused, vault not among the signers refused, existing witness refused, offline by the namespace or the canary; each control red against a planted defect.
