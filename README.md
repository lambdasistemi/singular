# Singular

A permissionless registry on Cardano for unique identities and independent application state.

## Design status

Singular is in early design. This repository contains no application implementation or proofs. Its CI is a bootstrap stub and does not build or test an application.

The registry design uses MPF as its shared data structure. The application stack and shared-library boundaries remain unselected; extracting a shared library is future work.

## Registry lifecycle

Each registry key is absent, `Active`, or `Over`. The adopted transitions are:

| Request | Before | After | Identity NFT | Key reuse |
| --- | --- | --- | --- | --- |
| Insert | Absent | `Active` | Mint | The key becomes registered |
| Update | `Active` | `Over` | Burn | Permanently retired |
| Delete | `Active` | Absent | Burn | Available for registration again |

An `Active` entry means its unique representative NFT is outstanding, either in application custody or in a pending request. Application state evolves independently of the registry. `Active` does not imply that an application is usable or unpaused. An `Over` entry records permanent retirement and has no live identity NFT. Registry Update is the retirement transition; it is distinct from application-state updates.

The registry has no native owner or actor permission gate. Requests must still satisfy validity rules and NFT custody requirements.
