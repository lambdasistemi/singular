# Connected naming API for #114

Issue https://github.com/lambdasistemi/singular/issues/117
Draft https://github.com/lambdasistemi/singular/pull/118
Worktree /code/singular-connected-cancellation, branch fix/connected-cancellation, owner %1194.

Implemented module `Naming.Connected` in the exposed naming library:

```haskell
connectedApplication :: CageConfig -> TokenId -> ShortByteString -> Script ConwayEra
registerConnected :: CageConfig -> Script ConwayEra -> Provider IO -> TokenId
  -> Addr -> ByteString -> NamingDatum -> ByteString -> Addr
  -> IO (ConwayTx, Registration)
cancelConnected :: CageConfig -> Script ConwayEra -> Provider IO -> TokenId
  -> Registration -> TxIn -> ByteString -> Addr -> IO ConwayTx
```

Registration arguments after TokenId: request owner/funder address, explicitly named controller key hash, unchanged four-field datum, spelling, immutable full refund address. It returns an unsigned evaluated/balanced transaction and public immutable Registration receipt. Persist that receipt and the transaction ID (request index is committed; actual claim outref is read from submission). No request-owner creation signer is added by the naming policy; the funding witness remains necessary.

Cancellation arguments after TokenId: original receipt, live claim outref, explicitly named withdrawal issuer key hash, fee-funding address. The builder obtains the exact native request via claim creation txid plus committed output index, checks both datums and Insert operation, and uses the existing native Retract timing and request-owner signer. The caller signs the required hashes and funding input and submits through its existing interface. It refuses unavailable/folded inputs or mismatching/non-Insert witnesses. This is a typed API; portable receipt encoding is still being completed before handoff acceptance.

`connectedApplication` applies the exact native request script hash derived with the pinned request blueprint, registry state policy and cage token to the new `connected.connected` application template. Use the resulting application hash to apply the existing representative template and initialize that registry. Old zero-parameter application entries remain compatible; this builder cannot retrofit existing deployments or old pending claims. #114 existing-deployment acceptance stays open. No deployment is authorized here.

A-003/A-004 correspondence: immutable versioned Insert commitment binds seed, registry policy/token, request output index/address/datum, full refund, four-field naming datum. Pending outputs cannot use Active-only Maintain/Recover/Retire. Cancellation composes existing mintWithdraw and withdraw: a distinct certificate hashes domain, registry policy/token, exact consumed native request outref and full refund; issuer is required explicitly under the existing WithdrawApproval mint rule. The same tx burns the original Insert token and mints +1 distinct certificate retained in the full refund output. It cannot authorize another request or replay spent inputs. No net-zero mint purpose or Insert-only success is claimed.

Current checks: 9 focused Aiken tests pass; source-bound Lean composition and unchanged Insert-only refusal build; production library/runner compile. Repaired real devnet acceptance is in progress, not yet GREEN. Accepted #110 integration remains required (PR112 freshly OPEN at 7e49825a6c6a52dde674ef57d3052d917a923776).

Acceptance command being delivered: `nix run ./offchain#connected-cancellation`. Desk forwards this API to #114; no CLI code is owned by this lane.
