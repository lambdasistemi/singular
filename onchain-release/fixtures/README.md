# Contract fixtures — the vendored v0.2.0 wire vectors

These are the four epic-15 wire vectors, vendored byte-for-byte from
the accepted naming contract so that checking against them needs no
network and no clone.

- `Naming-Wire-Vectors.hs` — the vendored fixture module, byte-identical
  to `offchain/naming/src/Naming/Wire/Vectors.hs` in this archive (the
  release checker asserts the two copies agree byte for byte).

## Provenance

| field | value |
|---|---|
| release | epic 15 v0.2.0 — the accepted naming contract |
| release commit | `13231f58833b8feb57f4b0f9b1117bfcfba0c07d` |
| annotated tag | `e9fdbf2afa7d99a42f2476434c1dfb3f90d7a1d5` |
| release asset | `singular-docs-0.2.0.tar.gz` |
| asset sha256 | `acbabdf54a271251bd73bf9d84ab2c901107045a7dd77d28a391f22cdd53b0e5` |
| source inside that archive | `simulator/lifecycle-corpus.json`, `wire` array |

Verify before trusting these bytes: the module header carries the same
provenance, and the four vectors are additionally pinned in epic 15's
live corpus (`lean/lifecycle-corpus.json` in the repository), with a CI
drift check that fails when the two copies diverge.

If the naming codec disagrees with these vectors, the vectors are
right and the codec is wrong. The rows built on them (`LM01`–`LM04`,
`WR01`, `LC01`–`LC04`, `LC06`) are finite fixture execution — see
`RELEASE.md` for what that does and does not establish.
