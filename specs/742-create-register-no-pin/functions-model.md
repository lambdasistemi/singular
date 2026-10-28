# Functions for creating a registry and registering a key on the proved design

Issue 742. This page lists only new signatures, with explicit argument names and types. Bodies are the commit owner's.
Types refer to [the data model](data-model.md).

## On-chain

| Function | Arguments | Result | Constraint |
| --- | --- | --- | --- |
| `singular_state` (validator) | `application_policy: PolicyId` | mint and spend handlers | the only parameter; genesis and fold redeemers carry the seed |
| `state_token_name` | `seed: OutputReference` | `AssetName` | equal to the off-chain `stateTokenName` on every vector |
| `registration_preimage` | `key: ByteArray`, `registry: RegistryIdentity`, `holding_address: Address`, `datum_hash: ByteArray`, `deposit: Int` | `ByteArray` | the Plutus Data serialisation of the structured value |
| `approval_name` | `preimage: ByteArray` | `AssetName` | the hash function the aligned model names |
| `open_datum_requests` (validator) | none: its own hash is both the approval policy and the address of pending registrations (epic owner ruling) | mint and spend handlers | reads the configuration record by reference; never reads a root or a trie proof |

## Off-chain

| Function | Arguments | Result | Effect |
| --- | --- | --- | --- |
| `stateTokenName` | `seed :: TxIn` | `AssetName` | pure |
| `registrationPreimage` | `key :: ByteString`, `registry :: RegistryIdentity`, `holding :: Address`, `datumHash :: DatumHash`, `deposit :: Lovelace` | `ByteString` | pure |
| `buildGenesis` | `session :: Session NoWitness IO`, `script :: StateScript`, `seed :: TxIn`, `payer :: Addr`, `application :: RegistryIdentity -> Program ()` (the application's steps of the creation, such as open datum's configuration record) | `IO (Either Refusal (ConwayTx, RegistryIdentity))` | spends the payer's seed; publishes the scripts once per application, reuses live copies with the expected hash |
| `buildRegistrationFold` | `session :: Session NoWitness IO`, `script :: StateScript`, `application :: Application` (what the application hands the fold), `registry :: RegistryIdentity`, `pending :: [TxIn]`, `payer :: Addr` | `IO (Either Refusal ConwayTx)` | reads the registry's state, its pending registrations and its own folds from the chain alone, rebuilds the trie, builds honest proofs |
| `configurationCreate` | `script :: RequestScript`, `network :: Network`, `registry :: RegistryIdentity`, `seed :: TxIn`, `parameters :: RequestParameters` | `TxBuild q e ()`, a fragment of the creation transaction | adds the configuration record output and its mint; composed by the genesis builder |
| `buildBookRegistration` | `session :: Session NoWitness IO`, `script :: RequestScript`, `booking :: Booking` (registry, key, payload, deposit, tip, refund address), `payer :: Addr` | `IO (Either Refusal ConwayTx)` | reads the configuration record by reference; the payer is the controller; refuses two records as ambiguous |
| `buildReclaim` | `session :: Session NoWitness IO`, `script :: RequestScript`, `pending :: TxIn`, `payer :: Addr` | `IO (Either Refusal ConwayTx)` | signed by the refund address, which must be the payer |
| `buildCleanup` | `session :: Session NoWitness IO`, `script :: RequestScript`, `pending :: TxIn`, `payer :: Addr` | `IO (Either Refusal ConwayTx)` | permissionless; the deposit to the refund address, the rest to the payer |

Where the aligned Lean models or the existing builders fix a different argument set, the mandate is versioned before the
slice that implements the function starts.
