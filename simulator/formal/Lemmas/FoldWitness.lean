import Singular.Lemmas.FoldSums

/-! Finite model witnesses for a booked termination. These constructions do
not claim a ledger UTxO set, minimum output value or a transaction builder. -/

namespace Singular

def worldRequestReferences (world : World) : List OutRef :=
  world.pending.map (·.request.reference) ++ world.terminations.map (·.request.reference)

theorem reachable_request_references (world : World) (reachable : WorldReachable world) :
    (worldRequestReferences world).Nodup := by
  induction reachable with
  | initial registry reachable => simp [worldRequestReferences]
  | @booking before after reach transaction accepted ih =>
    unfold book at accepted
    split at accepted
    · contradiction
    · split at accepted
      · contradiction
      next fresh =>
        cases accepted
        simp only [worldRequestReferences, List.map_cons, List.cons_append, List.nodup_cons]
        refine ⟨?_, ih⟩
        simpa only [worldRequestReferences, List.mem_append, List.mem_map,
          Bool.or_eq_true, List.any_eq_true, decide_eq_true_eq] using fresh
  | @termination before after reach transaction accepted ih =>
    unfold bookTermination at accepted
    split at accepted
    · contradiction
    · split at accepted
      · contradiction
      next fresh =>
        cases accepted
        have absent : transaction.request.reference ∉ worldRequestReferences before := by
          simpa only [worldRequestReferences, List.mem_append, List.mem_map,
          Bool.or_eq_true, List.any_eq_true, decide_eq_true_eq] using fresh
        have front : (transaction.request.reference :: worldRequestReferences before).Nodup :=
          List.nodup_cons.mpr ⟨absent, ih⟩
        exact (List.perm_cons_append_cons transaction.request.reference (List.Perm.refl _)).nodup front
  | @rejection before after reach unspent transaction accepted ih =>
    rw [rejectionAccepted_effect accepted]
    exact ih.sublist (List.Sublist.append
      (List.Sublist.map _ List.filter_sublist) (List.Sublist.refl _))
  | @retraction before after reach unspent transaction accepted ih =>
    rw [retractionAccepted_effect accepted]
    exact ih.sublist (List.Sublist.append
      (List.Sublist.map _ List.filter_sublist) (List.Sublist.refl _))
  | @fold before after reach unspent transaction accepted ih =>
    unfold worldRequestReferences
    rw [(foldAccepted_pending accepted).1, (foldAccepted_pending accepted).2]
    exact ih.sublist (List.Sublist.append
      (List.Sublist.map _ List.filter_sublist) (List.Sublist.map _ List.filter_sublist))

theorem foldActions_root {registry : RegistryState} {members : List Request} {result : Result}
    (root : registry.config.root = rootOf registry.trie)
    (accepted : foldActions registry members = .ok result) :
    result.state.config.root = rootOf result.state.trie := by
  induction members generalizing registry result with
  | nil => simp [foldActions] at accepted; subst result; exact root
  | cons member rest ih =>
    cases first : step registry member with
    | error why => simp [foldActions, first, bind, Except.bind] at accepted
    | ok next =>
      cases later : foldActions next.state rest with
      | error why => simp [foldActions, first, later, bind, Except.bind] at accepted
      | ok last =>
        simp [foldActions, first, later, bind, Except.bind, pure, Except.pure] at accepted
        subst result
        have nextRoot : next.state.config.root = rootOf next.state.trie := by
          rw [(step_eq_ok registry member next first).2]
          cases edge : member.edge <;> simp [applyEdge, edge, root]
        exact ih (result := last) nextRoot later

theorem reachable_world_root (world : World) (reachable : WorldReachable world) :
    world.registry.config.root = rootOf world.registry.trie := by
  induction reachable with
  | initial registry reachable => exact (reachable_consistent registry reachable).1
  | @booking before after reach transaction accepted ih =>
    unfold book at accepted
    repeat (split at accepted <;> try contradiction)
    cases accepted; exact ih
  | @termination before after reach transaction accepted ih =>
    unfold bookTermination at accepted
    repeat (split at accepted <;> try contradiction)
    cases accepted; exact ih
  | @rejection before after reach unspent transaction accepted ih =>
    rw [rejectionAccepted_effect accepted]; exact ih
  | @retraction before after reach unspent transaction accepted ih =>
    rw [retractionAccepted_effect accepted]; exact ih
  | @fold before after reach unspent transaction accepted ih =>
    obtain ⟨_, result, registry, _, effect⟩ := foldAccepted_checks accepted
    rw [effect]
    exact foldActions_root (registry := foldProjectedRegistry before) ih
      (foldBatch_inv _ _ _ registry).2

def terminationWitnessFresh (world : World) : Nat :=
  ((worldRequestReferences world).map (·.tx)).sum + 1

def foldWitnessOrdinary (amount : Nat) : EconomicOutput :=
  let output : TxOutput :=
    { role := .owner, datum := .none, lovelace := amount, assets := [],
      address := some 0, stateTokens := 0, config := none, commitment := none }
  { output, contents := { lovelace := amount, trieReadyTags := [], applicationTags := [] } }

def registrationWitnessOutput (booking : RegistrationBooking) : EconomicOutput :=
  { output := { (foldWitnessOrdinary booking.request.contents.lovelace).output with
      role := .request, datum := .inline }, contents := booking.request.contents,
    request := some (.registration booking.request) }

def terminationWitnessOutput (booking : TerminationBooking) : EconomicOutput :=
  { output := { (foldWitnessOrdinary booking.request.contents.lovelace).output with
      role := .request, datum := .inline }, contents := booking.request.contents,
    singularTags := booking.request.singularTags, request := some (.termination booking.request) }

def foldWitnessState (config : Config) : EconomicOutput :=
  { foldWitnessOrdinary 0 with output := { (foldWitnessOrdinary 0).output with
      role := .state, datum := .inline, config := some config,
      stateToken := some config.stateToken, stateTokens := 1, address := none } }

/-- Every pending observation comes from its retained booking. The two fresh
references provide the state and the explicitly supplied ordinary funding. -/
def terminationWitnessUnspent (world : World) (funding : Nat) : EconomicUtxo :=
  world.pending.map (fun b => (b.request.reference, registrationWitnessOutput b)) ++
  world.terminations.map (fun b => (b.request.reference, terminationWitnessOutput b)) ++
  [(⟨terminationWitnessFresh world, 0⟩, foldWitnessState world.registry.config),
   (⟨terminationWitnessFresh world, 1⟩, foldWitnessOrdinary funding)]

end Singular
