# Requests, folding and NFT custody

Request creation and folding are separate transactions. Each has its own atomic effects; there is an explicit pending interval between them. Creating a valid request does not guarantee that someone will fold it.

## Mint, move and burn

| Transaction | Request token | Representative NFT |
| --- | --- | --- |
| Create certified Insert request | Mint | None in request; successful fold creates one |
| Fold Insert | Consume request; token disposal to specify | Mint into the certified application output |
| Application update | No registry request needed | Move to the next application UTxO |
| Create authorized Update/Delete request | Mint | Move from the application into the request |
| Fold Update/Delete | Consume request; token disposal to specify | Burn |
| Withdraw Insert | Consume request; token disposal to specify | None minted |

The request token recognizes the native request. The representative NFT carries the identity's unique authority. They are not the same asset.

## Insert: certify first, check absence when folded

The application prepares a proposal identifying the registry, key, initial application state and destination application script/address. The configured application policy approves that exact proposal. Request minting must establish this application approval together with the native format, binding and custody requirements. A correctly formatted Insert without accepted application approval is invalid; it cannot be used to register an arbitrary non-application datum. The application constructs the transaction. Whether its configured policy mints the request token directly or supplies certification checked by a native request minting policy is still open.

The pending Insert request contains a request token but **no representative NFT**. Request creation need not observe the mutable registry state. Certification approves the proposed creation, not a claim that the key will remain absent.

When folded successfully, Insert checks that the key is absent, changes it to `Active`, and mints its representative NFT into the output required by the certified proposal. The native checks must match that output's NFT, destination and initial state to the request. These effects occur together in the folding transaction.

Two Insert requests can target the same key while pending. An Insert whose key is occupied cannot succeed at that point. The design does not yet select whether a batch builder omits such requests or how failure is presented; it does not assume a skip rule inside the validator.

An Insert can be withdrawn without changing the registry or creating a representative. Withdrawal authority, refund destination and disposal of the request token/certificate still need a concrete rule. Permissionless operation is not permission to take someone else's deposit. Even if refunds go to the correct address, allowing arbitrary third parties to cancel valid requests could prevent registration. Cancellation authorization comes from the configured application policy. The exact authorization action, its binding to the pending request and conditions remain unresolved; original Insert approval does not automatically authorize cancellation.

## Application evolution: keep the same representative

While the NFT is in application custody, the application spending validator governs its movement and state changes. An application update can spend one application UTxO and produce its successor with the same NFT. This need not change the registry.

The application can observe its own inputs and transaction context. Avoiding observation of the mutable registry UTxO does not prohibit those checks or the use of authenticated registry configuration.

## Update and Delete: transfer authority into a pending request

To request retirement or removal, the application constructs a transaction that spends its NFT UTxO and places the existing representative into the Singular request output. The output also carries a minted request token recognized by Singular; its issuing-policy arrangement remains open.

The application validator must authorize **that exact release**: the chosen Update or Delete operation, registry/key binding and request destination. Merely being able to spend the NFT does not establish authorization for every operation. Native request admission checks format, binding and custody; it does not repeat arbitrary application validation. No second application attestation token is required merely to repeat the approved release.

These checks need no observation of the mutable registry state when the request is created. The registry remains `Active` during the pending interval, and the NFT remains outstanding in the request. It cannot continue rotating as an application UTxO while held there.

Update/Delete requests are completion-only. There is no ordinary withdrawal, rejection or sweep that releases their representative. Valid folding consumes the request, burns the representative and applies exactly one of these transitions:

| Operation | Registry effect | Consequence |
| --- | --- | --- |
| Update | `Active → Over` | Permanent retirement; no transition leaves `Over` |
| Delete | `Active → Absent` | Key available for a future Insert |

The representative stays in request custody until that completion. Exact request-token disposal is still to be specified; it must not allow a completed request to be accepted again.

## What batching establishes

A fold traverses requests and applies their operations to the successive authenticated map states. Insert absence and Update/Delete old-value checks belong to those native mechanics. Certification and request recognition let the fold check bounded native obligations without repeating the application's full validation at every operation. This is a design objective, not a measured performance result.

One authentic representative cannot be held in two simultaneously pending Update/Delete requests for the same key. Consuming a request UTxO prevents consuming that UTxO again. These facts do not settle authorization replay across Delete followed by a fresh Insert, or all possible conflicts between different keys.

See [certification and the remaining decisions](certification.md).
