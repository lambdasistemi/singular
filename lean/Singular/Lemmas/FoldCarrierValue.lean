import Singular.Lemmas.FoldRoutingFacts

/-! Counting every carrier once by the singular tag it actually holds.
Coincident addresses and repeated commitment names do not supply a purpose. -/

namespace Singular

instance : LawfulBEq TokenId where
  eq_of_beq {a b} h := by
    cases a; cases b
    simpa [BEq.beq, instBEqTokenId.beq, TokenId.mk.injEq] using h
  rfl {a} := by cases a; simp [BEq.beq, instBEqTokenId.beq]

instance : LawfulBEq SingularTag where
  eq_of_beq {a b} h := by
    cases a; cases b
    have tokenEq (x y : TokenId) : instBEqTokenId.beq x y = true ↔ x = y := beq_iff_eq (a := x) (b := y)
    simpa [BEq.beq, instBEqSingularTag.beq, SingularTag.mk.injEq, tokenEq] using h
  rfl {a} := by
    cases a
    have tokenSelf (x : TokenId) : instBEqTokenId.beq x x = true := beq_self_eq_true x
    simp [BEq.beq, instBEqSingularTag.beq, tokenSelf]

def foldCarrierMeasure (outputs : List EconomicOutput) (tag : SingularTag) : Nat :=
  ((outputs.filter fun output => output.singularTags.contains tag).map (·.output.lovelace)).sum

theorem fold_carrier_measure {config : Config} {outputs : List EconomicOutput}
    {booking : RegistrationBooking}
    (accepted : foldCarrierRefusal config outputs (.registration booking) = none) :
    foldCarrierMeasure outputs (config.singularTag booking.request.key) = booking.request.carrierAda := by
  obtain ⟨output, selected, value, _, _⟩ := foldCarrier_checked accepted
  unfold foldCarrierMeasure
  rw [selected]
  simp [value]

theorem fold_carrier_declared_sum (config : Config) (outputs : List EconomicOutput)
    (members : List FoldMember)
    (checked : ∀ member ∈ members, foldCarrierRefusal config outputs member = none) :
    ((foldCarrierTags config members).map (foldCarrierMeasure outputs)).sum =
      (foldObligations members).carriers := by
  induction members with
  | nil => simp [foldCarrierTags, foldObligations]
  | cons member rest ih =>
    have tail := ih (fun m belongs => checked m (by simp [belongs]))
    cases member with
    | registration b =>
      have head := fold_carrier_measure (checked (.registration b) (by simp))
      simpa [foldCarrierTags, foldObligations, FoldMember.carrier, head] using tail
    | termination b => simpa [foldCarrierTags, foldObligations, FoldMember.carrier] using tail

theorem fold_output_carrier_shape (config : Config) (outputs : List EconomicOutput)
    (members : List FoldMember)
    (checked : ∀ member ∈ members, foldCarrierRefusal config outputs member = none)
    (tags : (outputs.flatMap (·.singularTags)).Perm (foldCarrierTags config members))
    (output : EconomicOutput) (member : output ∈ outputs)
    (tag : SingularTag) (held : tag ∈ output.singularTags) :
    output.singularTags = [tag] ∧ foldCarrierMeasure outputs tag = output.output.lovelace := by
  have present : tag ∈ foldCarrierTags config members :=
    tags.mem_iff.mp (List.mem_flatMap.mpr ⟨output, member, held⟩)
  obtain ⟨request, requestMem, named⟩ := List.mem_filterMap.mp present
  cases request with
  | termination b => simp at named
  | registration b =>
    simp only [Option.some.injEq] at named
    obtain ⟨destination, selected, value, singular, _⟩ :=
      foldCarrier_checked (checked (.registration b) requestMem)
    have belongs : output ∈ outputs.filter (fun o => o.singularTags.contains (config.singularTag b.request.key)) :=
      List.mem_filter.mpr ⟨member, by simpa [named] using held⟩
    rw [selected] at belongs
    have same := List.mem_singleton.mp belongs
    subst output
    exact ⟨by simpa [named] using singular, by unfold foldCarrierMeasure; rw [← named, selected]; simp⟩

theorem sum_flatMap_nat {α β : Type} (values : List α) (f : α → List β) (weight : β → Nat) :
    ((values.flatMap f).map weight).sum =
      (values.map fun value => ((f value).map weight).sum).sum := by
  induction values with
  | nil => rfl
  | cons value rest ih => simp [ih]

theorem fold_carrier_observed_sum (config : Config) (outputs : List EconomicOutput)
    (members : List FoldMember)
    (checked : ∀ member ∈ members, foldCarrierRefusal config outputs member = none)
    (tags : (outputs.flatMap (·.singularTags)).Perm (foldCarrierTags config members)) :
    foldCarrierLovelace outputs = (foldObligations members).carriers := by
  have actual : ((outputs.flatMap (·.singularTags)).map (foldCarrierMeasure outputs)).sum =
      foldCarrierLovelace outputs := by
    rw [sum_flatMap_nat]
    unfold foldCarrierLovelace
    rw [sum_filter_nat]
    apply congrArg List.sum
    apply List.map_congr_left
    intro output member
    cases held : output.singularTags with
    | nil => simp [held]
    | cons tag rest =>
      obtain ⟨single, value⟩ := fold_output_carrier_shape config outputs members checked tags
        output member tag (by simp [held])
      have restNil : rest = [] := by simpa [held] using single
      simp [restNil, value]
  rw [← actual, (tags.map (foldCarrierMeasure outputs)).sum_nat]
  exact fold_carrier_declared_sum config outputs members checked

end Singular
