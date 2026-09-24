# Module ownership

As a contributor, I expect the lint entry point to cover the source directories
that own active Haskell components, while the Cabal package keeps the same
library and commands.

```mermaid
flowchart LR
    A[Cabal declaration] -->|declares| B[Library and executables]
    A -->|lists directories| C[Active source inventory]
    C -->|feeds| D[Lint command]
    B -->|retains| E[Exports and command names]
```

| ID | Owner | Changed responsibility |
| --- | --- | --- |
| M264-1 | `offchain/singular-registry.cabal` | Declare each library dependency once; retain component names, source directories and exposed modules. |
| M264-2 | `offchain/nix/checks.nix` | Discover active Haskell source extent for the existing lint app and state exclusions. |

No new Haskell module, dependency direction, facade, or runtime owner is
introduced by this slice.
