# NOTE-149 — verified compiler facts for the existing mintless check

Preserve the same994/current offline block, histories and any in-flight command. Root observed repeated standalone mintless compilation failures and checked the actual pinned GHC9.12.3 environment, rather than guessing API versions. This is a bounded technical diagnosis, not a repaired worker artifact, gate success, model change or ledger authority. Receipt /tmp/projects/singular/milestone-1/handoffs/rival-root-mintless-api-diagnosis.json; exact interactive input/output in /tmp/singular-root-mintless-api-9I5vCu and frozen handoffs copies.

The helper is a standalone module, while the cabal component supplies OverloadedStrings. A ByteString type annotation does NOT turn a String literal into bytes without that extension. Root's actual GHCi negative produces Expected BS.ByteString / Actual String; enabling OverloadedStrings accepts the identical literal. This is not evidence that Cardano hash takes a proxy/algorithm value or changed its arity. Use explicit BS construction or the intentional extension for the standalone check.

Pinned API readback: Cardano.Crypto.Hash.Class.hash :: (HashAlgorithm h, ToCBOR a) => a -> Hash h a; hashWith :: HashAlgorithm h => (a -> ByteString) -> a -> Hash h a. Cardano.Ledger.Hashes exports unsafeMakeSafeHash :: Hash HASH i -> SafeHash i. Cardano.Ledger.SafeHash is NOT an available module here, and direct coerce into abstract SafeHash/TxId fails because its constructor is hidden. The final probe typechecked these PUBLIC fixture constructions with empty stderr:

- TxId (unsafeMakeSafeHash (castHash (hashWith id bytes))) :: TxId
- ScriptHash (castHash (hashWith id bytes)) :: ScriptHash
- unsafeMakeSafeHash (castHash (hashWith id bytes)) :: ScriptIntegrityHash

bytes is explicitly a ByteString; enclosing result types determine the hash algorithm. These are only the control's synthetic seed/script/view-hash fixtures, NOT a replacement for production deriveAssetName in real B seed binding.

Body fields are lenses: b ^. inputsTxBodyL, b ^. outputsTxBodyL, b ^. feeTxBodyL and b ^. scriptIntegrityHashTxBodyL all typecheck for b :: TxBody TopTx ConwayEra. Earlier inputsTxBodyL body etc are lens-as-function mistakes, not unknown era APIs. All four types and all three fixture types are retained in correct-public-api.stdout, stderr is empty. Earlier exploratory failures remain separately retained and get no credit. GHCi often exits0 after errors, so the original exit alone was never treated as proof.

Have the existing worker stop guessing these APIs, finish the actual shared-construction control with its true compile/run exits and positive/injected-hash discriminator, then continue the already authorized frozen offline packet. No new seat or broader rewrite. Do not count this type probe as the full control or replay a ledger run.

Transport correction: root inspected ONLY selected native user-event metadata. NOTE049 is already present in same session as user entry01b320ad at02:52:07.667Z, so no resend/restart is justified. Its durable STATUS ACK is still absent. At the next safe boundary require full NOTE049 read and the missing durable acknowledgement before its dependent work is credited; then keep its exact seed-token/full-signed-evidence/post-confirmation requirements. Raw native history stays local, never republished. No second ledger, acceptance, commit/push/merge/release or change to A006/E17 authority.
