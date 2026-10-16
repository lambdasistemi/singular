import CardanoLedger.Transaction

/-! Named hypotheses about an observed ledger, never hidden laws of the types. -/

namespace CardanoLedger

def CollisionFreeOn (hash : α → β) (occurs : α → Prop) : Prop :=
  ∀ a, occurs a → ∀ b, occurs b → hash a = hash b → a = b

def Ledger.RunsScripts (ledger : Ledger D R S) : Prop :=
  ∀ tx, ledger.accepts tx → ∀ purpose hash,
    (purpose, hash) ∈ tx.invocations →
    ∃ redeemer script, tx.redeemerOf purpose = some redeemer ∧
      script ∈ tx.scripts ∧ ledger.hash script = hash ∧
      ledger.evaluate script ⟨purpose, redeemer, tx⟩ = true

def Ledger.KeepsNamesWithinLimit (ledger : Ledger D R S) : Prop :=
  ∀ tx, ledger.accepts tx →
    (∀ entry ∈ tx.mint, entry.2 ≠ 0 → AssetName.valid entry.1.name) ∧
    (∀ output ∈ tx.outputs, ∀ entry ∈ output.value.assets,
      entry.2 ≠ 0 → AssetName.valid entry.1.name)

end CardanoLedger
