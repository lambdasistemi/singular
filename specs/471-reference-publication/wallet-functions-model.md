# Alice funds a transaction without spending a published carrier: wallet interface

As Alice, with a large script carrier, a token-holding output and a plain output, I fund a write
from the plain output. Bob can still find the carrier. This specialises the [functions model](functions-model.md)
under the opaque-wallet ruling; package placement is in the [modules model](modules-model.md).
Types and script-hash admission are in the [data model](data-model.md). No Lean/onchain change.

## The capability boundary

`Session w m` is abstract to shipped builders and the CLI: no constructor, fields, record updates,
raw OutputQuery constructors/combinators, general output lookup or raw history is exported there.
Provider/kernel code keeps those capabilities internally. Public provider constructors return only
the abstract session. Reconstruction exports state/refusals, never historical transaction/CBOR data.
Plain ledger types are not read capabilities. Evaluation/time services do not return raw wallet lists.

`WalletOutputs` is opaque; only its defining module reads or constructs its raw wallet list.
Acquisition preserves read failures and the existing witness treatment; it authenticates no provider.
Reference and script reads retain their existing witness types, admission checks and refusal order.

## Wallet acquisition and selection

In `Singular.Registry.WalletOutputs`:

- **`walletOutputs :: Monad m => Session w m -> Addr -> m (Either ReadFailure WalletOutputs)`**
  - Arguments: `session`, `walletAddress`. The only builder-facing wallet acquisition.
- **`fundable :: TxOut ConwayEra -> Bool`**
  - Argument: `output`. ADA only and no reference script; StateToken re-exports this one predicate.
- **`fundingOutputs :: WalletOutputs -> [(TxIn, TxOut ConwayEra)]`**
  - Argument: `walletOutputs`. Fundable outputs only, largest first with deterministic ties.
- **`chosenFunding :: TxIn -> WalletOutputs -> Either FundingRefusal WalletOutputs`**
  - Arguments: `chosenInput`, `walletOutputs`. Narrows to the requested fundable input or refuses.
    Absence/ineligibility retain existing command refusals; no raw fallback or new public name.
    Only the ordinary funding view narrows; named protocol/carrier selections retain their inputs.
- **`narrowFunding :: Monad m => Addr -> TxIn -> Session w m -> m (Either FundingViewRefusal (Session w m))`**
  - Arguments: `payerAddress`, `chosenInput`, `session`. Validates through walletOutputs and
    chosenFunding, returning an abstract session with only that address's ordinary funding view
    restricted. Reference fallback, owned carriers, protocol/history/observation reads and other
    addresses remain unchanged. No arbitrary session rewrapping or callback is exposed.
    FundingViewRefusal is FundingReadFailure ReadFailure or FundingInputRefusal FundingRefusal;
    retain existing provider-failure versus invalid-input outcomes and messages, no public rename.
    Later ordinary funding acquisitions retain the restriction, never fall back to another input.
- **`seedOf :: TxIn -> WalletOutputs -> Either SeedRefusal ((TxIn, TxOut ConwayEra), WalletOutputs)`**
  - Arguments: `seedReference`, `walletOutputs`. Requires a fundable seed, returning it and the
    wallet view with it reserved. SeedAbsent/SeedNotFundable precede the existing no-funding check.
- **`carriersOf :: ScriptHash -> WalletOutputs -> [(TxIn, TxOut ConwayEra)]`**
  - Arguments: `expectedHash`, `walletOutputs`. Computes the carried script's actual hash locally.
    Used only for deferred reference fallback and matching owned retirement under the shared-state
    ruling. No provenance or arbitrary protocol exception. StateToken.ownCarriers uses it per role.
- **`burnCandidates :: Asset -> WalletOutputs -> [(TxIn, TxOut ConwayEra)]`**
  - Arguments: `burnAsset`, `walletOutputs`. Only outputs holding the specific policy/name asset
    required by the fold's negative mint. Keep the wallet opaque in the context until that asset
    is known. Preserve burnSource's unique-output/unit-quantity/datum checks and token-missing
    refusal; retain wrong quantities and duplicates for those checks. No all-token wallet view.
    This realises Singular.txBurnInputs/txOfExit, not ordinary funding or a new protocol rule.
    Cage/script burn sources keep their existing location/datum checks via named script reads.

## Named protocol and observation reads

In `Singular.Registry.Reads`, `ScriptAddress` has a private constructor:

- **`scriptAddress :: Addr -> Maybe ScriptAddress`**
  - Argument: `address`. Admits only a script payment credential.
- **`atScriptAddress :: Monad m => Session w m -> ScriptAddress -> m (Either ReadFailure (Evidenced w Outputs))`**
  - Arguments: `session`, `address`. Returns script-address outputs, retaining provider provenance.
- **`holdingAtScript :: Monad m => Session w m -> Asset -> m (Either ReadFailure (Evidenced w Outputs))`**
  - Arguments: `session`, `asset`. Asset candidates at script credentials; identity still checks
    the expected state address/datum/pins. Wallet-token candidates are not ordinary funding inputs.
- **`carrying :: Monad m => Session w m -> ScriptHash -> m (Either ReadFailure (Evidenced w Outputs))`**
  - Arguments: `session`, `expectedHash`. Actual carried-script hashes are locally admitted, never
    provider hash fields. Keep live-output/read-failure and deferred provider-first selection.
- **`outputVisible :: Monad m => Session w m -> (TxIn, TxOut ConwayEra) -> m (Either ReadFailure Bool)`**
  - Arguments: `session`, `expectedOutput`. Confirmation of the exact submitted output receives
    what it compares. Preserve missing-other/conflicting/released/backend distinctions and waits;
    read failures are not False. Return any incompatible existing boundary as a concrete challenge.
- **`carriesAt :: Monad m => Session w m -> TxIn -> ScriptHash -> m (Either ReadFailure Bool)`**
  - Arguments: `session`, `publishedReference`, `expectedHash`. Create read-back checks the actual
    carried script hash; no unrestricted output is returned.
- **`livingAt :: Monad m => Session w m -> Addr -> m (Either ReadFailure (Set TxIn))`**
  - Arguments: `session`, `paidAddress`. Recovery keeps the address-wide live-reference observation.
- **`liveAs :: Monad m => Session w m -> Addr -> (TxIn, TxOut ConwayEra) -> m (Either ReadFailure Bool)`**
  - Arguments: `session`, `ownerAddress`, `expectedRefund`. Keeps address-wide exact refund equality.
- **`reportOutputsAt :: Monad m => Session w m -> Addr -> m (Either ReadFailure Aeson.Value)`**
  - Arguments: `session`, `address`. Inspect's existing receipt field, with identical JSON/failures;
    supplies no builder-facing raw output accessor.

Existing non-output parameters/tip/time/mintRecord/scriptRegistered/transactionBlock services become
named functions over abstract Session with their already-bound arguments, evidence and refusals.
Other necessary service/signature changes return to the ticket owner; no general query escape hatch.

## Correspondence evidence

- A positive legal builder and independent planted negatives use exactly the executable's actual
  component dependencies: raw session fields/constructors, AtTxIn/AtAddress/HoldingAsset/combinators,
  raw history/record updates, WalletOutputs unwrapping and provider internals are inaccessible.
  Retain actual commands/exits/GHC errors; expected negatives differ from setup or behavioral RED.
- Focused write-command RED/GREEN exercises the ruled carrier/token/plain-output wallet. All ordinary
  selectors and predicate copies migrate together; --fund-input cannot bypass fundable.
- Existing confirmation/create/recovery/refund/inspect contracts retain positive and material
  missing/altered/spent/read-failure controls, including byte-identical inspect receipt fields.
  The package migration changes no address-wide observation into a transaction-only observation.
- Burn controls keep the specific required token distinct from fee funding and reject missing,
  duplicate, wrong-policy/key/quantity sources as before. Reclaim permits its named request plus
  the narrowed fundable inputs only; carrier/token/unrelated inputs fail before signing, while
  a valid reclaim and its existing refusal/receipt outcomes remain unchanged.
- Component exports, dependency graph and moved consumers must actually build at the candidate;
  tests' kernel access cannot substitute for the shipped component opacity control. This is focused
  author evidence, not permission for a full local campaign, auditor execution or hosted acceptance.

## Current child binding

Retained from accepted #437 technical interfaces at archive ee3fdf4f; source start26af5ae7,
Lean tree16ee2d4a/constitution1.13.0. Existing-command funding and named read preservation
are #471 requirements. Own-carrier selectors preserve the closed boundary, but new retirement
and page commands/connected evidence remain #502/#503. No raw-capability exception follows
from selective recovery of implementation. Return changed contracts before relying on them.
