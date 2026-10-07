# Test existing recovery exports without changing their contract

As a maintainer, I want the recovery tests to call the production composition, so they observe real persistence and refusals.

## New test export

`Singular.CLI.RecoverySpec.spec :: Spec` adds the four offline stories to the existing Hspec suite. Test-local helper bodies and fault instrumentation belong to the commit owner, within the source fence; this model prescribes no algorithm or test implementation.

## Existing production signature bindings

| Function | Explicit arguments and result | Constraint |
| --- | --- | --- |
| `reconcile` | `command :: Text`, `dir :: FilePath`, `saved :: Saved`, `view :: Session NoWitness IO`; result `IO Reconciliation` | Executes existing saved-registry reconciliation and public-history observation |
| `reconcileIncomplete` | `command :: Text`, `dir :: FilePath`, `view :: Session NoWitness IO`; result `IO Reconciliation` | Executes existing incomplete-create reconciliation; no invented saved registry |
| `refuseUnreconciled` | `reconciliation :: Reconciliation`; result `IO ()` | Preserves existing `CommandFailure` outcome and fields for unresolved recovery |
| `reconciledJson` | `reconciliation :: Reconciliation`; result `Value` | Serializes the production result, not a fixture-authored verdict |
| `recoveryJson` | `recoveries :: [Recovery]`; result `Value` | Serializes recorded recovery decisions using the existing vocabulary |

The recorded four-mode core calls `reconcileIncomplete`; a separately labelled synthetic saved-registry supplement calls `reconcile` and demonstrates public-history acquisition with a discriminating missing-history control. No new or changed production signature is authorized. A needed injection/placement change returns a concrete contract challenge. The second slice receives its own selected signatures before its worker dispatch.
