import Singular.Lemmas
import Singular.Driver
import Singular.Economics

/-! Retraction characterization, admission precedence and all five fold deadline laws. -/

namespace Singular.Statements

/-- Which pending requests their owner can retract, and when.

For every state, request and witness: the retraction is admitted exactly when the
request inserts a key or reads a terminal one, the request's owner is among the
transaction's signatories, and the transaction's validity interval lies inside
phase 2 — from `submittedAt + processTime`, included, to
`submittedAt + processTime + retractTime`, which the excluded upper bound may
reach and not pass. -/
theorem retract_admitted_iff (s : RegistryState) (r : Request) (w : RetractWitness) :
    (∃ t, admittedExitStep s .retract r w = .ok t) ↔
      (r.edge = .insertAbsent ∨ r.edge = .insertActive ∨ r.edge = .witnessTerminal) ∧
      r.owner ∈ w.signatories ∧
      r.submittedAt + s.config.processTime ≤ w.validFrom ∧
      w.validTo ≤ r.submittedAt + s.config.processTime + s.config.retractTime := by
  have hr := retractableEdge_iff r.edge
  have hp := inPhase2_iff s.config r w
  simp only [admittedExitStep, exitAdmission, retractAdmission, exitStep]
  cases h1 : retractableEdge r.edge <;>
    cases h2 : w.signatories.contains r.owner <;>
    cases h3 : inPhase2 s.config r w <;> simp_all

/-- Why a retraction is refused: the first check it fails, in the request
script's order.

A request that neither inserts a key nor reads a terminal one is refused
`withdraw-insert-only`, whoever signed and whenever; a retractable request whose
owner did not sign is refused `retract-owner`, inside phase 2 or not; a
retractable request its owner signed, outside phase 2, is refused
`not-phase2`. -/
theorem retract_refusal_first_failing (s : RegistryState) (r : Request) (w : RetractWitness) :
    (r.edge ≠ .insertAbsent → r.edge ≠ .insertActive → r.edge ≠ .witnessTerminal →
      admittedExitStep s .retract r w = .error "withdraw-insert-only") ∧
    ((r.edge = .insertAbsent ∨ r.edge = .insertActive ∨ r.edge = .witnessTerminal) →
      r.owner ∉ w.signatories →
      admittedExitStep s .retract r w = .error "retract-owner") ∧
    ((r.edge = .insertAbsent ∨ r.edge = .insertActive ∨ r.edge = .witnessTerminal) →
      r.owner ∈ w.signatories →
      ¬ (r.submittedAt + s.config.processTime ≤ w.validFrom ∧
        w.validTo ≤ r.submittedAt + s.config.processTime + s.config.retractTime) →
      admittedExitStep s .retract r w = .error "not-phase2") := by
  have hr := retractableEdge_iff r.edge
  have hp := inPhase2_iff s.config r w
  refine ⟨?_, ?_, ?_⟩
  · intro n1 n2 n3
    have e1 : retractableEdge r.edge = false := by
      cases h : retractableEdge r.edge
      · rfl
      · exact absurd (hr.mp h) (by simp [n1, n2, n3])
    simp [admittedExitStep, exitAdmission, retractAdmission, e1]
  · intro hR hO
    have e1 : retractableEdge r.edge = true := hr.mpr hR
    simp [admittedExitStep, exitAdmission, retractAdmission, e1, hO]
  · intro hR hO hW
    have e1 : retractableEdge r.edge = true := hr.mpr hR
    have e3 : inPhase2 s.config r w = false := by
      cases h : inPhase2 s.config r w
      · rfl
      · exact absurd (hp.mp h) hW
    simp [admittedExitStep, exitAdmission, retractAdmission, e1, hO, e3]

/-- An admitted retraction is the retract exit, and admission changes no other exit.

For every state, exit, request, witness, lovelace and rejection evidence: when admission lets the exit
through, the admitted step is exactly `exitStep` and the admitted transaction exactly `txOfExit` —
what the exit pays, what it leaves of the registry and who must sign its transaction are the
exit's own, whatever the witnesses say. -/
theorem admitted_exit_is_the_exit (s : RegistryState) (exit : Exit) (r : Request)
    (w : RetractWitness) (lovelace : Nat) (rejection : Option RejectWitness)
    (admitted : exitAdmission s exit r w rejection = none) :
    admittedExitStep s exit r w rejection = exitStep s exit r ∧
      admittedTxOfExit s exit r w lovelace rejection = txOfExit s exit r lovelace := by
  simp [admittedExitStep, admittedTxOfExit, admitted]

/-- An admission refusal precedes spending and settlement for every exit;
a successfully admitted exit is judged by those existing obligations.

For every state, exit, request, witness, lovelace and rejection evidence: an exit its admission
refuses builds no transaction and is refused with admission's reason whatever the transaction
spends and pays; an exit admission lets through is judged exactly as before: what it spends
(`spendRefusal`), then what it pays (`settle`). -/
theorem admission_refuses_first (s : RegistryState) (exit : Exit) (r : Request)
    (w : RetractWitness) (lovelace : Nat) (rejection : Option RejectWitness) :
    (∀ why, exitAdmission s exit r w rejection = some why →
      admittedTxOfExit s exit r w lovelace rejection = .error why ∧
      ∀ inputs outputs, exitRefusal s exit r w inputs outputs rejection = some why) ∧
    (exitAdmission s exit r w rejection = none →
      ∀ inputs outputs, exitRefusal s exit r w inputs outputs rejection =
        (spendRefusal exit inputs).orElse fun _ => settle (obligations exit r) outputs) := by
  constructor
  · intro why refused
    exact ⟨by simp [admittedTxOfExit, refused],
      fun _ _ => by simp [exitRefusal, refused]⟩
  · intro admitted inputs outputs
    simp [exitRefusal, admitted]

/-- At or before every included request's deadline, admission preserves the batch law. -/
theorem fold_admitted_up_to_the_deadline (s : RegistryState) (batch : List Request)
    (w : FoldWitness) (edges : ∀ r ∈ batch, allowed r.edge = true)
    (window : ∀ r ∈ batch, w.validTo ≤ r.submittedAt + s.config.processTime) :
    foldAdmission s.config batch w = none ∧ admittedFoldBatch s batch w = foldBatch s batch := by
  have he : batch.all (fun r => allowed r.edge) = true := List.all_eq_true.mpr edges
  have hw : batch.all (fun r => inPhase1 s.config r.submittedAt w.validTo) = true := by
    apply List.all_eq_true.mpr
    intro r hr
    simp [inPhase1, window r hr]
  simp [foldAdmission, admittedFoldBatch, he, hw]

/-- One expired member refuses the whole batch, including a singleton, after
the fixed edge set has been checked. -/
theorem fold_refused_past_any_deadline (s : RegistryState) (batch : List Request)
    (w : FoldWitness) (edges : ∀ r ∈ batch, allowed r.edge = true)
    (r : Request) (member : r ∈ batch)
    (past : r.submittedAt + s.config.processTime < w.validTo) :
    foldAdmission s.config batch w = some "not-phase1" ∧
      admittedFoldBatch s batch w = .error "not-phase1" := by
  have he : batch.all (fun r => allowed r.edge) = true := List.all_eq_true.mpr edges
  have hw : batch.all (fun r => inPhase1 s.config r.submittedAt w.validTo) = false := by
    apply List.all_eq_false.mpr
    exact ⟨r, member, by simp [inPhase1]; omega⟩
  simp [foldAdmission, admittedFoldBatch, he, hw]

/-- Admission reads each request's own submission time under one shared bound. -/
theorem fold_admission_judges_each_request_by_its_own_time (c : Config)
    (batch : List Request) (w : FoldWitness) :
    foldAdmission c batch w = none ↔
      (∀ r ∈ batch, allowed r.edge = true) ∧
      (∀ r ∈ batch, w.validTo ≤ r.submittedAt + c.processTime) := by
  have he : (∀ r ∈ batch, allowed r.edge = true) ↔ batch.all (fun r => allowed r.edge) = true :=
    List.all_eq_true.symm
  have hw : (∀ r ∈ batch, w.validTo ≤ r.submittedAt + c.processTime) ↔
      batch.all (fun r => inPhase1 c r.submittedAt w.validTo) = true := by
    simp [List.all_eq_true, inPhase1]
  rw [he, hw]
  cases h₁ : batch.all (fun r => allowed r.edge) <;>
    cases h₂ : batch.all (fun r => inPhase1 c r.submittedAt w.validTo) <;>
    simp [foldAdmission, h₁, h₂]

/-- Any excluded edge wins over every window, even when another request expired. -/
theorem fixed_edge_set_precedes_the_window (c : Config) (batch : List Request)
    (w : FoldWitness) (r : Request) (member : r ∈ batch) (excluded : allowed r.edge = false) :
    foldAdmission c batch w = some "edge-inadmissible" := by
  have he : batch.all (fun r => allowed r.edge) = false :=
    List.all_eq_false.mpr ⟨r, member, by simp [excluded]⟩
  simp [foldAdmission, he]

/-- Admission precedes approval, leaf, ordered steps, mint and burns; the
singleton exit uses the same answer before it steps or builds. -/
theorem fold_admission_precedes_the_law (s : RegistryState) (batch : List Request)
    (w : FoldWitness) (why : String) (refused : foldAdmission s.config batch w = some why) :
    admittedFoldBatch s batch w = .error why ∧
      ∀ (r : Request) (rw : RetractWitness) (lovelace : Nat), batch = [r] → rw.validTo = w.validTo →
        admittedExitStep s (.fold r.edge) r rw = .error why ∧
        admittedTxOfExit s (.fold r.edge) r rw lovelace = .error why := by
  refine ⟨by simp [admittedFoldBatch, refused], ?_⟩
  intro r rw lovelace hb hw
  subst batch
  have single : foldAdmission s.config [r] { validTo := rw.validTo } = some why := by
    simpa [hw] using refused
  simp [admittedExitStep, admittedTxOfExit, exitAdmission, single]


end Singular.Statements
