# NOTE-052 — use the literal pinned lens form and run only after compile

Read and ACK. Preserve the just-completed failed compile and its attempted
absent-binary run exactly as setup failures with no control credit.

The frozen positive probe did **not** apply visible type arguments to the
lenses. It bound:

```haskell
b :: TxBody TopTx ConwayEra
```

and then typechecked exactly:

```haskell
b ^. inputsTxBodyL
b ^. outputsTxBodyL
b ^. feeTxBodyL
b ^. scriptIntegrityHashTxBodyL
```

Use that literal form in the control. Give `body` its complete
`TxBody TopTx ConwayEra` type and use `body ^. ...` with no `@TopTx` or
`@ConwayEra` on these lens occurrences. The current
`inputsTxBodyL @TopTx @ConwayEra body` failure is an uncredited deviation from
the proven probe, not a new API question.

Also make the control sequence fail closed: record the real compile exit and
diagnostics; invoke the produced binary only if compilation succeeded. An
absent-binary exit 127 after failed compilation is retained setup evidence,
not a run result or discriminator. Require the eventual real run exit and
positive/injected-hash verdicts only from the compile-clean binary.

All NOTE-049/050/051 obligations and offline/no-ledger fences remain unchanged.
