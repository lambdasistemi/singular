import NoPin.Identity

namespace NoPin.Statements
open Singular

/-- Hypothesis under #741, not accepted law; complete-identity ruling. Status: STATED. -/
theorem full_approval_inversion (hash : Hash) (code : Codec) (app : Nat) (r : TokenId) (payload : Payload) (supplied : TokenId) :
    (True) →
    (approve .none .full hash code app r payload supplied = true ↔ supplied = approvalAsset .full hash code app r payload) := by
  sorry

/-- Hypothesis under #741, not accepted law; rejected name-only contrast. Status: REJECTED-READING-STATED. -/
theorem name_only_inversion (hash : Hash) (code : Codec) (app : Nat) (r : TokenId) (payload : Payload) (supplied : TokenId) :
    (True) →
    (approve .none .nameOnly hash code app r payload supplied = true ↔ supplied = approvalAsset .nameOnly hash code app r payload) := by
  sorry

/-- Hypothesis under #741, not accepted law; unresolved shared-policy recognition. Status: STATED. -/
theorem policy_only_inversion (hash : Hash) (code : Codec) (r : TokenId) (o : Observation) :
    (True) →
    (recognize .none .policyOnly hash code r .state 0 o = true ↔ o.asset.policy = r.policy ∧ o.stateDatum = true) := by
  sorry

/-- Hypothesis under #741, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. Status: STATED. -/
theorem state_inversion (hash : Hash) (code : Codec) (r : TokenId) (key : Nat) (o : Observation) :
    (True) →
    (recognize .none .authenticated hash code r .state key o = true ↔ o.asset = (roleAsset hash code r .state key) ∧ o.provenance = (roleAsset hash code r .state key) ∧ o.stateDatum = true) := by
  sorry

/-- Hypothesis under #741, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. Status: STATED. -/
theorem witness_inversion (hash : Hash) (code : Codec) (r : TokenId) (key : Nat) (o : Observation) :
    (True) →
    (recognize .none .authenticated hash code r .witness key o = true ↔ o.asset = (roleAsset hash code r .witness key) ∧ o.provenance = (roleAsset hash code r .witness key)) := by
  sorry

/-- Hypothesis under #741, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. Status: STATED. -/
theorem trieReady_inversion (hash : Hash) (code : Codec) (r : TokenId) (key : Nat) (o : Observation) :
    (True) →
    (recognize .none .authenticated hash code r .trieReady key o = true ↔ o.asset = (roleAsset hash code r .trieReady key) ∧ o.provenance = (roleAsset hash code r .trieReady key)) := by
  sorry

/-- Hypothesis under #741, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. Status: STATED. -/
theorem application_inversion (hash : Hash) (code : Codec) (r : TokenId) (key : Nat) (o : Observation) :
    (True) →
    (recognize .none .authenticated hash code r .application key o = true ↔ o.asset = (roleAsset hash code r .application key) ∧ o.provenance = (roleAsset hash code r .application key)) := by
  sorry

/-- Hypothesis under #741, not accepted law; same transaction versus history. Status: STATED. -/
theorem genesis_inversion (tx : TxView) (seed : OutRef) (asset : TokenId) :
    (True) →
    (genesis .none tx seed asset = true ↔ tx.spent.count seed = 1 ∧ asset.policy ∈ tx.invoked ∧ mintQty tx asset = 1 ∧ (tx.outputs.map (fun o => outputQty o asset)).sum = 1 ∧ (tx.outputs.filter (fun o => outputQty o asset == 1)).length = 1) := by
  sorry

/-- Hypothesis under #741, not accepted law; across-history spent-once premise. Status: STATED. -/
theorem history_inversion (history : List TxView) :
    (True) →
    (historyAllows .none history = true ↔ (history.flatMap (·.spent)).Nodup) := by
  sorry

/-- Hypothesis under #741, not accepted law; complete-identity ruling, including equal seed names under different policies. Status: STATED. -/
theorem cross_registry_approval_refused (hash : Hash) (code : Codec) (app : Nat) (a b : TokenId) (payload : Payload) :
    (a ≠ b ∧ finiteEncoding code [Preimage.approval a payload, Preimage.approval b payload] ∧ finiteHash hash code [Preimage.approval a payload, Preimage.approval b payload]) →
    approve .none .full hash code app b payload (approvalAsset .full hash code app a payload) = false := by
  sorry

/-- Hypothesis under #741, not accepted law; rejected name-only safety claim. Status: REJECTED-READING-STATED-EXPECTED-REFUTABLE. -/
theorem name_only_separation_claim (hash : Hash) (code : Codec) (app : Nat) (a b : TokenId) (payload : Payload) :
    (a ≠ b ∧ finiteEncoding code [Preimage.approval { a with policy := 0 } payload, Preimage.approval { b with policy := 0 } payload, Preimage.application app] ∧ finiteHash hash code [Preimage.approval { a with policy := 0 } payload, Preimage.approval { b with policy := 0 } payload, Preimage.application app]) →
    approve .none .nameOnly hash code app b payload (approvalAsset .nameOnly hash code app a payload) = false := by
  sorry

/-- Hypothesis under #741, not accepted law; policy-only recognition of a genuine witness with fabricated state datum. Status: HYPOTHETICAL-READING-STATED-EXPECTED-REFUTABLE. -/
theorem policy_only_excludes_witness (hash : Hash) (code : Codec) (r foreign : TokenId) (key : Nat) (o : Observation) :
    (o.asset = roleAsset hash code foreign .witness key ∧ o.provenance = o.asset ∧ o.asset.name ≠ r.name) →
    recognize .none .policyOnly hash code r .state key o = false := by
  sorry

/-- Hypothesis under #741, not accepted law; same seed once, two application-specific policies in one transaction. Status: STATED. -/
theorem same_transaction_two_applications (hash : Hash) (code : Codec) (releaseA releaseB : Nat) (seed : OutRef) (tx : TxView) :
    (applicationPolicy hash code releaseA ≠ applicationPolicy hash code releaseB ∧ finiteEncoding code [Preimage.statePolicy (applicationPolicy hash code releaseA), Preimage.statePolicy (applicationPolicy hash code releaseB)] ∧ finiteHash hash code [Preimage.statePolicy (applicationPolicy hash code releaseA), Preimage.statePolicy (applicationPolicy hash code releaseB)] ∧ genesis .none tx seed (registry hash code releaseA seed) = true ∧ genesis .none tx seed (registry hash code releaseB seed) = true) →
    (registry hash code releaseA seed).name = (registry hash code releaseB seed).name ∧ (registry hash code releaseA seed) ≠ (registry hash code releaseB seed) ∧ tx.spent.count seed = 1 := by
  sorry

/-- Hypothesis under #741, not accepted law; across-history repeated seed, separate from same-transaction genesis. Status: STATED. -/
theorem history_reuse_refused (history : List TxView) (seed : OutRef) :
    (1 < (history.flatMap (·.spent)).count seed) →
    historyAllows .none history = false := by
  sorry

end NoPin.Statements

namespace NoPin.Statements
open Singular

/-- Hypothesis under #741, not accepted law; unresolved shared-policy recognition.
Finite encoding/hash premises separate seed and role preimages; provenance validity
is still supplied evidence. Request tags here omit economic payload and nonce. Status: STATED. -/
theorem authenticated_state_role_separation (hash : Hash) (code : Codec)
    (r : TokenId) (seed : OutRef) (role : Role) (key : Nat) :
    (role ≠ .state ∧ r.name = stateName hash code seed ∧
      finiteEncoding code [.seed seed, .role role r key] ∧
      finiteHash hash code [.seed seed, .role role r key]) →
    (recognize .none .authenticated hash code r .state key ⟨r, true, r⟩ = true ∧
      recognize .none .authenticated hash code r .state key
        ⟨roleAsset hash code r role key, true, roleAsset hash code r role key⟩ = false) := by
  sorry

end NoPin.Statements
