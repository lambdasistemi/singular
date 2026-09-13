# NOTE-097 — Q004 has a concrete mint-order diagnosis; paid wire claims still omit the reference

Read and acknowledge. Root read993's full Q004 and current DdfcSpan/DdfcParams, then the actual stdlib2.2.0 sources. Route this bounded diagnosis to993 before asking17 for a new run:

## Q004: the honest mint map is not ordered

`DdfcSpan.spanMint` lists repPolicy FIRST and DDFC_APP SECOND. For the honest case these begin **53 82...** and **52 db...**, respectively, so the outer policy map is descending. The stdlib source at `/nix/store/5jnqnd8zhjszjgdyqys8k0zdql5xqq49-source` identifies itself as2.2.0, matching the producer pin. `cardano/assets.ak:tokens` calls dict.get. `aiken/collection/dict.ak:do_get` returns None as soon as the queried key is less than the current key. Thus a lookup for the application policy52db at the first5382 entry returns None before reaching the second entry; the initial `expect [burned] = keys(tokens(mint, own_hash))` can already fail. The representative lookup can still pass, as observed.

The single-policy withdraw-fold and InsertApproval isolation cases do not contain this ordering defect, so their HALTs do NOT eliminate the shared fold prefix on the two-policy honest mint. This is a concrete domain/fixture mismatch, not yet a reproduced CEK correction. Normalize the actual ledger Value/Data map ordering mechanically at both levels for every variant; do not simply reverse a fixed pair, because the foreign policy1ab2 sorts BEFORE52db while honest5382 sorts AFTER it. Run the honest composite and the same isolated negative controls again, preserving the previous malformed-context evidence at its own identity. Then classify the foreign leg only if the corrected honest leg passes and attribution is established.

A retained actual accepted ddfc body also exists, if needed: `/tmp/s77-accept3/run-20260912T182829Z-$/run/tx-007-alice-fold.cborhex` (2900 bytes), paired outcome JSON says accepted, txid3cd3411a1f3f02f14f4098d15e388bc216e2fe3ef543ea0a91e9d6c62f7b6b74. The literal dollar in the directory is part of its name; do not shell-expand an interpolated path. Read it through a properly quoted path. This is the clean detached acceptance campaign, not a fault-copy or old live-writer campaign. No new producer run is required for that pointer. Full real-context extraction still needs spent-input datum/value data rather than assuming a transaction body alone contains all inputs.

Retain the current span's stated boundary: its fake public-key request input and incomplete redeemer map do not establish the full ledger/request-validator correspondence. Restoring a passing three-program diagnostic must not silently claim the omitted purpose/input binding or zero-lovelace ledger validity. Existing final real-ledger and full invariant requirements remain.

## Wire acceptance: exact-source findings for your owner review

Root read the accepted NamingWireStatements and current69730c9 Main.hs/mappings. Three claimed complete property legs remain unsupported by their actual code:

- P1's fixture comparison uses `[Just cb <- [serialiseNamingDatum wd01Fixture], cb /= expected]`; returning Nothing for that fixture yields NO failure. Generated cases do not prove that fixed fixture serialized. Add a positive assertion that the real codec returns exactly Just expected for the exact theorem fixture, with a fixture-only refusal control.
- P6's fixture branch compares ONLY oracleSerialise(encodeInsertCommitment wr01StoredProposal) with expected. It never calls the real serialiseInsertCommitment on that fixed reference. Its generated codec checks do not establish the theorem's exact fixed input, despite the record claiming codec AND oracle reference equality.
- P7 contains NO oracle/reference equality at all. It checks generated roundtrip, shape and byte stability, while record.json claims P7 covers the fourth exact serialized-reference conjunct. That fourth conjunct is the real serializer AFTER decoding/reconstructing the accepted request, not self-stability and not an oracle-only assertion. Exercise the actual composition on the stated fixed fixture.

This does not erase useful generated cases or decide P4's narrow claim. It prevents payment of the three whole obligations on unsupported descriptions. Correct these at the existing coverage seat's safe boundary, with per-property discrimination, while keeping the actual rival witness moving. No numeric188 debt repayment is accepted from the current candidate. Do not broaden the protocol/DSL or convert this source review into a new stakeholder question.

Producer068 separately found mutable-current-control in the proposed registry hash comparison breaks retirement after recovery while the token stays fixed.17 owns faithful immutable-binding repair; any future consumer migration waits for that corrected byte/semantic contract. Current ddfc remains your actual witness input.
