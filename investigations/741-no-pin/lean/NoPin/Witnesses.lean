import NoPin.Identity

namespace NoPin.Fixtures
open Singular

/-- Hypothesis fixture under #741, not accepted law; finite hash question. Not cryptographic. -/
def demoHash (xs : List Nat) : Nat := xs.foldl (fun a b => a * 37 + b + 1) 0
/-- Hypothesis fixture under #741, not accepted law; same-seed identity question. -/
def seed : OutRef := ⟨11, 2⟩
/-- Hypothesis fixture under #741, not accepted law; complete-identity ruling. -/
def regA : TokenId := ⟨10, 20⟩
/-- Hypothesis fixture under #741, not accepted law; same name, different policy. -/
def regB : TokenId := ⟨12, 20⟩
/-- Hypothesis fixture under #741, not accepted law; different name contrast. -/
def regC : TokenId := ⟨10, 21⟩
/-- Hypothesis fixture under #741, not accepted law; full approval tuple. -/
def payload : Payload := ⟨1, 7, 42, 99, 3⟩
/-- Hypothesis fixture under #741, not accepted law; supplied origin evidence. -/
def observation (asset : TokenId) : Observation := ⟨asset, true, asset⟩
/-- Hypothesis fixture under #741, not accepted law; abstract transaction, no ledger validity. -/
def genesisView (spent : List OutRef) (assets : List TokenId) : TxView :=
  ⟨spent, assets.map (fun a => ⟨[(a, 1)]⟩), assets.map (fun a => (a, 1)), assets.map (·.policy)⟩
/-- Hypothesis fixture under #741, not accepted law; acyclic identity. -/
def derivedA : TokenId := registry demoHash encode 1 seed
/-- Hypothesis fixture under #741, not accepted law; acyclic identity. -/
def derivedB : TokenId := registry demoHash encode 2 seed

/-- Hypothesis instance under #741, not accepted law; complete-identity ruling. -/
abbrev full_approval_inversion_premise (m : Mutation) (hash : Hash) (code : Codec) (app : Nat) (r : TokenId) (payload : Payload) (supplied : TokenId) : Prop :=
  True
/-- Hypothesis instance under #741, not accepted law; complete-identity ruling. -/
abbrev full_approval_inversion_claim (m : Mutation) (hash : Hash) (code : Codec) (app : Nat) (r : TokenId) (payload : Payload) (supplied : TokenId) : Prop :=
  (approve m .full hash code app r payload supplied = true ↔ supplied = approvalAsset .full hash code app r payload)
/-- Executed antecedent instance of the #741 hypothesis, not accepted law; complete-identity ruling. -/
theorem full_approval_inversion_antecedent : full_approval_inversion_premise .none demoHash encode 5 regA payload (approvalAsset .full demoHash encode 5 regA payload) := by
  decide +kernel

/-- Executed candidate instance of the #741 hypothesis, not accepted law; complete-identity ruling. -/
theorem full_approval_inversion_approvalFull_candidate :
    full_approval_inversion_premise .none demoHash encode 5 regA payload (approvalAsset .full demoHash encode 5 regA payload) →
    full_approval_inversion_claim .none demoHash encode 5 regA payload (approvalAsset .full demoHash encode 5 regA payload) := by
  decide +kernel

/-- Hypothesis instance under #741, not accepted law; rejected name-only contrast. -/
abbrev name_only_inversion_premise (m : Mutation) (hash : Hash) (code : Codec) (app : Nat) (r : TokenId) (payload : Payload) (supplied : TokenId) : Prop :=
  True
/-- Hypothesis instance under #741, not accepted law; rejected name-only contrast. -/
abbrev name_only_inversion_claim (m : Mutation) (hash : Hash) (code : Codec) (app : Nat) (r : TokenId) (payload : Payload) (supplied : TokenId) : Prop :=
  (approve m .nameOnly hash code app r payload supplied = true ↔ supplied = approvalAsset .nameOnly hash code app r payload)
/-- Executed antecedent instance of the #741 hypothesis, not accepted law; rejected name-only contrast. -/
theorem name_only_inversion_antecedent : name_only_inversion_premise .none demoHash encode 5 regA payload (approvalAsset .nameOnly demoHash encode 5 regA payload) := by
  decide +kernel

/-- Executed candidate instance of the #741 hypothesis, not accepted law; rejected name-only contrast. -/
theorem name_only_inversion_approvalNameOnly_candidate :
    name_only_inversion_premise .none demoHash encode 5 regA payload (approvalAsset .nameOnly demoHash encode 5 regA payload) →
    name_only_inversion_claim .none demoHash encode 5 regA payload (approvalAsset .nameOnly demoHash encode 5 regA payload) := by
  decide +kernel

/-- Hypothesis instance under #741, not accepted law; unresolved shared-policy recognition. -/
abbrev policy_only_inversion_premise (m : Mutation) (hash : Hash) (code : Codec) (r : TokenId) (o : Observation) : Prop :=
  True
/-- Hypothesis instance under #741, not accepted law; unresolved shared-policy recognition. -/
abbrev policy_only_inversion_claim (m : Mutation) (hash : Hash) (code : Codec) (r : TokenId) (o : Observation) : Prop :=
  (recognize m .policyOnly hash code r .state 0 o = true ↔ o.asset.policy = r.policy ∧ o.stateDatum = true)
/-- Executed antecedent instance of the #741 hypothesis, not accepted law; unresolved shared-policy recognition. -/
theorem policy_only_inversion_antecedent : policy_only_inversion_premise .none demoHash encode regA (observation regA) := by
  decide +kernel

/-- Executed candidate instance of the #741 hypothesis, not accepted law; unresolved shared-policy recognition. -/
theorem policy_only_inversion_policyOnlyPolicy_candidate :
    policy_only_inversion_premise .none demoHash encode regA (observation regA) →
    policy_only_inversion_claim .none demoHash encode regA (observation regA) := by
  decide +kernel

/-- Executed candidate instance of the #741 hypothesis, not accepted law; unresolved shared-policy recognition. -/
theorem policy_only_inversion_policyOnlyDatum_candidate :
    policy_only_inversion_premise .none demoHash encode regA (observation regA) →
    policy_only_inversion_claim .none demoHash encode regA (observation regA) := by
  decide +kernel

/-- Hypothesis instance under #741, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
abbrev state_inversion_premise (m : Mutation) (hash : Hash) (code : Codec) (r : TokenId) (key : Nat) (o : Observation) : Prop :=
  True
/-- Hypothesis instance under #741, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
abbrev state_inversion_claim (m : Mutation) (hash : Hash) (code : Codec) (r : TokenId) (key : Nat) (o : Observation) : Prop :=
  (recognize m .authenticated hash code r .state key o = true ↔ o.asset = (roleAsset hash code r .state key) ∧ o.provenance = (roleAsset hash code r .state key) ∧ o.stateDatum = true)
/-- Executed antecedent instance of the #741 hypothesis, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
theorem state_inversion_antecedent : state_inversion_premise .none demoHash encode regA 7 (observation (roleAsset demoHash encode regA .state 7)) := by
  decide +kernel

/-- Executed candidate instance of the #741 hypothesis, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
theorem state_inversion_statePolicy_candidate :
    state_inversion_premise .none demoHash encode regA 7 (observation (roleAsset demoHash encode regA .state 7)) →
    state_inversion_claim .none demoHash encode regA 7 (observation (roleAsset demoHash encode regA .state 7)) := by
  decide +kernel

/-- Executed candidate instance of the #741 hypothesis, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
theorem state_inversion_stateName_candidate :
    state_inversion_premise .none demoHash encode regA 7 (observation (roleAsset demoHash encode regA .state 7)) →
    state_inversion_claim .none demoHash encode regA 7 (observation (roleAsset demoHash encode regA .state 7)) := by
  decide +kernel

/-- Executed candidate instance of the #741 hypothesis, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
theorem state_inversion_stateProvenance_candidate :
    state_inversion_premise .none demoHash encode regA 7 (observation (roleAsset demoHash encode regA .state 7)) →
    state_inversion_claim .none demoHash encode regA 7 (observation (roleAsset demoHash encode regA .state 7)) := by
  decide +kernel

/-- Executed candidate instance of the #741 hypothesis, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
theorem state_inversion_stateDatum_candidate :
    state_inversion_premise .none demoHash encode regA 7 (observation (roleAsset demoHash encode regA .state 7)) →
    state_inversion_claim .none demoHash encode regA 7 (observation (roleAsset demoHash encode regA .state 7)) := by
  decide +kernel

/-- Hypothesis instance under #741, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
abbrev witness_inversion_premise (m : Mutation) (hash : Hash) (code : Codec) (r : TokenId) (key : Nat) (o : Observation) : Prop :=
  True
/-- Hypothesis instance under #741, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
abbrev witness_inversion_claim (m : Mutation) (hash : Hash) (code : Codec) (r : TokenId) (key : Nat) (o : Observation) : Prop :=
  (recognize m .authenticated hash code r .witness key o = true ↔ o.asset = (roleAsset hash code r .witness key) ∧ o.provenance = (roleAsset hash code r .witness key))
/-- Executed antecedent instance of the #741 hypothesis, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
theorem witness_inversion_antecedent : witness_inversion_premise .none demoHash encode regA 7 (observation (roleAsset demoHash encode regA .witness 7)) := by
  decide +kernel

/-- Executed candidate instance of the #741 hypothesis, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
theorem witness_inversion_witnessPolicy_candidate :
    witness_inversion_premise .none demoHash encode regA 7 (observation (roleAsset demoHash encode regA .witness 7)) →
    witness_inversion_claim .none demoHash encode regA 7 (observation (roleAsset demoHash encode regA .witness 7)) := by
  decide +kernel

/-- Executed candidate instance of the #741 hypothesis, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
theorem witness_inversion_witnessName_candidate :
    witness_inversion_premise .none demoHash encode regA 7 (observation (roleAsset demoHash encode regA .witness 7)) →
    witness_inversion_claim .none demoHash encode regA 7 (observation (roleAsset demoHash encode regA .witness 7)) := by
  decide +kernel

/-- Executed candidate instance of the #741 hypothesis, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
theorem witness_inversion_witnessProvenance_candidate :
    witness_inversion_premise .none demoHash encode regA 7 (observation (roleAsset demoHash encode regA .witness 7)) →
    witness_inversion_claim .none demoHash encode regA 7 (observation (roleAsset demoHash encode regA .witness 7)) := by
  decide +kernel

/-- Hypothesis instance under #741, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
abbrev trieReady_inversion_premise (m : Mutation) (hash : Hash) (code : Codec) (r : TokenId) (key : Nat) (o : Observation) : Prop :=
  True
/-- Hypothesis instance under #741, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
abbrev trieReady_inversion_claim (m : Mutation) (hash : Hash) (code : Codec) (r : TokenId) (key : Nat) (o : Observation) : Prop :=
  (recognize m .authenticated hash code r .trieReady key o = true ↔ o.asset = (roleAsset hash code r .trieReady key) ∧ o.provenance = (roleAsset hash code r .trieReady key))
/-- Executed antecedent instance of the #741 hypothesis, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
theorem trieReady_inversion_antecedent : trieReady_inversion_premise .none demoHash encode regA 7 (observation (roleAsset demoHash encode regA .trieReady 7)) := by
  decide +kernel

/-- Executed candidate instance of the #741 hypothesis, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
theorem trieReady_inversion_trieReadyPolicy_candidate :
    trieReady_inversion_premise .none demoHash encode regA 7 (observation (roleAsset demoHash encode regA .trieReady 7)) →
    trieReady_inversion_claim .none demoHash encode regA 7 (observation (roleAsset demoHash encode regA .trieReady 7)) := by
  decide +kernel

/-- Executed candidate instance of the #741 hypothesis, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
theorem trieReady_inversion_trieReadyName_candidate :
    trieReady_inversion_premise .none demoHash encode regA 7 (observation (roleAsset demoHash encode regA .trieReady 7)) →
    trieReady_inversion_claim .none demoHash encode regA 7 (observation (roleAsset demoHash encode regA .trieReady 7)) := by
  decide +kernel

/-- Executed candidate instance of the #741 hypothesis, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
theorem trieReady_inversion_trieReadyProvenance_candidate :
    trieReady_inversion_premise .none demoHash encode regA 7 (observation (roleAsset demoHash encode regA .trieReady 7)) →
    trieReady_inversion_claim .none demoHash encode regA 7 (observation (roleAsset demoHash encode regA .trieReady 7)) := by
  decide +kernel

/-- Hypothesis instance under #741, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
abbrev application_inversion_premise (m : Mutation) (hash : Hash) (code : Codec) (r : TokenId) (key : Nat) (o : Observation) : Prop :=
  True
/-- Hypothesis instance under #741, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
abbrev application_inversion_claim (m : Mutation) (hash : Hash) (code : Codec) (r : TokenId) (key : Nat) (o : Observation) : Prop :=
  (recognize m .authenticated hash code r .application key o = true ↔ o.asset = (roleAsset hash code r .application key) ∧ o.provenance = (roleAsset hash code r .application key))
/-- Executed antecedent instance of the #741 hypothesis, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
theorem application_inversion_antecedent : application_inversion_premise .none demoHash encode regA 7 (observation (roleAsset demoHash encode regA .application 7)) := by
  decide +kernel

/-- Executed candidate instance of the #741 hypothesis, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
theorem application_inversion_applicationPolicy_candidate :
    application_inversion_premise .none demoHash encode regA 7 (observation (roleAsset demoHash encode regA .application 7)) →
    application_inversion_claim .none demoHash encode regA 7 (observation (roleAsset demoHash encode regA .application 7)) := by
  decide +kernel

/-- Executed candidate instance of the #741 hypothesis, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
theorem application_inversion_applicationName_candidate :
    application_inversion_premise .none demoHash encode regA 7 (observation (roleAsset demoHash encode regA .application 7)) →
    application_inversion_claim .none demoHash encode regA 7 (observation (roleAsset demoHash encode regA .application 7)) := by
  decide +kernel

/-- Executed candidate instance of the #741 hypothesis, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
theorem application_inversion_applicationProvenance_candidate :
    application_inversion_premise .none demoHash encode regA 7 (observation (roleAsset demoHash encode regA .application 7)) →
    application_inversion_claim .none demoHash encode regA 7 (observation (roleAsset demoHash encode regA .application 7)) := by
  decide +kernel

/-- Hypothesis instance under #741, not accepted law; same transaction versus history. -/
abbrev genesis_inversion_premise (m : Mutation) (tx : TxView) (seed : OutRef) (asset : TokenId) : Prop :=
  True
/-- Hypothesis instance under #741, not accepted law; same transaction versus history. -/
abbrev genesis_inversion_claim (m : Mutation) (tx : TxView) (seed : OutRef) (asset : TokenId) : Prop :=
  (genesis m tx seed asset = true ↔ tx.spent.count seed = 1 ∧ asset.policy ∈ tx.invoked ∧ mintQty tx asset = 1 ∧ (tx.outputs.map (fun o => outputQty o asset)).sum = 1 ∧ (tx.outputs.filter (fun o => outputQty o asset == 1)).length = 1)
/-- Executed antecedent instance of the #741 hypothesis, not accepted law; same transaction versus history. -/
theorem genesis_inversion_antecedent : genesis_inversion_premise .none (genesisView [seed] [regA]) seed regA := by
  decide +kernel

/-- Executed candidate instance of the #741 hypothesis, not accepted law; same transaction versus history. -/
theorem genesis_inversion_genesisSeed_candidate :
    genesis_inversion_premise .none (genesisView [seed] [regA]) seed regA →
    genesis_inversion_claim .none (genesisView [seed] [regA]) seed regA := by
  decide +kernel

/-- Executed candidate instance of the #741 hypothesis, not accepted law; same transaction versus history. -/
theorem genesis_inversion_genesisInvocation_candidate :
    genesis_inversion_premise .none (genesisView [seed] [regA]) seed regA →
    genesis_inversion_claim .none (genesisView [seed] [regA]) seed regA := by
  decide +kernel

/-- Executed candidate instance of the #741 hypothesis, not accepted law; same transaction versus history. -/
theorem genesis_inversion_genesisMint_candidate :
    genesis_inversion_premise .none (genesisView [seed] [regA]) seed regA →
    genesis_inversion_claim .none (genesisView [seed] [regA]) seed regA := by
  decide +kernel

/-- Executed candidate instance of the #741 hypothesis, not accepted law; same transaction versus history. -/
theorem genesis_inversion_genesisQuantity_candidate :
    genesis_inversion_premise .none (genesisView [seed] [regA]) seed regA →
    genesis_inversion_claim .none (genesisView [seed] [regA]) seed regA := by
  decide +kernel

/-- Executed candidate instance of the #741 hypothesis, not accepted law; same transaction versus history. -/
theorem genesis_inversion_genesisOutput_candidate :
    genesis_inversion_premise .none (genesisView [seed] [regA]) seed regA →
    genesis_inversion_claim .none (genesisView [seed] [regA]) seed regA := by
  decide +kernel

/-- Hypothesis instance under #741, not accepted law; across-history spent-once premise. -/
abbrev history_inversion_premise (m : Mutation) (history : List TxView) : Prop :=
  True
/-- Hypothesis instance under #741, not accepted law; across-history spent-once premise. -/
abbrev history_inversion_claim (m : Mutation) (history : List TxView) : Prop :=
  (historyAllows m history = true ↔ (history.flatMap (·.spent)).Nodup)
/-- Executed antecedent instance of the #741 hypothesis, not accepted law; across-history spent-once premise. -/
theorem history_inversion_antecedent : history_inversion_premise .none [genesisView [seed] [regA]] := by
  decide +kernel

/-- Executed candidate instance of the #741 hypothesis, not accepted law; across-history spent-once premise. -/
theorem history_inversion_historySpentOnce_candidate :
    history_inversion_premise .none [genesisView [seed] [regA]] →
    history_inversion_claim .none [genesisView [seed] [regA]] := by
  decide +kernel

/-- Hypothesis instance under #741, not accepted law; complete-identity ruling, including equal seed names under different policies. -/
abbrev cross_registry_approval_refused_premise (m : Mutation) (hash : Hash) (code : Codec) (app : Nat) (a b : TokenId) (payload : Payload) : Prop :=
  a ≠ b ∧ finiteEncoding code [Preimage.approval a payload, Preimage.approval b payload] ∧ finiteHash hash code [Preimage.approval a payload, Preimage.approval b payload]
/-- Hypothesis instance under #741, not accepted law; complete-identity ruling, including equal seed names under different policies. -/
abbrev cross_registry_approval_refused_claim (m : Mutation) (hash : Hash) (code : Codec) (app : Nat) (a b : TokenId) (payload : Payload) : Prop :=
  approve m .full hash code app b payload (approvalAsset .full hash code app a payload) = false
/-- Executed antecedent instance of the #741 hypothesis, not accepted law; complete-identity ruling, including equal seed names under different policies. -/
theorem cross_registry_approval_refused_antecedent : cross_registry_approval_refused_premise .none demoHash encode 5 regA regB payload := by
  decide +kernel

/-- Executed candidate instance of the #741 hypothesis, not accepted law; complete-identity ruling, including equal seed names under different policies. -/
theorem cross_registry_approval_refused_approvalFull_candidate :
    cross_registry_approval_refused_premise .none demoHash encode 5 regA regB payload →
    cross_registry_approval_refused_claim .none demoHash encode 5 regA regB payload := by
  decide +kernel

/-- Hypothesis instance under #741, not accepted law; rejected name-only safety claim. -/
abbrev name_only_separation_claim_premise (m : Mutation) (hash : Hash) (code : Codec) (app : Nat) (a b : TokenId) (payload : Payload) : Prop :=
  a ≠ b ∧ finiteEncoding code [Preimage.approval { a with policy := 0 } payload, Preimage.approval { b with policy := 0 } payload, Preimage.application app] ∧ finiteHash hash code [Preimage.approval { a with policy := 0 } payload, Preimage.approval { b with policy := 0 } payload, Preimage.application app]
/-- Hypothesis instance under #741, not accepted law; rejected name-only safety claim. -/
abbrev name_only_separation_claim_claim (m : Mutation) (hash : Hash) (code : Codec) (app : Nat) (a b : TokenId) (payload : Payload) : Prop :=
  approve m .nameOnly hash code app b payload (approvalAsset .nameOnly hash code app a payload) = false
/-- Executed antecedent instance of the #741 hypothesis, not accepted law; rejected name-only safety claim. -/
theorem name_only_separation_claim_antecedent : name_only_separation_claim_premise .none demoHash encode 5 regA regC payload := by
  decide +kernel

/-- Executed candidate instance of the #741 hypothesis, not accepted law; rejected name-only safety claim. -/
theorem name_only_separation_claim_approvalNameOnly_candidate :
    name_only_separation_claim_premise .none demoHash encode 5 regA regC payload →
    name_only_separation_claim_claim .none demoHash encode 5 regA regC payload := by
  decide +kernel

/-- Hypothesis instance under #741, not accepted law; policy-only recognition of a genuine witness with fabricated state datum. -/
abbrev policy_only_excludes_witness_premise (m : Mutation) (hash : Hash) (code : Codec) (r foreign : TokenId) (key : Nat) (o : Observation) : Prop :=
  o.asset = roleAsset hash code foreign .witness key ∧ o.provenance = o.asset ∧ o.asset.name ≠ r.name
/-- Hypothesis instance under #741, not accepted law; policy-only recognition of a genuine witness with fabricated state datum. -/
abbrev policy_only_excludes_witness_claim (m : Mutation) (hash : Hash) (code : Codec) (r foreign : TokenId) (key : Nat) (o : Observation) : Prop :=
  recognize m .policyOnly hash code r .state key o = false
/-- Executed antecedent instance of the #741 hypothesis, not accepted law; policy-only recognition of a genuine witness with fabricated state datum. -/
theorem policy_only_excludes_witness_antecedent : policy_only_excludes_witness_premise .none demoHash encode regA regB 7 (observation (roleAsset demoHash encode regB .witness 7)) := by
  decide +kernel

/-- Executed candidate instance of the #741 hypothesis, not accepted law; policy-only recognition of a genuine witness with fabricated state datum. -/
theorem policy_only_excludes_witness_policyOnlyPolicy_candidate :
    policy_only_excludes_witness_premise .none demoHash encode regA regB 7 (observation (roleAsset demoHash encode regB .witness 7)) →
    policy_only_excludes_witness_claim .none demoHash encode regA regB 7 (observation (roleAsset demoHash encode regB .witness 7)) := by
  decide +kernel

/-- Hypothesis instance under #741, not accepted law; same seed once, two application-specific policies in one transaction. -/
abbrev same_transaction_two_applications_premise (m : Mutation) (hash : Hash) (code : Codec) (releaseA releaseB : Nat) (seed : OutRef) (tx : TxView) : Prop :=
  applicationPolicy hash code releaseA ≠ applicationPolicy hash code releaseB ∧ finiteEncoding code [Preimage.statePolicy (applicationPolicy hash code releaseA), Preimage.statePolicy (applicationPolicy hash code releaseB)] ∧ finiteHash hash code [Preimage.statePolicy (applicationPolicy hash code releaseA), Preimage.statePolicy (applicationPolicy hash code releaseB)] ∧ genesis m tx seed (registry hash code releaseA seed) = true ∧ genesis m tx seed (registry hash code releaseB seed) = true
/-- Hypothesis instance under #741, not accepted law; same seed once, two application-specific policies in one transaction. -/
abbrev same_transaction_two_applications_claim (m : Mutation) (hash : Hash) (code : Codec) (releaseA releaseB : Nat) (seed : OutRef) (tx : TxView) : Prop :=
  (registry hash code releaseA seed).name = (registry hash code releaseB seed).name ∧ (registry hash code releaseA seed) ≠ (registry hash code releaseB seed) ∧ tx.spent.count seed = 1
/-- Executed antecedent instance of the #741 hypothesis, not accepted law; same seed once, two application-specific policies in one transaction. -/
theorem same_transaction_two_applications_antecedent : same_transaction_two_applications_premise .none demoHash encode 1 2 seed (genesisView [seed] [derivedA, derivedB]) := by
  decide +kernel

/-- Executed candidate instance of the #741 hypothesis, not accepted law; same seed once, two application-specific policies in one transaction. -/
theorem same_transaction_two_applications_genesisSeed_candidate :
    same_transaction_two_applications_premise .none demoHash encode 1 2 seed (genesisView [seed, seed] [derivedA, derivedB]) →
    same_transaction_two_applications_claim .none demoHash encode 1 2 seed (genesisView [seed, seed] [derivedA, derivedB]) := by
  decide +kernel

/-- Hypothesis instance under #741, not accepted law; across-history repeated seed, separate from same-transaction genesis. -/
abbrev history_reuse_refused_premise (m : Mutation) (history : List TxView) (seed : OutRef) : Prop :=
  1 < (history.flatMap (·.spent)).count seed
/-- Hypothesis instance under #741, not accepted law; across-history repeated seed, separate from same-transaction genesis. -/
abbrev history_reuse_refused_claim (m : Mutation) (history : List TxView) (seed : OutRef) : Prop :=
  historyAllows m history = false
/-- Executed antecedent instance of the #741 hypothesis, not accepted law; across-history repeated seed, separate from same-transaction genesis. -/
theorem history_reuse_refused_antecedent : history_reuse_refused_premise .none [genesisView [seed] [regA], genesisView [seed] [regB]] seed := by
  decide +kernel

/-- Executed candidate instance of the #741 hypothesis, not accepted law; across-history repeated seed, separate from same-transaction genesis. -/
theorem history_reuse_refused_historySpentOnce_candidate :
    history_reuse_refused_premise .none [genesisView [seed] [regA], genesisView [seed] [regB]] seed →
    history_reuse_refused_claim .none [genesisView [seed] [regA], genesisView [seed] [regB]] seed := by
  decide +kernel

end NoPin.Fixtures

namespace NoPin.Fixtures
open Singular

/-- Hypothesis instance under #741, not accepted law; shared-policy finite role separation. -/
abbrev authenticated_state_role_separation_premise (_m : Mutation) (hash : Hash) (code : Codec)
    (r : TokenId) (seed : OutRef) (role : Role) (key : Nat) : Prop :=
  role ≠ .state ∧ r.name = stateName hash code seed ∧
    finiteEncoding code [.seed seed, .role role r key] ∧
    finiteHash hash code [.seed seed, .role role r key]
/-- Hypothesis instance under #741, not accepted law; simplified role preimages, no economic nonce. -/
abbrev authenticated_state_role_separation_claim (m : Mutation) (hash : Hash) (code : Codec)
    (r : TokenId) (_seed : OutRef) (role : Role) (key : Nat) : Prop :=
  recognize m .authenticated hash code r .state key ⟨r, true, r⟩ = true ∧
    recognize m .authenticated hash code r .state key
      ⟨roleAsset hash code r role key, true, roleAsset hash code r role key⟩ = false
/-- Executed antecedent of the #741 hypothesis, not accepted law; two distinct occurring preimages. -/
theorem authenticated_state_role_separation_antecedent :
    authenticated_state_role_separation_premise .none demoHash encode derivedA seed .witness 7 := by
  decide +kernel
/-- Executed positive #741 hypothesis instance, not accepted law; genuine state and fabricated state datum. -/
theorem authenticated_state_role_separation_stateName_candidate :
    authenticated_state_role_separation_premise .none demoHash encode derivedA seed .witness 7 →
    authenticated_state_role_separation_claim .none demoHash encode derivedA seed .witness 7 := by
  decide +kernel

end NoPin.Fixtures
