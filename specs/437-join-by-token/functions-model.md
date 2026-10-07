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
- **`findReferences :: Monad m => Session w m -> Maybe Addr -> Map ReferenceRole ScriptHash -> Set ReferenceRole -> m (Either ReferenceRefusal (Map ReferenceRole (TxIn, TxOut ConwayEra)))`**
  - Arguments: `session`, `walletAddress`, `expected`, `needed`.
  - Versioned 2026-10-07 for the operator's two-source ruling. A wallet address, rather than
    already-read outputs, lets discovery defer the wallet read until a needed role is missing
    from the provider. `Nothing` supplies no wallet fallback.
  - Only needed roles are queried. When the provider supplies all of them, the wallet is not
    read; with no needed roles, no discovery read occurs. Each role uses the lowest locally
    admitted output reference within the first source that supplies it.
  - Returns carriers only; no warning list or caller-supplied reference source remains.
- **`renderIdentityRefusal :: IdentityRefusal -> Text`** and
  **`renderReferenceRefusal :: ReferenceRefusal -> Text`**
  - Argument: `refusal`.

## CLI

- **Global options** gain `--state-token` (with `SINGULAR_STATE_TOKEN`). Every registry subcommand
  except `create` refuses to run without a state token.
- **`neededRoles`:** each transaction-building command declares the set of reference roles its
  builder runs.
  - A test pins the set per command.
- **Slice 2:**
  - `publish-references [--role ROLE]…` and `retire-references`;
  - `--publish-references` on transaction-building commands;
  - a coin-selection predicate that rejects outputs carrying a reference script.
- **Slice 3:** `describe [--json]`.

These two slices are versioned here when they start.
