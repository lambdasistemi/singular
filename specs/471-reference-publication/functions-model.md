# Publication and funding: functions model

Only changed interfaces are listed. Scope/binding: [plan.md](plan.md). Fields:
[data-model.md](data-model.md). Closed wallet/read signatures:
[wallet-functions-model.md](wallet-functions-model.md), retained from the accepted technical
packet. Other necessary signature changes return to the delivery owner before reliance.

## Shared release and discovery

In Singular.Registry.StateToken:

- `referenceScripts :: Release -> Asset -> Map ReferenceRole (Script ConwayEra)`
  - Arguments: release, stateToken. Total over the six existing roles.
- `checkedScript :: Release -> Asset -> ReferenceRole -> Either ReferenceRefusal (Script ConwayEra)`
  - Arguments: release, stateToken, role. Built hash must equal the expected role hash.
    Mismatch refuses before building/signing/writing; an independent altered-script control is required.
- `missingReferences :: Monad m => Session w m -> Maybe Addr -> Map ReferenceRole ScriptHash -> Set ReferenceRole -> m (Either ReferenceRefusal (Map ReferenceRole (TxIn, TxOut ConwayEra), Set ReferenceRole))`
  - Arguments: session, walletAddress, expected, needed. Shares existing deferred provider-first
    discovery and local candidate admission. Returns found carriers and missing roles without
    a missing-role refusal; findReferences adds that refusal to the same search.
- `fundable :: TxOut ConwayEra -> Bool`
  - Argument: output. Re-export of the one wallet predicate, never a second implementation.

## Publication builder

In Singular.Registry.TxBuilder.Edges:

- `publishReferencesTx :: Session NoWitness IO -> Addr -> WalletOutputs -> [Script ConwayEra] -> IO (ConwayTx, [TxOut ConwayEra])`
  - Arguments: session, payerAddress, walletOutputs, scripts. One transaction creates one
    ledger-minimum-ADA output per checked script at the payer address, using permitted funding.

## Command composition

In Singular.CLI.References / Command:

- `PublishReferences PublishArgs` uses token, blueprint, actor wallet/directory, current write
  settings, preview, receipt and applicable fund-input/max-outlay controls. Publish has
  repeatable --role ROLE; no selection considers all six missing roles.
- `--publish-references` on insert/update/terminate/fold/reject/reclaim explicitly restores
  exactly missing command-needed roles, reads new outputs back, then continues. Without it,
  existing missing-reference refusal remains. Demo2's separate no-auto policy is preserved.
- `neededRoles` keeps each transaction-building command's existing role set. Explicit
  publication searches the requested roles; an empty needed set causes no discovery read.

Existing Session services preserve current parameters, tip/time, mint record, confirmation,
script registration, reconstruction and tracing result shapes. Builders receive only named
reads and opaque funding. Exact command recovery and preview composition is inherited;
no generic query escape hatch or new recovery policy is introduced.

Existing-command reclaim retains the named request plus fundable selected fee inputs. New
retireReferencesTx/RetireReferences and describe/page signatures stay deferred to #502/#503.
