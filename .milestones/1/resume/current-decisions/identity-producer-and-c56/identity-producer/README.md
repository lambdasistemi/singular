# Production applied-List[] state identity, historical 5bd snapshot

Source: `5bd7c79dd64fd9c7ec872f1c20ab2f5e075366ad`, exact isolated checkout `/tmp/singular-identity-producer-5I7ygR`. No tracked onchain/offchain/Lean source changed. Scope: byte and credential handoff for Blaster Q002; no reachable-state, ledger execution, invariant, or final-ownerless acceptance.

The producer loads the unique `state.state.spend` from the Nix-built blueprint, then directly calls the unchanged SDK `Blueprint.applyPreviousPolicies []`, whose actual implementation calls `applyDataParam (PlutusCore.Data.List [])`. Its result is serialized single-CBOR UPLC, not naked Flat. Both representations are supplied.

Hashing calls the actual Conway ledger `mkPlutusScript @ConwayEra`, `hashScript @ConwayEra . fromPlutusScript` and `hashToBytes` APIs used by frozen `Internal.computeScriptHash`/`scriptHashBytes`. The full Internal module was not linked: it pulls unrelated transaction-provider code into this narrow helper, whose first build failed on missing Cardano.Tx.Ledger. The helper uses those same ledger operations explicitly; it does not use a home-grown hash as the producer. The second compile found an ambiguous Base16 module; hiding the unrelated `base16` package selected `base16-bytestring`. Both failed build logs are retained, and build3 succeeded.

Independent Python `hashlib.blake2b(b'\x03' + serialized_program, digest_size=28)` agrees with the ledger result. Bare hashing without the V3 tag differs, as does the unapplied program's identity. These negative comparisons prevent confusing the representation/hash layers; they are not product mutation tests.

- Applied hash: `ce7615f6ba4de80dfa9b9c6aef680666472ba4ed7e640ff55aad7c6e`.
- Unapplied hash: `d42860fa972c8a325daae773adc372795c48cf365d0a72b137c749d3`.
- `artifacts/applied.single-cbor.hex`: 7806 serialized bytes as hex, suitable for `single_cbor_hex` import.
- `artifacts/applied.flat.hex`: 7803 raw Flat bytes as hex, suitable for `flat_hex` import. Flat version prefix `010100`.
- `artifacts/applied.script-hash.hex`: 28-byte ledger hash as hex.
- `identity.json`, `provenance.json`: source/build/compiler/blueprint/source-file/artifact digests.
- `independent-hash-check.json`: independently recomputed hashes and the differing wrong-layer hashes.

The raw `compiledCode` exactly matches the Blaster worker's currently generated snapshot blueprint. Its actual Aiken preamble is v1.1.21+unknown. SHA256 of the whole Nix blueprint is c916813424e2d007cfc50135755dcc97e90c38b1f4e3f1cbdbf701eab28f0dd3.

Executed environment/build commands (the helper and logs are preserved here):

```sh
nix develop --no-update-lock-file /tmp/singular-identity-producer-5I7ygR/offchain --command bash -c 'command -v ghci; command -v cabal'
nix build --no-update-lock-file --quiet --no-link --print-out-paths /tmp/singular-identity-producer-5I7ygR/onchain#plutus-blueprint
/nix/store/dgvrp8z9n4b495z7hv18rzxq2vd06knw-ghc-shell-for-packages-ghc-9.12.3-env/bin/ghc -O0 -XGHC2021 -XDerivingStrategies -XDuplicateRecordFields -XOverloadedStrings -XRecordWildCards -XStrictData -hide-package base16 -i/tmp/singular-identity-producer-5I7ygR/offchain/lib -outputdir /tmp/singular-identity-producer-5I7ygR/build -o /tmp/singular-identity-producer-5I7ygR/identity-producer /tmp/singular-identity-producer-5I7ygR/IdentityProducer.hs
/tmp/singular-identity-producer-5I7ygR/identity-producer /nix/store/j9grxyyb9w9nbia92zhms26rhlfj8cn1-mpf-plutus-blueprint-0.0.0 /tmp/singular-identity-producer-5I7ygR/artifacts
```

The isolated executable remains available for reproduction. Consume supplied outputs once their manifest digests are checked. This is the old one-parameter state script only. The definitive f3 ownerless state script is parameterless and must be separately bound and rerun; do not apply List[] to it.
