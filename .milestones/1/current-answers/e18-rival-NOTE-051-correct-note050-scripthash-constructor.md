# NOTE-051 — correct NOTE-050 `ScriptHash` constructor

Read and ACK before using NOTE-050's synthetic hash fixtures. Preserve NOTE-050
and its ACK unchanged as the record of this parent transcription error.

NOTE-050 incorrectly wrote:

```haskell
ScriptHash (unsafeMakeSafeHash (castHash (hashWith id bytes))) :: ScriptHash
```

That is wrong. The frozen pinned GHC 9.12.3 public-API probe actually
typechecked:

```haskell
ScriptHash (castHash (hashWith id bytes)) :: ScriptHash
```

Only the synthetic `TxId` and `ScriptIntegrityHash` fixtures use
`unsafeMakeSafeHash` in this probe. The complete corrected trio remains:

```haskell
TxId (unsafeMakeSafeHash (castHash (hashWith id bytes))) :: TxId
ScriptHash (castHash (hashWith id bytes)) :: ScriptHash
unsafeMakeSafeHash (castHash (hashWith id bytes)) :: ScriptIntegrityHash
```

`bytes` is explicitly `ByteString`; result types infer the algorithms. All
other NOTE-049/050 instructions and offline/no-ledger fences are unchanged.
Do not credit any control compiled from the mistaken `ScriptHash` form.
