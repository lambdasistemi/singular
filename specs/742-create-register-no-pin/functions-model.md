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
| `open_datum_requests` (validator) | `application_policy: PolicyId` | mint and spend handlers | reads the configuration record by reference; never reads a root or a trie proof |

## Off-chain

| Function | Arguments | Result | Effect |
| --- | --- | --- | --- |
| `stateTokenName` | `seed :: TxIn` | `AssetName` | pure |
| `registrationPreimage` | `key :: ByteString`, `registry :: RegistryIdentity`, `holding :: Address`, `datumHash :: DatumHash`, `deposit :: Lovelace` | `ByteString` | pure |
| `buildGenesis` | `session :: Session`, `application :: PolicyId`, `seed :: TxIn` | a transaction and the registry identity | reads the chain through the session |
| `buildRegistrationFold` | `session :: Session`, `registry :: RegistryIdentity`, `pending :: [TxIn]` | a transaction | reads the state, the pending registrations and the trie through the session |
| `buildConfigurationCreate` | `session :: Session`, `registry :: RegistryIdentity`, `parameters :: RequestParameters` | a transaction | reads the chain through the session |
| `buildBookRegistration` | `session :: Session`, `registry :: RegistryIdentity`, `key :: ByteString`, `payload :: Datum`, `deposit :: Lovelace`, `refund :: Address` | a transaction | reads the configuration record by reference |
| `buildReclaim` | `session :: Session`, `pending :: TxIn` | a transaction | signed by the refund address |
| `buildCleanup` | `session :: Session`, `pending :: TxIn` | a transaction | permissionless |

Where the aligned Lean models or the existing builders fix a different argument set, the mandate is versioned before the
slice that implements the function starts.
