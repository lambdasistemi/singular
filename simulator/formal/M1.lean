import Singular.Model

/-! Compatibility names for the sole active permanent contract. There is no
 broader execution path: every entry below names the same Singular definition. -/
namespace Singular.M1

abbrev allowed := Singular.allowed
abbrev step := Singular.step
abbrev foldActions := Singular.foldActions
abbrev foldBatch := Singular.foldBatch
abbrev admittedExitStep := Singular.admittedExitStep
abbrev admittedTxOfExit := Singular.admittedTxOfExit
abbrev buildFold := Singular.buildFold
abbrev Reachable := Singular.Reachable

namespace Statements

theorem admission_exactly_two (edge : Edge) :
    allowed edge = true ↔ edge = .insertActive ∨ edge = .updateTerminal := by
  cases edge <;> simp [allowed, Singular.allowed]

theorem excluded_step (state : RegistryState) (request : Request)
    (excluded : allowed request.edge = false) :
    step state request = .error "edge-inadmissible" := by
  simp [step, Singular.step, Singular.refusal, excluded]

theorem allowed_step_unchanged (state : RegistryState) (request : Request)
    (admitted : allowed request.edge = true) :
    step state request = Singular.step state request := by
  simp [step, admitted]

theorem successful_step_allowed (state : RegistryState) (request : Request) (result : Result)
    (success : step state request = .ok result) : allowed request.edge = true := by
  cases he : request.edge <;>
    simp_all [allowed, Singular.allowed, step, Singular.step, Singular.refusal]

theorem successful_batch_members_allowed (state : RegistryState) (batch : List Request) (result : Result)
    (success : foldActions state batch = .ok result) :
    ∀ request ∈ batch, allowed request.edge = true := by
  induction batch generalizing state result with
  | nil => simp
  | cons request rest ih =>
    simp only [foldActions, Singular.foldActions, bind, Except.bind, pure, Except.pure] at success
    cases first : Singular.step state request with
    | error why => simp [first] at success
    | ok intermediate =>
      rw [first] at success
      cases following : Singular.foldActions intermediate.state rest with
      | error why => simp [following] at success
      | ok after =>
        intro member present
        rcases List.mem_cons.mp present with same | remaining
        · subst member
          exact successful_step_allowed state request intermediate first
        · exact ih intermediate.state after following member remaining

theorem reachable_uses_active_model (state : RegistryState) (reachable : Reachable state) :
    Singular.Reachable state := by
  exact reachable

theorem excluded_fold (state : RegistryState) (request : Request) (witness : RetractWitness)
    (excluded : allowed request.edge = false) :
    admittedExitStep state (.fold request.edge) request witness =
      .error "edge-inadmissible" := by
  simp [admittedExitStep, Singular.admittedExitStep, Singular.exitAdmission,
    Singular.exitStep, Singular.step, Singular.refusal, excluded]

theorem reject_unchanged (state : RegistryState) (request : Request) (witness : RetractWitness) :
    admittedExitStep state .reject request witness =
      Singular.admittedExitStep state .reject request witness := by
  rfl

theorem retract_unchanged (state : RegistryState) (request : Request) (witness : RetractWitness) :
    admittedExitStep state .retract request witness =
      Singular.admittedExitStep state .retract request witness := by
  rfl

theorem excluded_batch_head (state : RegistryState) (request : Request) (rest : List Request)
    (excluded : allowed request.edge = false) :
    foldBatch state (request :: rest) = .error "edge-inadmissible" := by
  simp [foldBatch, Singular.foldBatch, foldActions, Singular.foldActions, step,
    Singular.step, Singular.refusal, excluded, bind, Except.bind, pure, Except.pure]

end Statements
end Singular.M1
