import Singular.Economics

/-! Inversions of the economic rejection judgement. These are helpers for the
public statements, not a second acceptance rule. -/

namespace Singular

instance : LawfulBEq OutRef where
  eq_of_beq {a b} h := by
    cases a; cases b
    simpa [BEq.beq, instBEqOutRef.beq, OutRef.mk.injEq] using h
  rfl {a} := by cases a; simp [BEq.beq, instBEqOutRef.beq]

instance : LawfulBEq TxRole where
  eq_of_beq {a b} h := by
    cases a <;> cases b <;> first | rfl | exact absurd h (by decide)
  rfl {a} := by cases a <;> rfl

instance : LawfulBEq DatumForm where
  eq_of_beq {a b} h := by
    cases a <;> cases b <;> first | rfl | exact absurd h (by decide)
  rfl {a} := by cases a <;> rfl

instance : LawfulBEq Config where
  eq_of_beq {a b} h := by
    cases a; cases b
    have byteEq (x y : ByteArray) : ByteArray.instBEq.beq x y = true ↔ x = y :=
      beq_iff_eq (a := x) (b := y)
    simpa [BEq.beq, instBEqConfig.beq, Config.mk.injEq, byteEq] using h
  rfl {a} := by
    cases a
    have byteSelf (x : ByteArray) : ByteArray.instBEq.beq x x = true := beq_self_eq_true x
    simp [BEq.beq, instBEqConfig.beq, byteSelf]

set_option maxRecDepth 2048 in
theorem rejectionAccepted_checks {world after : World} {u : EconomicUtxo} {r : Rejection}
    (accepted : rejectionAccepted world u r = .ok after) :
    rejectionInputsRefusal u r = none ∧ rejectionStateRefusal world u r = none ∧
    economicObservationRefusal world u r.transaction = none ∧
    ∃ interval, r.transaction.transaction.validity = some interval ∧ interval.valid ∧
      r.members.isEmpty = false ∧
      (r.transaction.transaction.inputs.map (·.ref)).Perm (r.members.map fun m => some m.1) ∧
      (∀ member ∈ r.members, rejectionMemberRefusal world interval member = none) ∧
      requestTagsBurned u r.transaction = true ∧
      rejectionSupplyUnchanged u r.transaction = true := by
  have refused : rejectionRefusal world u r = none := by
    unfold rejectionAccepted at accepted
    split at accepted
    · contradiction
    · assumption
  unfold rejectionRefusal at refused
  clear accepted
  simp only [bind, pure, Option.bind] at refused
  repeat (split at refused <;> try contradiction)
  all_goals simp_all [← Option.eq_none_iff_forall_ne_some, List.findSome?_eq_none_iff]

theorem rejectionInputs_facts {u : EconomicUtxo} {r : Rejection}
    (accepted : rejectionInputsRefusal u r = none) :
    ¬ (inputsContainReference r.transaction.transaction.inputs r.stateReference = true ∧
      inputsContainReference r.transaction.transaction.referenceInputs r.stateReference = true) ∧
    (r.transaction.transaction.inputs.map (·.ref)).Nodup ∧
    (r.members.map Prod.fst).Nodup ∧ disjointInputs r.transaction.transaction = true ∧
    inputPresenceRefusal u.ledger r.transaction.transaction = none := by
  unfold rejectionInputsRefusal at accepted
  dsimp only at accepted
  repeat (split at accepted <;> try contradiction)
  all_goals simp_all

theorem rejectionObservation_world {world : World} {u : EconomicUtxo} {tx : EconomicTransaction}
    (accepted : economicObservationRefusal world u tx = none) :
    observesWorld world u = true ∧ (u.map Prod.fst).Nodup ∧
      ∀ ref output, (ref, output) ∈ u → ref.tx ≠ tx.identity := by
  unfold economicObservationRefusal at accepted
  repeat (split at accepted <;> try contradiction)
  all_goals
    simp_all <;> assumption

theorem observed_registration_unique {u : EconomicUtxo} {a b : RegistrationRequest}
    (first : observesRegistration u a = true) (second : observesRegistration u b = true)
    (same : a.reference = b.reference) : a = b := by
  unfold observesRegistration at first second
  rw [same] at first
  cases lookup : economicLookup u b.reference with
  | none => simp [lookup] at second
  | some o =>
    simp only [lookup, decide_eq_true_eq] at first second
    have equal := first.1.symm.trans second.1
    simpa using equal

theorem observed_request_kinds_disjoint {u : EconomicUtxo}
    {a : RegistrationRequest} {b : TerminationRequest}
    (first : observesRegistration u a = true) (second : observesTermination u b = true)
    (same : a.reference = b.reference) : False := by
  unfold observesRegistration at first
  unfold observesTermination at second
  rw [same] at first
  cases lookup : economicLookup u b.reference with
  | none => simp [lookup] at second
  | some o =>
    simp only [lookup, decide_eq_true_eq] at first second
    have equal := first.1.symm.trans second.1
    cases equal

end Singular
