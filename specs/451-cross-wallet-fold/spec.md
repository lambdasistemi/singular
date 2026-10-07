# Recover another wallet's fold

As a registry operator, I want the cross-wallet recovery check to run on its own, so that a passing job demonstrates recovery rather than depending on another check's setup.

## User stories

A requester books an insertion. Another funded wallet folds it in the same registry directory. If that process stops at a declared hold or loses its submission answer, the requester's next ordinary write reconciles the fold once and proceeds. The job reads receipts, saved transaction bodies, the journal and public lineage to judge the result. If a command fails before the intended boundary, its own receipt and refusal reason remain visible.

```mermaid
sequenceDiagram
    participant Requester as Owner
    participant Folder
    participant Ledger
    Requester->>Ledger: Establish the part's starting state
    Requester->>Ledger: Book an insertion
    Folder->>Ledger: Fold the request
    Note over Folder: Stop at the selected hold
    Requester->>Ledger: Reconcile with the next write
    Ledger-->>Requester: Observe inclusion once
```

The sequence shows one connected journey on a private development ledger. The selected part establishes the prerequisite holding itself before testing an interrupted fold.

## Requirements

| Requirement | Meaning | Severity |
|---|---|---|
| selected-part-starting-state | Selecting only cross-wallet establishes every holding needed by its next ordinary write through real CLI commands. | BLOCKING |
| cross-wallet-recovery | Every discovered fold hold and the lost-answer case retain the existing receipt, journal, root, signer-witness and no-resubmission expectations. | BLOCKING |
| failed-command-visible | A failed command prints its actual receipt and refusal reason without replacing the command's outcome or the job's failure. | ADVISORY |
| hosted-selected-part | A distinct cross-wallet app and Registry job select that part and reject absent or empty execution through the existing ran-proof. | BLOCKING |

## Model and limits

The behavioral authority is Lean at commit 0676e5354353b823b40b9cad5cac31a170a8fd08: Singular.Request, Singular.refusal, Singular.step and Singular.txOf in lean/Singular/Model.lean, and Singular.Statements.fold_requires_no_signer in lean/Singular/Statements.lean. A fold requires no owner or folder signer; a funded wallet's payment-key witness is distinct from a transaction's required-signers field. This change adds no signer, refusal, deadline or model rule.

The historical fold exit 10 remains unreproduced and unidentified. The observed missing-key defect concerns the next update, and is not presented as the cause of that historical fold refusal. Both wallets use one registry directory here; this check establishes no public-only fold from a separate directory. Consumer conformance remains receipt-derived and its uncovered rows do not change.
