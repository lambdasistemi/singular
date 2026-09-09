# Singular

A permissionless registry on Cardano for unique identities and independent application state.

Singular records whether a key has an outstanding representative NFT or has been permanently retired. The application keeps its state in the UTxO holding that NFT and controls its local transitions. Anyone can submit or fold requests that satisfy the protocol.

| Registry request | Before | After | Representative NFT |
| --- | --- | --- | --- |
| Insert | Absent | `Active` | Mint into the certified application output |
| Update | `Active` | `Over` | Burn; permanently reserve the key |
| Delete | `Active` | Absent | Burn; make the key available again |

`Active` and `Over` contain no application payload. Registry **Update** means retirement, not an application-state update. `Over` is terminal.

The configured application policy ID is the authorization anchor. It mints action tokens whose asset names hash the action and its necessary parameters. Insert approval binds the registry/key, initial application datum and destination. Withdraw approval separately binds the exact pending Insert and its refund requirements; Insert approval alone cannot authorize cancellation.

Insert carries no representative NFT, can fail at folding if its key is occupied, and can be withdrawn with the required authorization. Update/Delete carry the existing representative after the application authorizes its exact release, and retain it until completion. The concrete request-token arrangement for Update/Delete remains open.

Read the design in order:

1. [Responsibilities and terminology](docs/overview.md)
2. [Requests, folding and NFT custody](docs/lifecycle.md)
3. [Certification and identity binding](docs/certification.md)
4. [Naming walkthrough: register, resolve, change address](docs/naming-demo.md)
5. [Prior art and reuse candidates](docs/prior-art.md)
6. [Draft protocol specification and acceptance scenarios](specs/protocol/spec.md)

## Design status

These documents record the adopted design and name the decisions still needed before implementation. This repository contains no application implementation or proofs. Its CI builds and checks the documentation; it does not build or test an application.

Singular uses MPF as its authenticated registry data structure. Existing MPFS is a separate application with potentially reusable mechanics. The implementation stack and shared-library boundaries remain unselected; extracting a shared library is future work.

[Build and serve the documentation](docs/building.md) with the pinned Nix toolchain.
