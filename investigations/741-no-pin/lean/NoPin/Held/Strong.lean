import NoPin.Held.Instances

/-! Satisfying and violating instances of the novel #741 obligations, not accepted law. -/
set_option maxRecDepth 8192
set_option maxHeartbeats 2000000
namespace NoPin.Held.Instances
open Singular Fixtures

/-- Hypothesis instance under #741, not accepted law; mirrors the general pending_paths_refused premise. -/
abbrev pending_paths_refused_premise (m : Mutation) (hash : Hash) (code : Codec) (s : ApplicationState)
    (p next : Pending) (signers : List Nat) : Prop :=
  True
/-- Hypothesis instance under #741, not accepted law; mirrors the general pending_paths_refused claim. -/
abbrev pending_paths_refused_claim (m : Mutation) (hash : Hash) (code : Codec) (s : ApplicationState)
    (p next : Pending) (signers : List Nat) : Prop :=
  liveSpend m .update (.pending p) = false ∧
  liveSpend m .release (.pending p) = false ∧
  book m hash code s (.pending p) next signers = false

/-- Hypothesis instance under #741, not accepted law; mirrors the general booking_retains premise. -/
abbrev booking_retains_premise (m : Mutation) (hash : Hash) (code : Codec) (s : ApplicationState)
    (h : Holding) (p : Pending) (signers : List Nat) : Prop :=
  book m hash code s (.live h) p signers = true
/-- Hypothesis instance under #741, not accepted law; mirrors the general booking_retains claim. -/
abbrev booking_retains_claim (m : Mutation) (hash : Hash) (code : Codec) (s : ApplicationState)
    (h : Holding) (p : Pending) (signers : List Nat) : Prop :=
  h.control.controller ∈ signers ∧ p.holding.family = h.family ∧
  p.holding.control = h.control ∧ p.holding.token = h.token ∧
  p.holding.quantity = 1 ∧ p.holding.provenance = h.provenance ∧
  p.holding.payload = h.payload ∧
  terminationBookingRefusal (project s).registry p.booking = none ∧
  p.holding.lovelace = p.booking.request.contents.lovelace + p.holding.control.deposit ∧
    genuine .none hash code s.registry.config (.pending p) = true ∧
    bookTermination (project s) p.booking = .ok (project (bookEffect s (.live h) p))

/-- Hypothesis instance under #741, not accepted law; mirrors the general pending_witness_authentication premise. -/
abbrev pending_witness_authentication_premise (m : Mutation) (hash : Hash) (code : Codec) (c : Config) (p : Pending) : Prop :=
  genuine m hash code c (.pending p) = true
/-- Hypothesis instance under #741, not accepted law; mirrors the general pending_witness_authentication claim. -/
abbrev pending_witness_authentication_claim (m : Mutation) (hash : Hash) (code : Codec) (c : Config) (p : Pending) : Prop :=
  p.holding.token = roleAsset hash code p.holding.control.registry .witness p.holding.control.key ∧
  p.holding.quantity = 1 ∧ p.holding.provenance = p.holding.token ∧
  terminationExactContents c p.booking.request = true

/-- Hypothesis instance under #741, not accepted law; mirrors the general release_terminal premise. -/
abbrev release_terminal_premise (m : Mutation) (hash : Hash) (code : Codec) (c : Config) (p : Pending)
    (tx : LocalTransaction) (o : FoldObservation) : Prop :=
  (pendingRelease m hash code c p tx = true ∧
    BurnCoupling p.holding.control.registry p.holding.control.key p.holding.token tx.assets o)
/-- Hypothesis instance under #741, not accepted law; mirrors the general release_terminal claim. -/
abbrev release_terminal_claim (m : Mutation) (hash : Hash) (code : Codec) (c : Config) (p : Pending)
    (tx : LocalTransaction) (o : FoldObservation) : Prop :=
  mintQty tx.assets p.holding.token = -1 ∧ acceptedFold o = true ∧
  trieGet o.after.registry.trie p.holding.control.key = .known .terminal

/-- Hypothesis instance under #741, not accepted law; mirrors the general additive_settlement premise. -/
abbrev additive_settlement_premise (m : Mutation) (hash : Hash) (code : Codec) (c : Config) (p : Pending)
    (tx : LocalTransaction) : Prop :=
  pendingRelease m hash code c p tx = true
/-- Hypothesis instance under #741, not accepted law; mirrors the general additive_settlement claim. -/
abbrev additive_settlement_claim (m : Mutation) (hash : Hash) (code : Codec) (c : Config) (p : Pending)
    (tx : LocalTransaction) : Prop :=
  releasedTo tx.spent p.holding.family p.holding.control.controller ≤
    localPayments tx p.holding.control.controller

/-- Hypothesis instance under #741, not accepted law; mirrors the general composed_available premise. -/
abbrev composed_available_premise (m : Mutation) (hash : Hash) (code : Codec) (s : ApplicationState)
    (registry : TokenId) (ps : List Pending) (time funding fee : Nat) (folderAccepts : Nat → Prop) : Prop :=
  (WorldReachable (project s) ∧ registry = s.registryIdentity ∧ ps ≠ [] ∧
    (ps.map (·.holding.reference)).Nodup ∧
    (∀ p ∈ ps, p ∈ discover s ∧ p.holding.control.registry = registry ∧ genuine .none hash code s.registry.config (.pending p) = true) ∧
    finiteEncoding code (ps.map (fun p => Preimage.role .witness registry p.holding.control.key)) ∧
    finiteHash hash code (ps.map (fun p => Preimage.role .witness registry p.holding.control.key)) ∧
    fee ≤ funding ∧ fee ≤ (foldObligations (ps.map (fun p => FoldMember.termination p.booking))).tips ∧
    folderAccepts (foldObligations (ps.map (fun p => FoldMember.termination p.booking))).tips)
/-- Hypothesis instance under #741, not accepted law; mirrors the general composed_available claim. -/
abbrev composed_available_claim (m : Mutation) (hash : Hash) (code : Codec) (s : ApplicationState)
    (registry : TokenId) (ps : List Pending) (time funding fee : Nat) (folderAccepts : Nat → Prop) : Prop :=
  let o := canonicalFold s ps time funding fee
  let v := canonicalPhysical ps o
  composedWith m hash code registry ps o v = true ∧
  o.transaction.transaction.signers = [] ∧
  o.transaction.transaction.validity = some ⟨time, time + 1⟩ ∧
  ∀ p ∈ ps, trieGet o.after.registry.trie p.holding.control.key = .known .terminal ∧
    mintQty (canonicalLocal p.holding.control.registry ps o v).assets p.holding.token = -1

/-- Hypothesis fixture under #741, not accepted law; a missing controller signature. -/
abbrev noSigner := ([] : List Nat)
/-- Hypothesis fixture under #741, not accepted law; a non-unit held quantity. -/
abbrev wrongQuantity : Pending := { pending 7 5 with holding := { (pending 7 5).holding with quantity := 0 } }
/-- Hypothesis fixture under #741, not accepted law; exact token not burned. -/
abbrev noBurn : LocalTransaction := { localTx with assets := { localTx.assets with mint := [] } }
/-- Hypothesis fixture under #741, not accepted law; physical controller deposit omitted. -/
abbrev noPayment : LocalTransaction := { localTx with payments := [] }

/-- Executed #741 antecedent, not accepted law. -/
theorem pending_paths_refused_antecedent : pending_paths_refused_premise .none hash encode two (pending 7 5) (pending 8 7) [] := by trivial
/-- Executed #741 candidate instance, not accepted law. -/
theorem pending_paths_refused_liveUpdate_candidate : pending_paths_refused_premise .none hash encode two (pending 7 5) (pending 8 7) [] → pending_paths_refused_claim .none hash encode two (pending 7 5) (pending 8 7) [] := by decide +kernel

/-- Executed #741 antecedent, not accepted law; actual authorized booking. -/
theorem booking_retains_antecedent : booking_retains_premise .none hash encode before (holding 7 5) (pending 7 5) [42] := by
  exact good_positive .booking
/-- Executed #741 refusal control, not accepted law; missing signature is refused. -/
theorem booking_no_signer : book .none hash encode before (.live (holding 7 5)) (pending 7 5) noSigner = false := by decide +kernel
/-- Executed #741 candidate instance, not accepted law; violating input is refused. -/
theorem booking_retains_bookSigner_candidate : booking_retains_premise .none hash encode before (holding 7 5) (pending 7 5) noSigner → booking_retains_claim .none hash encode before (holding 7 5) (pending 7 5) noSigner := by
  intro accepted
  have impossible : book .none hash encode before (.live (holding 7 5)) (pending 7 5) noSigner = true := accepted
  rw [booking_no_signer] at impossible
  cases impossible

/-- Executed #741 antecedent, not accepted law; exact authentic pending output. -/
theorem pending_witness_authentication_antecedent : pending_witness_authentication_premise .none hash encode config (pending 7 5) := genuine7_executes
/-- Executed #741 refusal control, not accepted law; zero-quantity witness refuses. -/
theorem quantity_refused : genuine .none hash encode config (.pending wrongQuantity) = false := by decide +kernel
/-- Executed #741 candidate instance, not accepted law; violating input is refused. -/
theorem pending_witness_authentication_quantity_candidate : pending_witness_authentication_premise .none hash encode config wrongQuantity → pending_witness_authentication_claim .none hash encode config wrongQuantity := by
  intro accepted
  have impossible : genuine .none hash encode config (.pending wrongQuantity) = true := accepted
  rw [quantity_refused] at impossible
  cases impossible

/-- Executed #741 antecedent, not accepted law; computed exact burn and same-key root fold. -/
theorem release_terminal_antecedent : release_terminal_premise .none hash encode config (pending 7 5) localTx folded := by
  constructor
  · exact release7_executes
  · intro _
    exact good_positive .coupling
/-- Executed #741 refusal control, not accepted law; no burn refuses independently of payment. -/
theorem burn_refused : pendingRelease .none hash encode config (pending 7 5) noBurn = false := by
  simp only [pendingRelease, applyGuard, reduceBEq, Bool.false_eq_true, ite_false]
  change (((_ && _) && _) && false && _) = false
  simp
/-- Executed #741 candidate instance, not accepted law; violating input is refused. -/
theorem release_terminal_releaseBurn_candidate : release_terminal_premise .none hash encode config (pending 7 5) noBurn folded → release_terminal_claim .none hash encode config (pending 7 5) noBurn folded := by
  intro accepted
  have impossible : pendingRelease .none hash encode config (pending 7 5) noBurn = true := accepted.1
  rw [burn_refused] at impossible
  cases impossible

/-- Executed #741 antecedent, not accepted law; actual physical additive settlement. -/
theorem additive_settlement_antecedent : additive_settlement_premise .none hash encode config (pending 7 5) localTx := release7_executes
/-- Executed #741 refusal control, not accepted law; missing payment refuses independently of the burn. -/
theorem payment_refused : pendingRelease .none hash encode config (pending 7 5) noPayment = false := by
  simp only [pendingRelease, applyGuard, reduceBEq, Bool.false_eq_true, ite_false]
  change (_ && false) = false
  simp
/-- Executed #741 candidate instance, not accepted law; violating input is refused. -/
theorem additive_settlement_releasePayments_candidate : additive_settlement_premise .none hash encode config (pending 7 5) noPayment → additive_settlement_claim .none hash encode config (pending 7 5) noPayment := by
  intro accepted
  have impossible : pendingRelease .none hash encode config (pending 7 5) noPayment = true := accepted
  rw [payment_refused] at impossible
  cases impossible

/-- Executed #741 antecedent, not accepted law; n>1, computed finite separation, explicit fee/funding/willingness. -/
theorem composed_available_antecedent : composed_available_premise .none hash encode two Fixtures.registry selected 1000 20 1 willing := by
  refine ⟨two_reachable, rfl, ?_, ?_, ?_, ?_, ?_, ?_, ?_, trivial⟩
  · decide +kernel
  · decide +kernel
  · intro p member
    simp only [selected, List.mem_cons, List.not_mem_nil, or_false] at member
    rcases member with rfl | rfl
    · refine ⟨?_, rfl, ?_⟩
      · change pending 7 5 ∈ [pending 8 7, pending 7 5]; simp
      · exact genuine7_executes
    · refine ⟨?_, rfl, ?_⟩
      · change pending 8 7 ∈ [pending 8 7, pending 7 5]; simp
      · exact genuine8_executes
  · decide +kernel
  · decide +kernel
  · decide +kernel
  · decide +kernel
/-- Executed #741 candidate instance, not accepted law; permissionless composed fold at chosen later time. -/
theorem composed_available_composedLocal_candidate : composed_available_premise .none hash encode two Fixtures.registry selected 1000 20 1 willing → composed_available_claim .none hash encode two Fixtures.registry selected 1000 20 1 willing := by
  intro _
  refine ⟨composition_executes, rfl, rfl, ?_⟩
  intro p member
  simp only [selected, List.mem_cons, List.not_mem_nil, or_false] at member
  rcases member with rfl | rfl <;> decide +kernel

/-- Executed #741 satisfying witness, not accepted law; authorized booking retains every promised field. -/
theorem booking_retains_satisfying : booking_retains_premise .none hash encode before (holding 7 5) (pending 7 5) [42] ∧ booking_retains_claim .none hash encode before (holding 7 5) (pending 7 5) [42] := by
  refine ⟨booking_retains_antecedent, ?_⟩
  simp only [booking_retains_claim]
  have genuineAccepted : genuine .none hash encode before.registry.config (.pending (pending 7 5)) = true := genuine7_executes
  have correspondence : bookTermination (project before) (pending 7 5).booking =
      .ok (project (bookEffect before (.live (holding 7 5)) (pending 7 5))) := book7_accepted
  simp only [genuineAccepted, correspondence, and_true]
  held_decide
/-- Executed #741 satisfying witness, not accepted law; authentic quantity, identity and root tag contents. -/
theorem pending_witness_authentication_satisfying : pending_witness_authentication_premise .none hash encode config (pending 7 5) ∧ pending_witness_authentication_claim .none hash encode config (pending 7 5) := by
  refine ⟨pending_witness_authentication_antecedent, ?_⟩
  simp only [pending_witness_authentication_claim]
  held_decide
/-- Executed #741 satisfying witness, not accepted law; computed burn, root acceptance and same-key terminal leaf. -/
theorem release_terminal_satisfying : release_terminal_premise .none hash encode config (pending 7 5) localTx folded ∧ release_terminal_claim .none hash encode config (pending 7 5) localTx folded := by
  refine ⟨release_terminal_antecedent, ?_⟩
  exact ⟨by decide +kernel, fold_executes, by decide +kernel⟩
/-- Executed #741 satisfying witness, not accepted law; the physical payment covers the actual sum. -/
theorem additive_settlement_satisfying : additive_settlement_premise .none hash encode config (pending 7 5) localTx ∧ additive_settlement_claim .none hash encode config (pending 7 5) localTx :=
  ⟨additive_settlement_antecedent, by decide +kernel⟩
end NoPin.Held.Instances
