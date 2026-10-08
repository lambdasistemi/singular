import Singular.Model

/-! The permanent M1 contract, authorized on 8 October 2026. The broader
contract remains `Singular`; this surface changes only fold admission. Its
admission set is a definition, never a registry configuration field. Rejected
and retracted requests retain the original exits, including excluded requests
which a caller can place at the request address without using our builder. -/

namespace Singular.M1

def allowed (edge : Edge) : Bool :=
  edge == .insertActive || edge == .updateTerminal

def step (state : RegistryState) (request : Request) : Except String Result :=
  if allowed request.edge then Singular.step state request
  else .error "edge-inadmissible"

def foldActions (state : RegistryState) (batch : List Request) : Except String Result :=
  match batch with
  | [] => .ok (emptyResult state)
  | request :: rest => do
    let first ← step state request
    let after ← foldActions first.state rest
    pure (combineResults first after)

def foldBatch (state : RegistryState) (batch : List Request) : Except String Result := do
  if batch.isEmpty then throw "empty-fold"
  let result ← foldActions state batch
  if assetSame (claimedMint batch) (actualMint batch) then pure result
  else throw "net-mint-mismatch"

def admittedExitStep (state : RegistryState) (exit : Exit) (request : Request)
    (witness : RetractWitness) : Except String Result :=
  match exit with
  | .fold edge =>
      if request.edge != edge then .error "exit-edge-mismatch"
      else if !allowed edge then .error "edge-inadmissible"
      else Singular.admittedExitStep state exit request witness
  | .reject | .retract => Singular.admittedExitStep state exit request witness

def admittedTxOfExit (state : RegistryState) (exit : Exit) (request : Request)
    (witness : RetractWitness) (lovelace : Nat) : Except String Tx := do
  let _ ← admittedExitStep state exit request witness
  Singular.admittedTxOfExit state exit request witness lovelace

def buildFold (view : PublicView) (reference lovelace : Nat) : Except String Tx :=
  match view.pending.find? (·.reference == reference) with
  | none => .error "request-not-pending"
  | some request => admittedTxOfExit view.registry (.fold request.edge) request
      { submittedAt := 0, validFrom := 0, validTo := 0, signatories := [] } lovelace

inductive Reachable : RegistryState → Prop where
  | initial (config : Config) : Reachable
      { config := { config with root := rootOf [] }, trie := [], custody := [], held := [] }
  | next {state : RegistryState} {request : Request} {result : Result} :
      Reachable state → step state request = .ok result → Reachable result.state

namespace Statements

theorem admission_exactly_two (edge : Edge) :
    allowed edge = true ↔ edge = .insertActive ∨ edge = .updateTerminal := by
  cases edge <;> simp [allowed]

theorem excluded_step (state : RegistryState) (request : Request)
    (excluded : allowed request.edge = false) :
    step state request = .error "edge-inadmissible" := by
  simp [step, excluded]

theorem allowed_step_unchanged (state : RegistryState) (request : Request)
    (admitted : allowed request.edge = true) :
    step state request = Singular.step state request := by
  simp [step, admitted]

theorem successful_step_allowed (state : RegistryState) (request : Request) (result : Result)
    (success : step state request = .ok result) : allowed request.edge = true := by
  unfold step at success
  split at success
  next admitted => exact admitted
  next _ => contradiction

theorem successful_batch_members_allowed (state : RegistryState) (batch : List Request) (result : Result)
    (success : foldActions state batch = .ok result) :
    ∀ request ∈ batch, allowed request.edge = true := by
  induction batch generalizing state result with
  | nil => simp
  | cons request rest ih =>
    simp only [foldActions, bind, Except.bind, pure, Except.pure] at success
    cases first : step state request with
    | error why => simp [first] at success
    | ok intermediate =>
      rw [first] at success
      cases following : foldActions intermediate.state rest with
      | error why => simp [following] at success
      | ok after =>
        intro member present
        rcases List.mem_cons.mp present with same | remaining
        · subst member
          exact successful_step_allowed state request intermediate first
        · exact ih intermediate.state after following member remaining

theorem reachable_preserves_broader_laws (state : RegistryState) (reachable : Reachable state) :
    Singular.Reachable state := by
  induction reachable with
  | initial config => exact Singular.Reachable.initial config
  | @next before request result _ success ih =>
    have admitted := successful_step_allowed before request result success
    rw [allowed_step_unchanged before request admitted] at success
    exact Singular.Reachable.next ih success

theorem excluded_fold (state : RegistryState) (request : Request) (witness : RetractWitness)
    (excluded : allowed request.edge = false) :
    admittedExitStep state (.fold request.edge) request witness =
      .error "edge-inadmissible" := by
  simp [admittedExitStep, excluded]

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
  simp [foldBatch, foldActions, step, excluded, bind, Except.bind, pure, Except.pure]

end Statements
end Singular.M1
