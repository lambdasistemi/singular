import OpenDatumApplicationHeld.MoneyClaims


namespace OpenDatumApplicationHeld.Money
open Singular Lean SingularApplicationHeld


inductive HoldingPaymentMutation where
  | none | includeHolding
  deriving BEq, DecidableEq


def holdingSeparatedPayment (m : HoldingPaymentMutation) (outputs : List ObservedOutput)
    (address : Nat) (active : TokenId) : Nat :=
  paidTo (outputs.filter fun output =>
    m == .includeHolding || quantity output active == 0) address


abbrev HoldingSeparatedFoldOutcome (m : HoldingPaymentMutation) (h : Hash) (c : Codec)
    (t : TrieCommit) (q : Input) : Prop :=
  let built := builtFor h c t .registrationFold q
  fold .none h c t q.lifecycle.query.release built = true ∧
  batchEffects t built ∧ built.donation = 0 ∧ built.signers = [] ∧
  (trieGet built.after.trie q.registration.key = .known .active ∧
    SingularApplicationHeld.Assets.mintQty built.assets (activeAsset h c q.registration.registry q.registration.key) = 1) ∧
  holdingSeparatedPayment m built.outputs q.lifecycle.query.funding.processorAddress
      (activeAsset h c q.registration.registry q.registration.key) =
    (newAllocation .none .registrationFold q).folder + q.lifecycle.query.funding.ordinaryInput.lovelace -
      q.lifecycle.query.funding.fee


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

end OpenDatumApplicationHeld.Money
