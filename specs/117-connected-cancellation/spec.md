As a naming user, I register a name, receive its real pending Insert claim/request, then cancel before fold and recover the refund committed by that request. The current InsertApproval cannot pass the application's cancellation path. This repairs the existing connected cancellation acceptance of #114.

Accepted baseline: f558d0e8fc916eef494fffcef09cfe2ac5582b8e. Original probe is bound to fc2ad9e5987b171ca33a430f5bbe170ab6423fd5. `setupNamingClaim` uses `Naming.Register.insertApprovalName(control, commitment)`, a 32-byte hash, while `application.cancel` compares that token name with the refund and decodes it as a canonical 29/57-byte address. The four-field naming datum carries no refund. A four-test Aiken context probe reports existing WithdrawApproval cancellation and real Insert mint passing, Insert cancellation with the actual refund or approval hash failing. This is constructed-context evidence, not a node receipt.

Lean authority: `Singular.NamingLifecycle.cancelNamingClaim`, `cancellationAsset`, and generic `Singular.step` withdrawal at the exact accepted baseline. The queued Insert proposal's `refundAddress` must govern cancellation. Any new token/refund association or authorization choice requires an exact operator/model ruling before affected implementation. Prior generic retraction or separately minted WithdrawApproval fixtures do not establish the connected route.

Acceptance command to ship and run in CI from the repository root:

```
nix run ./offchain#connected-cancellation
```

This new dedicated command must start its own isolated devnet and exercise the production register/cancellation builders. It is implemented; complete repaired real-node acceptance remains required. Exit 0 requires:

- CC01: create a genuine pending Insert claim and associated generic request, cancel before fold, observe the claim and approval consumed, refund at the request's committed address, and the exact generic request disposition; no representative mint and no Active entry.
- CC02: redirected refund refuses at the application/ledger boundary.
- CC03: replay refuses because the original consumed inputs are unavailable.
- CC04: an already-folded claim cannot be cancelled; preserve the connected successful fold as its positive control.
- CC05: cancellation of a retirement Update request refuses at the corresponding actual boundary.
- CC06: preserve the existing WithdrawApproval cancellation positive control.

Retain baseline failing and repaired node observations with candidate, command, exit status, script/transaction identities and logs. Keep component Aiken results separate. Expose a production cancellation builder for #114 to consume after landing, with an early interface handoff.

Scope: minimal naming application/register representation, offchain builder, focused tests and CI required to restore the accepted cancellation story after any necessary ruling. Preserve the existing generic request lifecycle. Coordinate overlapping validator/register paths with #110/PR112; integrate accepted #110 before final acceptance. No use of unmerged sibling code as accepted authority.

Excludes economic deposits, Lean deposit work, deployment prices, CLI wrapper, follower/folder implementation, unrelated validator changes and new deployment. Use isolated devnet only; shared preprod identities and writes remain governed by existing single-writer ownership.

A-003 through A-006 rulings and exact two-transition/certificate mapping are recorded in [decisions.md](decisions.md). The old Insert-only baseline refusal is expected under the preserved theorem. CC07/CC08 additionally require actual application refusal when distinct withdrawal issuance or its issuer authorization is absent. Accepted #110 merge b4a36eaf72d8a355d9048a00081a8f999c195e27 is integrated.
