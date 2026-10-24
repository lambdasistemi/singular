import NoPin.ApplicationRequests.MoneyClaims

/-! Hypothetical registration-money correction: the holding's deposit and the
ordinary residual payment are separate even at the same address. -/
namespace NoPin.ApplicationRequests.Money
open Singular Lean

/-- Hypothesis under #741, not accepted law; one guard can include the holding incorrectly. -/
inductive HoldingPaymentMutation where
  | none | includeHolding
  deriving BEq, DecidableEq

/-- Hypothesis under #741, not accepted law; credit only outputs without the newly active asset. -/
def holdingSeparatedPayment (m : HoldingPaymentMutation) (outputs : List ObservedOutput)
    (address : Nat) (active : TokenId) : Nat :=
  paidTo (outputs.filter fun output =>
    m == .includeHolding || quantity output active == 0) address

/-- Hypothesis under #741, not accepted law; the original fold outcome with only its payment observation corrected. -/
abbrev HoldingSeparatedFoldOutcome (m : HoldingPaymentMutation) (h : Hash) (c : Codec)
    (t : TrieCommit) (q : Input) : Prop :=
  let built := builtFor h c t .registrationFold q
  fold .none h c t q.lifecycle.query.release built = true ∧
  batchEffects t built ∧ built.donation = 0 ∧ built.signers = [] ∧
  (trieGet built.after.trie q.registration.key = .known .active ∧
    NoPin.mintQty built.assets (activeAsset h c q.registration.registry q.registration.key) = 1) ∧
  holdingSeparatedPayment m built.outputs q.lifecycle.query.funding.processorAddress
      (activeAsset h c q.registration.registry q.registration.key) =
    (newAllocation .none .registrationFold q).folder + q.lifecycle.query.funding.ordinaryInput.lovelace -
      q.lifecycle.query.funding.fee

/-- Hypothesis under #741, not accepted law; every original registration conjunct is retained. -/
abbrev HoldingSeparatedClaim (m : HoldingPaymentMutation) (h : Hash) (c : Codec)
    (t : TrieCommit) (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Prop :=
  RefundApplication.applicationStep (appMutation .none) h c decode release q.lifecycle.observation = true ∧
  RefundLifecycle.registrationEffects h c decode q.lifecycle.observation = true ∧
  RefundLifecycle.terminationEffects h c q.lifecycle.observation = true ∧
  RefundLifecycle.paymentEffects decode q.lifecycle.observation = true ∧
  RefundLifecycle.treasuryEffect decode q.lifecycle.observation = true ∧
  updateEffect decode q.lifecycle.observation = true ∧
  actualMoneyEffect .registrationFold q = true ∧
  AllDifferences .none .registrationFold q ∧
  HoldingSeparatedFoldOutcome m h c t q ∧ True ∧ True

end NoPin.ApplicationRequests.Money
