# Singular

A permissionless registry on Cardano for unique identities and independent application state.

Singular records whether a key has an outstanding representative NFT or has been permanently retired. The application keeps its state in the UTxO holding that NFT and controls its local transitions. Anyone can submit or fold requests that satisfy the protocol.

| Registry request | Before | After | Representative NFT |
| --- | --- | --- | --- |
| Insert | Absent | `Active` | Mint into the certified application output |
| Update | `Active` | `Over` | Burn; permanently reserve the key |
| Delete | `Active` | Absent | Burn; make the key available again |

`Active` and `Over` contain no application payload. Registry **Update** means retirement, not an application-state update. `Over` is terminal.

Requests carry a token issued by Singular's request policy. Update and Delete also carry the existing representative NFT: the application authorizes its transfer into the exact request, which then awaits completion. Insert has no representative NFT yet. Minting its request token requires accepted application certification of the proposed initial state and destination. Insert can fail at folding if its key is occupied, and can be withdrawn.

Read the design in order:

1. [Responsibilities and terminology](docs/overview.md)
2. [Requests, folding and NFT custody](docs/lifecycle.md)
3. [Certification and identity binding](docs/certification.md)
4. [Draft protocol specification and acceptance scenarios](specs/protocol/spec.md)

## Design status

These documents record the adopted design and name the decisions still needed before implementation. This repository contains no application implementation or proofs. Its CI is a bootstrap stub and does not build or test an application.

Singular uses MPF as its authenticated registry data structure. Existing MPFS is a separate application with potentially reusable mechanics. The implementation stack and shared-library boundaries remain unselected; extracting a shared library is future work.
