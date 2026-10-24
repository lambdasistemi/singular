import NoPin.Witnesses

namespace NoPin.Mutants
open Singular NoPin.Fixtures

/-- Executed single-guard falsification of the #741 hypothesis, not accepted law; complete-identity ruling. -/
theorem full_approval_inversion_approvalFull_mutant :
    ¬ (full_approval_inversion_premise (.flip .approvalFull) demoHash encode 5 regA payload (approvalAsset .full demoHash encode 5 regA payload) →
       full_approval_inversion_claim (.flip .approvalFull) demoHash encode 5 regA payload (approvalAsset .full demoHash encode 5 regA payload)) := by
  decide +kernel

/-- Executed single-guard falsification of the #741 hypothesis, not accepted law; rejected name-only contrast. -/
theorem name_only_inversion_approvalNameOnly_mutant :
    ¬ (name_only_inversion_premise (.flip .approvalNameOnly) demoHash encode 5 regA payload (approvalAsset .nameOnly demoHash encode 5 regA payload) →
       name_only_inversion_claim (.flip .approvalNameOnly) demoHash encode 5 regA payload (approvalAsset .nameOnly demoHash encode 5 regA payload)) := by
  decide +kernel

/-- Executed single-guard falsification of the #741 hypothesis, not accepted law; unresolved shared-policy recognition. -/
theorem policy_only_inversion_policyOnlyPolicy_mutant :
    ¬ (policy_only_inversion_premise (.flip .policyOnlyPolicy) demoHash encode regA (observation regA) →
       policy_only_inversion_claim (.flip .policyOnlyPolicy) demoHash encode regA (observation regA)) := by
  decide +kernel

/-- Executed single-guard falsification of the #741 hypothesis, not accepted law; unresolved shared-policy recognition. -/
theorem policy_only_inversion_policyOnlyDatum_mutant :
    ¬ (policy_only_inversion_premise (.flip .policyOnlyDatum) demoHash encode regA (observation regA) →
       policy_only_inversion_claim (.flip .policyOnlyDatum) demoHash encode regA (observation regA)) := by
  decide +kernel

/-- Executed single-guard falsification of the #741 hypothesis, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
theorem state_inversion_statePolicy_mutant :
    ¬ (state_inversion_premise (.flip .statePolicy) demoHash encode regA 7 (observation (roleAsset demoHash encode regA .state 7)) →
       state_inversion_claim (.flip .statePolicy) demoHash encode regA 7 (observation (roleAsset demoHash encode regA .state 7))) := by
  decide +kernel

/-- Executed single-guard falsification of the #741 hypothesis, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
theorem state_inversion_stateName_mutant :
    ¬ (state_inversion_premise (.flip .stateName) demoHash encode regA 7 (observation (roleAsset demoHash encode regA .state 7)) →
       state_inversion_claim (.flip .stateName) demoHash encode regA 7 (observation (roleAsset demoHash encode regA .state 7))) := by
  decide +kernel

/-- Executed single-guard falsification of the #741 hypothesis, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
theorem state_inversion_stateProvenance_mutant :
    ¬ (state_inversion_premise (.flip .stateProvenance) demoHash encode regA 7 (observation (roleAsset demoHash encode regA .state 7)) →
       state_inversion_claim (.flip .stateProvenance) demoHash encode regA 7 (observation (roleAsset demoHash encode regA .state 7))) := by
  decide +kernel

/-- Executed single-guard falsification of the #741 hypothesis, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
theorem state_inversion_stateDatum_mutant :
    ¬ (state_inversion_premise (.flip .stateDatum) demoHash encode regA 7 (observation (roleAsset demoHash encode regA .state 7)) →
       state_inversion_claim (.flip .stateDatum) demoHash encode regA 7 (observation (roleAsset demoHash encode regA .state 7))) := by
  decide +kernel

/-- Executed single-guard falsification of the #741 hypothesis, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
theorem witness_inversion_witnessPolicy_mutant :
    ¬ (witness_inversion_premise (.flip .witnessPolicy) demoHash encode regA 7 (observation (roleAsset demoHash encode regA .witness 7)) →
       witness_inversion_claim (.flip .witnessPolicy) demoHash encode regA 7 (observation (roleAsset demoHash encode regA .witness 7))) := by
  decide +kernel

/-- Executed single-guard falsification of the #741 hypothesis, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
theorem witness_inversion_witnessName_mutant :
    ¬ (witness_inversion_premise (.flip .witnessName) demoHash encode regA 7 (observation (roleAsset demoHash encode regA .witness 7)) →
       witness_inversion_claim (.flip .witnessName) demoHash encode regA 7 (observation (roleAsset demoHash encode regA .witness 7))) := by
  decide +kernel

/-- Executed single-guard falsification of the #741 hypothesis, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
theorem witness_inversion_witnessProvenance_mutant :
    ¬ (witness_inversion_premise (.flip .witnessProvenance) demoHash encode regA 7 (observation (roleAsset demoHash encode regA .witness 7)) →
       witness_inversion_claim (.flip .witnessProvenance) demoHash encode regA 7 (observation (roleAsset demoHash encode regA .witness 7))) := by
  decide +kernel

/-- Executed single-guard falsification of the #741 hypothesis, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
theorem trieReady_inversion_trieReadyPolicy_mutant :
    ¬ (trieReady_inversion_premise (.flip .trieReadyPolicy) demoHash encode regA 7 (observation (roleAsset demoHash encode regA .trieReady 7)) →
       trieReady_inversion_claim (.flip .trieReadyPolicy) demoHash encode regA 7 (observation (roleAsset demoHash encode regA .trieReady 7))) := by
  decide +kernel

/-- Executed single-guard falsification of the #741 hypothesis, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
theorem trieReady_inversion_trieReadyName_mutant :
    ¬ (trieReady_inversion_premise (.flip .trieReadyName) demoHash encode regA 7 (observation (roleAsset demoHash encode regA .trieReady 7)) →
       trieReady_inversion_claim (.flip .trieReadyName) demoHash encode regA 7 (observation (roleAsset demoHash encode regA .trieReady 7))) := by
  decide +kernel

/-- Executed single-guard falsification of the #741 hypothesis, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
theorem trieReady_inversion_trieReadyProvenance_mutant :
    ¬ (trieReady_inversion_premise (.flip .trieReadyProvenance) demoHash encode regA 7 (observation (roleAsset demoHash encode regA .trieReady 7)) →
       trieReady_inversion_claim (.flip .trieReadyProvenance) demoHash encode regA 7 (observation (roleAsset demoHash encode regA .trieReady 7))) := by
  decide +kernel

/-- Executed single-guard falsification of the #741 hypothesis, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
theorem application_inversion_applicationPolicy_mutant :
    ¬ (application_inversion_premise (.flip .applicationPolicy) demoHash encode regA 7 (observation (roleAsset demoHash encode regA .application 7)) →
       application_inversion_claim (.flip .applicationPolicy) demoHash encode regA 7 (observation (roleAsset demoHash encode regA .application 7))) := by
  decide +kernel

/-- Executed single-guard falsification of the #741 hypothesis, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
theorem application_inversion_applicationName_mutant :
    ¬ (application_inversion_premise (.flip .applicationName) demoHash encode regA 7 (observation (roleAsset demoHash encode regA .application 7)) →
       application_inversion_claim (.flip .applicationName) demoHash encode regA 7 (observation (roleAsset demoHash encode regA .application 7))) := by
  decide +kernel

/-- Executed single-guard falsification of the #741 hypothesis, not accepted law; shared-policy role question; request tags use simplified registry/role/key only. -/
theorem application_inversion_applicationProvenance_mutant :
    ¬ (application_inversion_premise (.flip .applicationProvenance) demoHash encode regA 7 (observation (roleAsset demoHash encode regA .application 7)) →
       application_inversion_claim (.flip .applicationProvenance) demoHash encode regA 7 (observation (roleAsset demoHash encode regA .application 7))) := by
  decide +kernel

/-- Executed single-guard falsification of the #741 hypothesis, not accepted law; same transaction versus history. -/
theorem genesis_inversion_genesisSeed_mutant :
    ¬ (genesis_inversion_premise (.flip .genesisSeed) (genesisView [seed] [regA]) seed regA →
       genesis_inversion_claim (.flip .genesisSeed) (genesisView [seed] [regA]) seed regA) := by
  decide +kernel

/-- Executed single-guard falsification of the #741 hypothesis, not accepted law; same transaction versus history. -/
theorem genesis_inversion_genesisInvocation_mutant :
    ¬ (genesis_inversion_premise (.flip .genesisInvocation) (genesisView [seed] [regA]) seed regA →
       genesis_inversion_claim (.flip .genesisInvocation) (genesisView [seed] [regA]) seed regA) := by
  decide +kernel

/-- Executed single-guard falsification of the #741 hypothesis, not accepted law; same transaction versus history. -/
theorem genesis_inversion_genesisMint_mutant :
    ¬ (genesis_inversion_premise (.flip .genesisMint) (genesisView [seed] [regA]) seed regA →
       genesis_inversion_claim (.flip .genesisMint) (genesisView [seed] [regA]) seed regA) := by
  decide +kernel

/-- Executed single-guard falsification of the #741 hypothesis, not accepted law; same transaction versus history. -/
theorem genesis_inversion_genesisQuantity_mutant :
    ¬ (genesis_inversion_premise (.flip .genesisQuantity) (genesisView [seed] [regA]) seed regA →
       genesis_inversion_claim (.flip .genesisQuantity) (genesisView [seed] [regA]) seed regA) := by
  decide +kernel

/-- Executed single-guard falsification of the #741 hypothesis, not accepted law; same transaction versus history. -/
theorem genesis_inversion_genesisOutput_mutant :
    ¬ (genesis_inversion_premise (.flip .genesisOutput) (genesisView [seed] [regA]) seed regA →
       genesis_inversion_claim (.flip .genesisOutput) (genesisView [seed] [regA]) seed regA) := by
  decide +kernel

/-- Executed single-guard falsification of the #741 hypothesis, not accepted law; across-history spent-once premise. -/
theorem history_inversion_historySpentOnce_mutant :
    ¬ (history_inversion_premise (.flip .historySpentOnce) [genesisView [seed] [regA]] →
       history_inversion_claim (.flip .historySpentOnce) [genesisView [seed] [regA]]) := by
  decide +kernel

/-- Executed single-guard falsification of the #741 hypothesis, not accepted law; complete-identity ruling, including equal seed names under different policies. -/
theorem cross_registry_approval_refused_approvalFull_mutant :
    ¬ (cross_registry_approval_refused_premise (.flip .approvalFull) demoHash encode 5 regA regB payload →
       cross_registry_approval_refused_claim (.flip .approvalFull) demoHash encode 5 regA regB payload) := by
  decide +kernel

/-- Executed single-guard falsification of the #741 hypothesis, not accepted law; rejected name-only safety claim. -/
theorem name_only_separation_claim_approvalNameOnly_mutant :
    ¬ (name_only_separation_claim_premise (.flip .approvalNameOnly) demoHash encode 5 regA regC payload →
       name_only_separation_claim_claim (.flip .approvalNameOnly) demoHash encode 5 regA regC payload) := by
  decide +kernel

/-- Executed single-guard falsification of the #741 hypothesis, not accepted law; policy-only recognition of a genuine witness with fabricated state datum. -/
theorem policy_only_excludes_witness_policyOnlyPolicy_mutant :
    ¬ (policy_only_excludes_witness_premise (.flip .policyOnlyPolicy) demoHash encode regA regB 7 (observation (roleAsset demoHash encode regB .witness 7)) →
       policy_only_excludes_witness_claim (.flip .policyOnlyPolicy) demoHash encode regA regB 7 (observation (roleAsset demoHash encode regB .witness 7))) := by
  decide +kernel

/-- Executed single-guard falsification of the #741 hypothesis, not accepted law; same seed once, two application-specific policies in one transaction. -/
theorem same_transaction_two_applications_genesisSeed_mutant :
    ¬ (same_transaction_two_applications_premise (.flip .genesisSeed) demoHash encode 1 2 seed (genesisView [seed, seed] [derivedA, derivedB]) →
       same_transaction_two_applications_claim (.flip .genesisSeed) demoHash encode 1 2 seed (genesisView [seed, seed] [derivedA, derivedB])) := by
  decide +kernel

/-- Executed single-guard falsification of the #741 hypothesis, not accepted law; across-history repeated seed, separate from same-transaction genesis. -/
theorem history_reuse_refused_historySpentOnce_mutant :
    ¬ (history_reuse_refused_premise (.flip .historySpentOnce) [genesisView [seed] [regA], genesisView [seed] [regB]] seed →
       history_reuse_refused_claim (.flip .historySpentOnce) [genesisView [seed] [regA], genesisView [seed] [regB]] seed) := by
  decide +kernel

/- These concrete evaluations do not prove the general candidate statements. -/
/-- Hypothesis contrast under #741, not accepted law; rejected name-only reading. -/
example : approve .none .nameOnly demoHash encode 5 regB payload
    (approvalAsset .nameOnly demoHash encode 5 regA payload) = true := by decide +kernel
/-- Hypothesis contrast under #741, not accepted law; policy-only fabricated state datum. -/
example : recognize .none .policyOnly demoHash encode regA .state 7
    (observation (roleAsset demoHash encode regA .witness 7)) = true := by decide +kernel
/-- Hypothesis contrast under #741, not accepted law; authenticated fabricated state datum refusal. -/
example : recognize .none .authenticated demoHash encode regA .state 7
    (observation (roleAsset demoHash encode regA .witness 7)) = false := by decide +kernel
end NoPin.Mutants

namespace NoPin.Mutants
open NoPin.Fixtures

/-- Executed single-guard falsification under #741, not accepted law; role separation and state completeness. -/
theorem authenticated_state_role_separation_stateName_mutant :
    ¬ (authenticated_state_role_separation_premise (.flip .stateName) demoHash encode derivedA seed .witness 7 →
       authenticated_state_role_separation_claim (.flip .stateName) demoHash encode derivedA seed .witness 7) := by
  decide +kernel

end NoPin.Mutants
