import Singular.Lemmas.FoldSupply
import Singular.Statements.Booking
import Singular.Statements.Termination

/-! Accounting and provenance facts for the public economic fold statements. -/

namespace Singular

theorem foldMembers_registration {world : World} {tx : EconomicTransaction}
    {b : RegistrationBooking} (member : FoldMember.registration b ∈ foldMembers world tx) :
    b ∈ world.pending ∧ inputsContainReference tx.transaction.inputs b.request.reference = true := by
  obtain ⟨input, inputMem, chosen⟩ := List.mem_filterMap.mp member
  cases reference : input.ref with
  | none => simp [reference] at chosen
  | some ref =>
    simp only [reference, Option.bind_some] at chosen
    unfold foldMemberAt at chosen
    cases registration : world.pending.find? (fun b => b.request.reference == ref) with
    | none =>
      cases termination : world.terminations.find? (fun b => b.request.reference == ref) <;>
        simp [registration, termination] at chosen
    | some found =>
      simp only [registration, Option.some.injEq, FoldMember.registration.injEq] at chosen
      subst found
      have same : b.request.reference = ref := by simpa using List.find?_some registration
      refine ⟨List.mem_of_find?_eq_some registration, ?_⟩
      apply List.any_eq_true.mpr
      exact ⟨input, inputMem, by simp [reference, same]⟩

set_option maxRecDepth 2048 in
theorem foldPrerequisite_observations {world : World} {u : EconomicUtxo}
    {tx : EconomicTransaction} (accepted : foldPrerequisite world u tx = none) :
    economicObservationRefusal world u tx = none ∧
    (tx.transaction.inputs.map (·.ref)).Nodup ∧
    inputPresenceRefusal u.ledger tx.transaction = none := by
  unfold foldPrerequisite at accepted
  simp only [bind, pure, Option.bind] at accepted
  repeat (split at accepted <;> try contradiction)
  all_goals simp_all [← Option.eq_none_iff_forall_ne_some]

set_option maxRecDepth 2048 in
theorem foldRouting_accounting {world : World} {u : EconomicUtxo}
    {tx : EconomicTransaction} {result : Result}
    (accepted : foldRoutingRefusal world u tx result = none) :
    tx.transaction.donation = (foldObligations (foldMembers world tx)).donation ∧
    tx.transaction.fee ≤ foldOrdinaryLovelace (economicSpent u tx) ∧
    balanced u.ledger tx.transaction = true ∧ requestTagsBurned u tx = true := by
  unfold foldRoutingRefusal at accepted
  simp only [bind, pure, Option.bind] at accepted
  repeat (split at accepted <;> try contradiction)
  all_goals simp_all [← Option.eq_none_iff_forall_ne_some] <;> omega

def FoldMember.isRegistration : FoldMember → Bool
  | .registration _ => true
  | .termination _ => false

theorem fold_donation_floor {world : World} (reachable : WorldReachable world)
    (members : List FoldMember)
    (selected : ∀ b, FoldMember.registration b ∈ members → b ∈ world.pending) :
    (members.filter FoldMember.isRegistration).length * world.registry.config.registrationCost ≤
      (foldObligations members).donation := by
  induction members with
  | nil => simp [foldObligations]
  | cons member rest ih =>
    have tail := ih (fun b member => selected b (by simp [member]))
    cases member with
    | registration b =>
      have exact := (Statements.booked_request_has_exact_contents world reachable b
        (selected b (by simp))).1
      have cost : b.request.registrationCost = world.registry.config.registrationCost := by
        simp only [exactContents, Bool.and_eq_true, decide_eq_true_eq] at exact
        have shape := exact.1.1
        simp only [registrationContentsShape, Bool.and_eq_true, decide_eq_true_eq] at shape
        exact shape.1.2.1
      simpa [FoldMember.isRegistration, foldObligations, FoldMember.donation,
        cost, Nat.add_mul, Nat.add_comm] using Nat.add_le_add_left tail world.registry.config.registrationCost
    | termination b =>
      simpa [FoldMember.isRegistration, foldObligations, FoldMember.donation] using
        Nat.le_trans tail (Nat.le_add_left (foldObligations rest).donation
          (b.request.contents.lovelace - b.request.declaredTip))

theorem flatMap_length_one {α β : Type} (values : List α) (f : α → List β)
    (one : ∀ value ∈ values, (f value).length = 1) :
    (values.flatMap f).length = values.length := by
  induction values with
  | nil => rfl
  | cons value rest ih =>
    simp only [List.flatMap_cons, List.length_append, List.length_cons,
      one value (by simp), ih (fun v member => one v (by simp [member]))]
    omega

end Singular
