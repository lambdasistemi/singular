# A registry joined from its state token: functions model

This file lists only new or changed signatures. The names are proposals for the commit owner. A
signature change goes back to the ticket owner as a challenge. Types refer to the
[data model](data-model.md).

## Provider interface

- **`OutputQuery`** gains the constructor `CarryingReferenceScript ScriptHash`. It is answered by
  the existing `outputs` session field with the same `Evidenced w Outputs` shape.
- **`Session`** gains the field `mintRecord :: Asset -> m (Either ReadFailure (Evidenced w (Maybe
  MintRecord)))`.
  - Argument: `asset`.

## Koios client

- **`referenceScriptUtxos :: KoiosClient -> NonEmpty ScriptHash -> IO (Either KoiosError [(ScriptHash, TxIn)])`**
  - Arguments: `client`, `scriptHashes`.
- **`utxoInfo :: KoiosClient -> NonEmpty TxIn -> IO (Either KoiosError [UtxoInfo])`**
  - Arguments: `client`, `outputReferences`.
- **`assetInfo :: KoiosClient -> Asset -> IO (Either KoiosError (Maybe AssetInfo))`**
  - Arguments: `client`, `asset`.

## Registry identity and references

- **`parseStateToken :: Text -> Either Text Asset`**
  - Argument: `spelling`.
- **`expectedReferences :: Release -> Asset -> Map ReferenceRole ScriptHash`**
  - Arguments: `release`, `stateToken`.
  - Total over every role.
- **`resolveRegistry :: Monad m => Release -> Asset -> Session w m -> m (Either IdentityRefusal ResolvedRegistry)`**
  - Arguments: `release`, `stateToken`, `session`.
  - Applies the refusals in the data model's order. No file access.
- **`carriesReference :: ScriptHash -> TxOut ConwayEra -> Bool`**
  - Arguments: `expectedHash`, `output`.
  - Computes the hash from the output's script.
- **`findReferences :: Monad m => Session w m -> [TxIn] -> Outputs -> Map ReferenceRole ScriptHash -> Set ReferenceRole -> m (Either ReferenceRefusal (Map ReferenceRole (TxIn, TxOut ConwayEra), [TxIn]))`**
  - Arguments: `session`, `hints`, `walletOutputs`, `expected`, `needed`.
  - The returned `[TxIn]` lists the hints that were not admitted.
- **`renderIdentityRefusal :: IdentityRefusal -> Text`** and
  **`renderReferenceRefusal :: ReferenceRefusal -> Text`**
  - Argument: `refusal`.

## CLI

- **Global options** gain `--state-token` (with `SINGULAR_STATE_TOKEN`) and repeatable
  `--reference-hint TX#IX`. Every registry subcommand except `create` refuses to run without a
  state token.
- **`neededRoles`:** each transaction-building command declares the set of reference roles its
  builder runs.
  - A test pins the set per command.
- **Slice 2:**
  - `publish-references [--role ROLE]…` and `retire-references`;
  - `--publish-references` on transaction-building commands;
  - a coin-selection predicate that rejects outputs carrying a reference script.
- **Slice 3:** `describe [--json]`.

These two slices are versioned here when they start.
