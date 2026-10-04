# Node module ownership

As a contributor, I need a directed owner graph, so I can change shared node
behavior without creating a second copy of state or a cycle.

```mermaid
flowchart TD
    Facade[Singular.Registry.Node public facade] --> O[Node.Options]
    Facade --> W[Node.Wallet]
    Facade --> I[Node.Indexer]
    Facade --> F[Node.Funding]
    Facade --> S[Node.Session]
    Facade --> C[Node.Confirmation]
    O --> W
    W --> I
    W --> F
    I --> S
    F --> S
    S --> C
    I --> C
```

## Responsibilities

| ID | Owner | Responsibility and direction |
| --- | --- | --- |
| parse-mode-flags-environment-own-one-time | `Node.Options` | Parse mode flags and environment, own the one-time process mode and mode-specific diagnostics. No dependency on runtime modules. |
| parse-signing-keys-derive-addresses-own-one | `Node.Wallet` | Parse signing keys, derive addresses, own the one-time process wallet and expose the original funding identity through the facade. Depends on options. |
| own-follower-state-genesis-sweep-state-provider | `Node.Indexer` | Own follower state, genesis sweep state, provider address-read guard and counter; follow a chain and answer indexed reads. Depends on wallet and options. |
| own-funding-floor-checks-their-existing-diagnostics | `Node.Funding` | Own funding floor checks and their existing diagnostics. Depends on wallet presentation. |
| own-open-session-state-node-client-connection | `Node.Session` | Own open session state, node client connection, protocol parameters, mode-specific setup and bracketed lifecycle. Depends on options, wallet, indexer and funding. |
| own-waits-deadlines-chain-observation-reads-session | `Node.Confirmation` | Own waits, deadlines and chain observation. Reads the session and follower through their owners; neither owner imports confirmation. |
| compatibility-facade-retaining-its-exact-public-export | `Singular.Registry.Node` | Compatibility facade retaining its exact public export list and old caller imports. It owns no copied global. |

The owner may choose a smaller acyclic graph when the actual type dependencies
require it, but must version this plan before changing a listed owner or adding
a module. Each moved declaration gets exactly one before and after entry.
