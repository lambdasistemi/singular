import Singular.Lemmas
import Singular.Driver
import Singular.Economics
import Singular.Statements.Preservation

/-! Empty batch, live burns, distinct requests, ordered chain, keyed mint and singleton laws. -/

namespace Singular.Statements

/-- A zero-request batch is always refused. -/
theorem empty_fold_error (s : RegistryState) (batch : List Request)
    (h : batch = []) : foldBatch s batch = .error "empty-fold" := by
  subst h
  rfl

/-- A termination cannot burn a holding an earlier insertion in the same
batch created. Existing step refusals and the keyed mint check take precedence. -/
theorem batch_cannot_consume_what_it_creates
    (s : RegistryState) (before middle after : List Request) (insert retire : Request)
    (m : Result) (hi : insert.edge = .insertActive) (hr : retire.edge = .updateTerminal)
    (hk : insert.key = retire.key)
    (hsteps : foldActions s (before ++ insert :: middle ++ retire :: after) = .ok m)
    (hmint : assetSame (claimedMint (before ++ insert :: middle ++ retire :: after))
      (actualMint (before ++ insert :: middle ++ retire :: after)) = true) :
    foldBatch s (before ++ insert :: middle ++ retire :: after) = .error "token-missing" := by
  have hscan : batchConsumesCreated (before ++ insert :: middle ++ retire :: after) =
      some "token-missing" := by
    rcases created_scan_reason [] (before ++ insert :: middle ++ retire :: after) with hn | hrule
    · have hp := ((created_scan_none [] _).mp hn).2
      have bad : insert.key ≠ retire.key :=
        (List.pairwise_append.mp hp).2.2 insert (by simp) retire (by simp) hi hr
      exact False.elim (bad hk)
    · exact hrule
  have hne : (before ++ insert :: middle ++ retire :: after).isEmpty = false := by simp
  unfold foldBatch
  simp only [hne, Bool.false_eq_true, if_false, hsteps, bind, Except.bind,
    hmint, ite_true, hscan]
  rfl

/-- Every termination in an accepted batch burns an active holding present
before the batch began. This does not assert a concrete batch transaction. -/
theorem batch_burns_only_live_holdings (s : RegistryState) (batch : List Request)
    (t : Result) (hok : foldBatch s batch = .ok t) :
    ∀ r ∈ batch, r.edge = .updateTerminal →
      s.held.any (fun h => h.key == r.key && h.kind == .active) = true := by
  have hp := ((created_scan_none [] batch).mp (foldBatch_scan s batch t hok)).2
  exact foldActions_live_burns s batch t (foldBatch_inv s batch t hok).2 hp

/-- A non-empty batch of independently admissible requests on distinct keys
is admissible. No comparison of roots or of reordered effects is claimed. -/
theorem independent_requests_fold_as_a_batch (s : RegistryState) (batch : List Request)
    (hne : batch ≠ [])
    (hkeys : batch.Pairwise (fun a b => a.key ≠ b.key))
    (hclaims : ∀ r ∈ batch, assetSame (requestClaim r) (assetDelta r) = true)
    (hsteps : ∀ r ∈ batch, ∃ t, step s r = .ok t) :
    ∃ t, foldBatch s batch = .ok t := by
  obtain ⟨t, ht⟩ := foldActions_independent s batch hkeys hsteps
  have hscan : batchConsumesCreated batch = none := by
    apply (created_scan_none [] batch).mpr
    refine ⟨by simp, ?_⟩
    exact hkeys.imp (by intro a b hab _ _; exact hab)
  have hn : batch.isEmpty = false := by simpa using hne
  exact ⟨t, by simp [foldBatch, hn, ht, batch_claims_agree batch hclaims, hscan]⟩

/-- A fold succeeds iff every request applies in order, the claimed mint
matches the summed delta of the folded edges, and no termination consumes an
active holding created earlier in the batch. -/
theorem fold_batch_cons (s : RegistryState) (b : Request) (bs : List Request) (t : Result) :
    foldBatch s (b :: bs) = .ok t ↔
    ∃ m r, step s b = .ok m ∧ foldActions m.state bs = .ok r ∧
      t = { state := r.state, mint := assetPlus m.mint r.mint, paid := m.paid ++ r.paid } ∧
      assetSame (claimedMint (b :: bs)) (actualMint (b :: bs)) ∧
      batchConsumesCreated (b :: bs) = none := by
  constructor
  · intro hok
    have hacts := (foldBatch_inv s (b :: bs) t hok).2
    have hdelta : assetSame (claimedMint (b :: bs)) (actualMint (b :: bs)) := by
      unfold foldBatch at hok
      rw [if_neg (by simp)] at hok
      rw [hacts] at hok
      simp only [bind, Except.bind, pure, Except.pure] at hok
      split at hok
      · assumption
      · exact nomatch hok
    unfold foldActions at hacts
    simp only [bind, Except.bind, pure, Except.pure] at hacts
    cases hs : step s b with
    | error e => rw [hs] at hacts; exact nomatch hacts
    | ok m =>
      rw [hs] at hacts
      simp only [bind, Except.bind, pure, Except.pure] at hacts
      cases hr : foldActions m.state bs with
      | error e => rw [hr] at hacts; exact nomatch hacts
      | ok r =>
        rw [hr] at hacts
        have hEq : combineResults m r = t := by injection hacts
        exact ⟨m, r, rfl, hr, by rw [← hEq]; rfl, hdelta, foldBatch_scan _ _ _ hok⟩
  · rintro ⟨m, r, hs, hr, hEq, hdelta, hscan⟩
    unfold foldBatch
    rw [if_neg (by simp)]
    have hacts : foldActions s (b :: bs) = .ok t := by
      unfold foldActions
      simp only [bind, Except.bind, pure, Except.pure]
      rw [hs]
      simp only [bind, Except.bind, pure, Except.pure]
      rw [hr, hEq]
      rfl
    rw [hacts]
    simp only [bind, Except.bind, pure, Except.pure]
    split
    · simp [hscan]
    · rename_i hc; exact absurd hdelta hc





/-- **#173 registration-transaction-and-keyed-mint** — the fold's mint guard is per `(TokenKind, Key)`.

An accepted fold's claimed and actual keyed sums agree; a nonempty batch whose
every request applies but whose keyed sums differ is refused
`net-mint-mismatch`; and the guard is strictly finer than a per-kind one. The
third clause is not a bare existential mismatch: it exhibits a reachable state
and two booking requests that both apply there, whose per-kind totals agree at
every kind, whose keyed sums differ, and whose fold is *observed* to be
`.error "net-mint-mismatch"` from that state. The bridge from "the sums differ"
to "the batch is refused" is inside the statement, not left to the reader. -/
theorem fold_batch_claimed_mint_by_kind_key :
    (∀ (s : RegistryState) (batch : List Request) (t : Result),
        foldBatch s batch = .ok t → assetSame (claimedMint batch) (actualMint batch) = true) ∧
    (∀ (s : RegistryState) (batch : List Request) (m : Result),
        batch ≠ [] → foldActions s batch = .ok m →
        assetSame (claimedMint batch) (actualMint batch) = false →
        foldBatch s batch = .error "net-mint-mismatch") ∧
    (∃ (s : RegistryState) (b₁ b₂ : Request) (m : Result),
        Reachable s ∧
        b₁.edge = .insertActive ∧ b₂.edge = .insertActive ∧ b₁.key ≠ b₂.key ∧
        foldActions s [b₁, b₂] = .ok m ∧
        (∀ k : TokenKind, assetKindTotal (claimedMint [b₁, b₂]) k
                        = assetKindTotal (actualMint [b₁, b₂]) k) ∧
        assetSame (claimedMint [b₁, b₂]) (actualMint [b₁, b₂]) = false ∧
        foldBatch s [b₁, b₂] = .error "net-mint-mismatch") := by
  refine ⟨?_, ?_, ?_⟩
  · intro s batch t hok
    obtain ⟨hne, hacts⟩ := foldBatch_inv s batch t hok
    unfold foldBatch at hok
    rw [if_neg (by simpa using hne)] at hok
    rw [hacts] at hok
    simp only [bind, Except.bind, pure, Except.pure] at hok
    split at hok
    · assumption
    · exact nomatch hok
  · intro s batch m hne hacts hfalse
    unfold foldBatch
    rw [if_neg (by simpa using hne)]
    rw [hacts]
    simp only [bind, Except.bind, pure, Except.pure]
    rw [if_neg (by simp [hfalse])]
    rfl
  · refine ⟨{ config := { Oracle.referenceConfig with root := rootOf [] }
            , trie := [], custody := [], held := [] },
      { edge := .insertActive, key := 5, owner := 0, output := 555
      , approval := some { policy := 7, edge := .insertActive, key := 5, owner := 0
                         , destination := 555
                         , assetName := approvalAssetName .insertActive 5 0 555 }
      , claimed := [(.active, 2)] },
      { edge := .insertActive, key := 6, owner := 0, output := 555
      , approval := some { policy := 7, edge := .insertActive, key := 6, owner := 0
                         , destination := 555
                         , assetName := approvalAssetName .insertActive 6 0 555 }
      , claimed := [] },
      _, Reachable.initial _, rfl, rfl, by decide, rfl, ?_, by decide, rfl⟩
    intro k
    cases k <;> rfl

/-- **#344, a batch of one folds as its step** — for one request whose claimed
mint is the delta of its own edge, under an admitted witness the batch fold
is exactly the single step:
refused for the same reason, or accepted with the same state, mint and payments. -/
theorem fold_batch_of_one_is_step (s : RegistryState) (r : Request) (w : FoldWitness)
    (admitted : foldAdmission s.config [r] w = none)
    (hclaim : assetSame (requestClaim r) (assetDelta r) = true) :
    admittedFoldBatch s [r] w = step s r := by
  simp only [admittedFoldBatch, admitted]

  have hsame : assetSame (claimedMint [r]) (actualMint [r]) = true := by
    rw [assetSame_iff] at hclaim ⊢
    intro x
    simp only [claimedMint, actualMint, List.foldl, assetKind_plus, hclaim x]
  have hscan : batchConsumesCreated [r] = none := by
    cases r.edge <;> simp [batchConsumesCreated, batchConsumesCreated.go]
  have hnil : assetPlus (assetDelta r) [] = assetDelta r := by
    rcases r with ⟨edge, key⟩
    cases edge <;> simp [assetPlus, assetDelta, delta, assetKind, List.eraseDups_cons]
  unfold foldBatch
  cases hs : step s r with
  | error why => simp [foldActions, hs]; rfl
  | ok t =>
    have hmint : t.mint = assetDelta r := by
      unfold step at hs
      split at hs
      · cases hs
      · cases hs; rfl
    cases t
    simp_all [foldActions, combineResults, emptyResult, bind, Except.bind, Functor.map,
      Except.map, pure, Except.pure]


end Singular.Statements
