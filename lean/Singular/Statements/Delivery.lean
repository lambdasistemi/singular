import Singular.Lemmas
import Singular.Driver
import Singular.Economics

/-! Destination presence, datum identity, public inputs, foreign datum refusal and all five anonymous examples. -/

namespace Singular.Statements

/-- **#304** — a fold's transaction describes a destination output exactly when
the fold routes a token to the requester.

For every state, request, lovelace and admitted fold, over all seven edges: the
built outputs contain an output in the destination role if and only if the
edge's routing sends a token to the request's output. A fold that delivers
nothing — an absent insertion, whose token goes to custody, or a retirement or
deletion, which burn — describes no destination output, so none can be invented
for a comparison to agree with. The state, custody and owner outputs never take
the destination role. -/
theorem destination_output_iff_delivers (s : RegistryState) (r : Request) (lovelace : Nat)
    (t : Result) (tx : Tx) (hok : step s r = .ok t) (htx : txOf s r lovelace = .ok tx) :
    tx.outputs.any (·.role == .destination) = !(routedPayment t r .requestOutput).isEmpty := by
  rw [txOf_of_step_ok s r lovelace t hok] at htx
  injection htx with htx
  subst htx
  have hcage : (txCageOutputs t r).any (·.role == .destination) = false := by
    unfold txCageOutputs
    dsimp only
    split <;> rfl
  have howner : ∀ (d : DatumForm) (c : Option Nat) (ps : List Payment),
      (ownerOutputs d c ps).any (·.role == .destination) = false := by
    intro d c ps
    simp only [ownerOutputs, List.any_eq_false, List.mem_filterMap]
    rintro o ⟨p, -, hp⟩
    split at hp <;> (cases hp; try (intro h; cases h))
  have hdest : ∀ f : TxOutput → TxOutput, (∀ o, (f o).role = o.role) →
      ((txDestinationOutputs t r).map f).any (·.role == .destination)
        = !(routedPayment t r .requestOutput).isEmpty := by
    intro f hf
    unfold txDestinationOutputs
    dsimp only
    split
    · rename_i h
      simp [h]
    · rename_i h
      rw [Bool.eq_false_iff.mpr h]
      simp only [List.map_cons, List.map_nil, List.any_cons, List.any_nil, hf,
        Bool.or_false, Bool.not_false]
      rfl
  simp only [List.any_cons, List.any_append, hcage, howner, Bool.or_false]
  rw [hdest]
  · rfl
  · intro o
    rfl

/-- **#304** — a witness a fold spends presents the datum its holding carries: for
every state, request, lovelace and admitted fold, over all seven edges, each input
in the witness role presents, for the asset it supplies, the datum the state
records for that holding, in its form and its value. A holding records the datum
the fold that delivered it wrote, the request's own (as the inversions state), so
a retirement or a deletion spends a witness as the chain holds it. -/
theorem witness_input_datum_is_held (s : RegistryState) (r : Request) (lovelace : Nat)
    (t : Result) (tx : Tx) (hok : step s r = .ok t) (htx : txOf s r lovelace = .ok tx) :
    ∀ i ∈ tx.inputs, i.role = .witness → ∀ a ∈ i.assets,
      i.datum = heldDatum s a.1.2 a.1.1 ∧ i.datumValue = heldValue s a.1.2 a.1.1 := by
  rw [txOf_of_step_ok s r lovelace t hok] at htx
  injection htx with htx
  subst htx
  intro i hi hrole a ha
  dsimp only at hi
  rw [List.mem_append, List.mem_cons, List.mem_cons] at hi
  rcases hi with (hi | hi | hi) | hi
  · subst hi
    simp at hrole
  · subst hi
    simp at hrole
  · simp at hi
  · rw [txBurnInputs, List.mem_filterMap] at hi
    obtain ⟨p, -, hp⟩ := hi
    split at hp
    · cases hp
      simp only [List.mem_singleton] at ha
      subst ha
      simp only [burnSourceRole] at hrole
      simp only [burnSourceDatum, burnSourceValue]
      split at hrole <;> simp_all
    · cases hp

/-- By value: a delivered output carries the request's datum inline when the
request carries one, and no datum when it carries none. -/
example (s : RegistryState) (k : Key) :
    (txDestinationOutputs { state := s, mint := [((.active, k), 1)], paid := [] }
      { edge := .insertActive, key := k, datum := some 7 }).map (fun o => (o.datum, o.datumValue))
      = [(.inline, some 7)] := by
  simp +decide [txDestinationOutputs, routedPayment, mintRoutedTo, route, deliveredDatum, datumFormOf]

example (s : RegistryState) (k : Key) :
    (txDestinationOutputs { state := s, mint := [((.active, k), 1)], paid := [] }
      { edge := .insertActive, key := k }).map (fun o => (o.datum, o.datumValue))
      = [(.none, none)] := by
  simp +decide [txDestinationOutputs, routedPayment, mintRoutedTo, route, deliveredDatum, datumFormOf]

/-- By value, one edge each way: an absent insertion routes its token to custody
and describes no destination output. -/
example (s : RegistryState) (k : Key) :
    txDestinationOutputs { state := s, mint := [((.absent, k), 1)], paid := [] }
      { edge := .insertAbsent, key := k } = [] := by
  simp +decide [txDestinationOutputs, routedPayment, mintRoutedTo, route]

/-- By value: an active insertion routes its token to the requester and
describes exactly one destination output. -/
example (s : RegistryState) (k : Key) :
    (txDestinationOutputs { state := s, mint := [((.active, k), 1)], paid := [] }
      { edge := .insertActive, key := k }).length = 1 := by
  simp +decide [txDestinationOutputs, routedPayment, mintRoutedTo, route]

/-! ### Public fold inputs (#419)

A fold is built from what the chain shows: the registry's state output, the
holdings it commits to and the pending requests at the cage. The request carries
the datum it names, so no booker's file is an input of any fold. -/

/-- **#419, the delivered datum is the request's datum** — for every state,
request, lovelace and admitted fold, over all seven edges, each output in the
destination role carries exactly the datum the request carries: inline with that
value when the request carries one, no datum when it carries none. -/
theorem delivered_datum_is_request_datum (s : RegistryState) (r : Request)
    (lovelace : Nat) (t : Result) (tx : Tx) (hok : step s r = .ok t)
    (htx : txOf s r lovelace = .ok tx) :
    ∀ o ∈ tx.outputs, o.role = .destination →
      o.datum = datumFormOf r.datum ∧ o.datumValue = r.datum := by
  rw [txOf_of_step_ok s r lovelace t hok] at htx
  injection htx with htx
  subst htx
  intro o ho hrole
  dsimp only at ho
  rw [List.mem_append, List.mem_append, List.mem_cons] at ho
  rcases ho with ((ho | ho) | ho) | ho
  · subst ho
    simp [txStateOutput] at hrole
  · rw [List.mem_map] at ho
    obtain ⟨d, hd, rfl⟩ := ho
    unfold txDestinationOutputs at hd
    dsimp only at hd
    split at hd
    · simp at hd
    · rw [List.mem_singleton] at hd
      subst hd
      exact ⟨rfl, rfl⟩
  · unfold txCageOutputs at ho
    dsimp only at ho
    split at ho
    · simp at ho
    · rw [List.mem_singleton] at ho
      subst ho
      simp at hrole
  · rw [ownerOutputs, List.mem_filterMap] at ho
    obtain ⟨p, -, hp⟩ := ho
    split at hp <;> (cases hp <;> simp at hrole)

/-- **#419, fold inputs are public** — for every state, request and lovelace, the
transaction a fold builds is the one any party builds from the public view: the
registry state as its outputs show it, with the holdings and their datums, and
the request pending at the cage, found by its own output reference. -/
theorem fold_inputs_public (s : RegistryState) (r : Request) (lovelace : Nat) :
    txOf s r lovelace = buildFold (publicView s [r]) r.reference lovelace := by
  simp [buildFold, publicView]

/-- **#419, a foreign datum is refused** — for every request delivering a token
(`insertActive`), whatever its deposit, an
observed fold whose every destination output carries a datum other than the
request's — another value, a datum where the request carries none, none where it
carries one, a datum presented by hash — or that has no destination output at
all, is refused `destination`, as the cage refuses a carrier that does not match
the destination the request names. -/
theorem fold_refuses_foreign_datum (r : Request) (outputs : List TxOutput)
    (hdelivers : r.edge = .insertActive)
    (hforeign : ∀ o ∈ outputs, o.role = .destination →
      (∀ v, r.datum = some v → o.datum ≠ .inline ∨ o.datumValue ≠ some v) ∧
      (r.datum = none → o.datum ≠ .none)) :
    settle (obligations (.fold r.edge) r) outputs = some "destination" := by
  have hpaying : outputs.filter (paysRecipient (.destination (requestDestination r) r.datum)) = [] := by
    rw [List.filter_eq_nil_iff]
    intro o ho
    cases hr : o.role
    case destination =>
      obtain ⟨h1, h2⟩ := hforeign o ho hr
      cases hd : r.datum with
      | none =>
        have h := h2 hd
        cases hod : o.datum <;> simp_all +decide [paysRecipient, presentsDatum]
      | some v =>
        rcases h1 v hd with h | h <;> cases hod : o.datum <;>
          simp_all +decide [paysRecipient, presentsDatum]
    all_goals simp +decide [paysRecipient, hr]
  have hob : obligations (.fold r.edge) r =
      [{ recipient := .destination (requestDestination r) r.datum, atLeast := r.deposit }] := by
    rw [hdelivers]
    rfl
  rw [hob]
  have hnone : ∀ o ∈ outputs,
      paysRecipient (.destination (requestDestination r) r.datum) o = false := by
    simpa [List.filter_eq_nil_iff] using hpaying
  simp [settle, requiresCarrier, unpaidReason, hpaying, List.eraseDups_cons]
  rw [if_pos hnone, if_pos hnone]


/-- By value: an active insertion whose request carries no datum, observed paying
its destination through an output carrying an inline datum, is refused
`destination`. -/
example :
    settle (obligations (.fold .insertActive)
        { edge := .insertActive, key := 5, output := 99, deposit := 2 })
      [{ role := .destination, datum := .inline, address := some 99, stateTokens := 0
       , config := none, commitment := none, assets := [], lovelace := 2 }]
      = some "destination" := by
  decide


end Singular.Statements
