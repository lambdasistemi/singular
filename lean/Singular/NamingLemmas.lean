import Singular.Naming

/-! Proof-side helpers for the naming statements. Nothing here is part of the
public statement inventory; these lemmas exist so the statements in
`Singular.NamingStatements` stay readable. -/
namespace Singular

/-- Bind reduction on the claim-typed Except. -/
theorem exceptBindOkClaim (x : NamingClaim) (f : NamingClaim → Except String NamingResult) :
    (Except.bind (Except.ok x : Except String NamingClaim) f : Except String NamingResult) = f x := rfl

/-- Bind reduction on the action-typed Except (ok case, raw bind). -/
theorem exceptBindOkAction (x : Action) (f : Action → Except String NamingResult) :
    (Except.bind (Except.ok x : Except String Action) f : Except String NamingResult) = f x := rfl

/-- Bind reduction on the action-typed Except (error case, raw bind). -/
theorem exceptBindErrAction (e : String) (f : Action → Except String NamingResult) :
    (Except.bind (Except.error e : Except String Action) f : Except String NamingResult) = Except.error e := rfl

/-- Bind reduction from the generic registry result into a naming result. -/
theorem exceptBindOkRegistryResult (x : Result) (f : Result → Except String NamingResult) :
    (Except.bind (Except.ok x : Except String Result) f : Except String NamingResult) = f x := rfl

/-- Error bind reduction from the generic registry result into a naming result. -/
theorem exceptBindErrRegistryResult (e : String) (f : Result → Except String NamingResult) :
    (Except.bind (Except.error e : Except String Result) f : Except String NamingResult) = Except.error e := rfl

/-- Polymorphic bind reductions used for small validation pipelines. -/
@[simp] theorem exceptBindOkAny { α β : Type } (x : α) (f : α → Except String β) :
    (Except.bind (Except.ok x : Except String α) f : Except String β) = f x := rfl

@[simp] theorem exceptBindErrAny { α β : Type } (e : String) (f : α → Except String β) :
    (Except.bind (Except.error e : Except String α) f : Except String β) = Except.error e := rfl

/-- Polymorphic functor-map reductions used after an early validation result. -/
@[simp] theorem exceptMapOkAny { α β : Type } (x : α) (f : α → β) :
    f <$> (Except.ok x : Except String α) = (Except.ok (f x) : Except String β) := rfl

@[simp] theorem exceptMapErrAny { α β : Type } (e : String) (f : α → β) :
    f <$> (Except.error e : Except String α) = (Except.error e : Except String β) := rfl

/-- Map is the corresponding bind followed by `Except.ok`. -/
theorem exceptMapEqAny { α β : Type } (x : Except String α) (f : α → β) :
    (Except.map f x : Except String β) = Except.bind x (fun y => Except.ok (f y)) := rfl

/-- Bind reduction on the action-typed Except (general case, typeclass bind). -/
theorem exceptBindResultEqAction (x : Except String Action) (f : Action → Except String NamingResult) :
    (Except.bind x f : Except String NamingResult) =
      match x with
      | Except.ok v => f v
      | Except.error e => Except.error e := by
  cases x <;> rfl

/-- Map/bind relation on the result-typed Except. -/
theorem exceptMapEq (x : Except String NamingResult) (f : NamingResult → NamingResult) :
    (Except.map f x : Except String NamingResult) = Except.bind x (fun y => Except.ok (f y)) := rfl

/-- Throw in the Except monad is Except.error. -/
theorem throwEqError {α : Type} (s : String) : (throw s : Except String α) = Except.error s := rfl

theorem insertNeSelfFalse : ((Operation.insert : Operation) != Operation.insert) = false := rfl

/-- The fold branch of the naming transition, with the terminal guard and the
monadic plumbing made explicit. -/
theorem namingStepFoldActionEq (state : NamingState) (items : List FoldItem)
    (mint : List Delta) (net : List ActionDelta) (w : Witnesses) :
    namingStep state (Action.fold items mint net w) =
      (if (items.any fun i =>
            match state.registry.requests.find? (fun x => x.id == i.request) with
            | some q => q.operation != Operation.insert
            | none => false) = true then
        (Except.error "naming-no-delete" : Except String NamingResult)
      else
        Except.bind (step state.registry (Action.fold items mint net w))
          (fun res => (Except.ok : NamingResult → Except String NamingResult)
            { state := migrateClaims state items res.state, logical := res.logical })) := rfl

/-- The else branch's do-sequence is the bind of the certified fold's step. -/
theorem foldElseBindEq (state : NamingState) (items : List FoldItem)
    (mint : List Delta) (net : List ActionDelta) (w : Witnesses) :
    (do pure PUnit.unit
        let result ← step state.registry (Action.fold items mint net w)
        pure { state := migrateClaims state items result.state, logical := result.logical } :
      Except String NamingResult) =
      Except.bind (step state.registry (Action.fold items mint net w))
        (fun result => (Except.ok : NamingResult → Except String NamingResult)
          { state := migrateClaims state items result.state, logical := result.logical }) := rfl

/-- The naming terminal guard fires only for a non-Insert queued request. -/
theorem namingTerminalFalse (state : NamingState) (items : List FoldItem)
    (ht : ∀ (i : FoldItem) (q : Request),
        state.registry.requests.find? (fun x => x.id == i.request) = some q →
        q.operation = Operation.insert) :
    (items.any fun i =>
        match state.registry.requests.find? (fun x => x.id == i.request) with
        | some q => q.operation != Operation.insert
        | none => false) = true → False := by
  intro hb
  rcases List.any_eq_true.mp hb with ⟨i, _hi, htrue⟩
  cases hr : state.registry.requests.find? (fun x => x.id == i.request) with
  | none => rw [hr] at htrue; simp at htrue
  | some r =>
    rw [hr] at htrue
    revert htrue
    cases hop : r.operation with
      | insert =>
        intro htrue
        dsimp only at htrue
        rw [hop] at htrue
        have hneg : ¬(((Operation.insert : Operation) != Operation.insert) = true) := by decide
        exact absurd htrue hneg
      | delete =>
        intro _htrue
        exact absurd (hop.symm.trans (ht i r hr)) (by decide)
      | update =>
        intro _htrue
        exact absurd (hop.symm.trans (ht i r hr)) (by decide)

/-- Generalized fixture preservation: a successful certified fold of an
arbitrary queued claim moves that claim's fixture, unchanged, into an active
record keyed by the claim's key. -/
theorem namingFoldInsertPreservesFixture (state : NamingState) (claim : NamingClaim)
    (r : Request) (result : NamingResult)
    (hc : state.claims.find? (fun c => c.requestId == claim.requestId) = some claim)
    (hr : state.registry.requests.find? (fun q => q.id == claim.requestId) = some r)
    (hop : r.operation = Operation.insert)
    (hok : (namingFoldAction state claim.requestId).bind (namingStep state) = .ok result) :
    ∃ rec, rec.key = claim.key ∧ rec.fixture = claim.fixture ∧ rec ∈ result.state.records := by
  rw [namingFoldAction, hr] at hok
  simp only [exceptBindOkAction] at hok
  simp only [namingStep, List.any_cons, List.any_nil] at hok
  rw [hr] at hok
  dsimp only at hok
  rw [hop] at hok
  simp only [insertNeSelfFalse, Bool.or_false, Bool.false_eq_true, if_false] at hok
  rw [foldElseBindEq] at hok
  cases hs : step state.registry (Action.fold [{ request := claim.requestId, outputId := freshId state.registry, output := some r.proposal.initial }] [{ asset := representative state.registry r.proposal.key, quantity := 1 }] [] { nativeSpend := true, representativeMint := true, consumerWithdraw := true }) with
  | error =>
    rw [hs] at hok
    rw [exceptBindErrRegistryResult] at hok
    exact absurd hok (by simp)
  | ok res =>
    rw [hs] at hok
    rw [exceptBindOkRegistryResult, Except.ok.injEq] at hok
    subst result
    let record : NamingRecord :=
      { outputId := freshId state.registry
        key := claim.key
        representative := representative res.state claim.key
        fixture := claim.fixture }
    refine ⟨record, rfl, rfl, ?_⟩
    simp [record, migrateClaims, hc]

end Singular
