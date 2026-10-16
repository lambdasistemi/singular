import Singular.Lemmas.Payments

/-! Payment monotonicity and the request fields obligations read. -/

namespace Singular.Statements

/-- Value an exit does not owe is unconstrained, for every exit alike.

For every exit, every request and any two lists of transaction outputs: when each
recipient the exit owes that some output of the first list reaches is reached by
some output of the second, and receives (`receivedBy`: the summed lovelace of the
outputs that pay it by role, address and, for a destination, datum, or, for a
retraction's return bound to its request, the largest such output) at least as
much from the second list as from the first, the second list settles whenever the
first does. Adding outputs, or adding lovelace to an output, therefore never turns
a settled transaction into an unsettled one, and whether a transaction settles
depends only on which recipients the exit owes are reached and the lovelace
reaching them: fees, the folder's tip and every output that pays none of them play
no part. -/
theorem exit_settles_on_lovelace_received (exit : Exit) (request : Request)
    (outputs more : List TxOutput)
    (reached : ∀ payment ∈ obligations exit request,
      (outputs.filter (paysRecipient payment.recipient)).isEmpty = false →
      (more.filter (paysRecipient payment.recipient)).isEmpty = false)
    (received : ∀ payment ∈ obligations exit request,
      receivedBy payment.recipient outputs ≤ receivedBy payment.recipient more) :
    settle (obligations exit request) outputs = none →
    settle (obligations exit request) more = none := by
  -- `settle` judges each recipient the payments name once; a recipient is judged
  -- on the lovelace of the outputs paying it, which `received` says only grows.
  have named : ∀ (l acc : List Recipient) (recipient : Recipient),
      recipient ∈ List.eraseDupsBy.loop (· == ·) l acc → recipient ∈ l ∨ recipient ∈ acc := by
    intro l
    induction l with
    | nil => intro acc recipient h; exact .inr (by simpa [List.eraseDupsBy.loop] using h)
    | cons head tail ih =>
      intro acc recipient h
      simp only [List.eraseDupsBy.loop] at h
      split at h
      · rcases ih _ _ h with h | h
        · exact .inl (List.mem_cons_of_mem _ h)
        · exact .inr h
      · rcases ih _ _ h with h | h
        · exact .inl (List.mem_cons_of_mem _ h)
        · rcases List.mem_cons.mp h with h | h
          · exact .inl (h ▸ List.mem_cons_self)
          · exact .inr h
  intro settled
  unfold settle at settled ⊢
  rw [List.findSome?_eq_none_iff] at settled ⊢
  intro recipient judged
  have owed := (named _ [] recipient judged).resolve_right (by simp)
  obtain ⟨payment, owedPayment, rfl⟩ := List.mem_map.mp owed
  have before := settled _ judged
  dsimp only at before ⊢
  split at before
  · cases before
  · next notMissing =>
    split at before
    · next paid =>
      have keep : ¬ ((requiresCarrier payment.recipient &&
          (more.filter (paysRecipient payment.recipient)).isEmpty) = true) := by
        intro h
        simp only [Bool.and_eq_true] at h
        cases hb : (outputs.filter (paysRecipient payment.recipient)).isEmpty
        · rw [reached payment owedPayment hb] at h
          exact Bool.false_ne_true h.2
        · exact notMissing (by simp [h.1, hb])
      rw [if_neg keep, if_pos (Nat.le_trans paid (received payment owedPayment))]
    · cases before
/-- Only a retract owes the tip.

For every exit: what the exit owes is the same for every request whatever tip the
request holds exactly when the exit is not a retract. Every other exit leaves the
tip to the folder, and a retract's obligations change with it. -/
theorem only_retract_owes_the_tip (exit : Exit) :
    (∀ (request : Request) (tip : Nat),
      obligations exit { request with tip := tip } = obligations exit request) ↔
    exit ≠ .retract := by
  constructor
  · intro unchanged retract
    subst retract
    have tipped := unchanged { edge := .insertAbsent, key := 0 } 1
    simp [obligations] at tipped
  · intro notRetract request tip
    cases exit with
    | fold edge => cases edge <;> rfl
    | reject => rfl
    | retract => exact absurd rfl notRetract

/-- What an exit owes is read off the request alone.

For every exit and any two requests with the same owner, deposit, tip, destination
— its address and the datum it carries — and output reference, the exit owes the
same payments. The obligations read no registry state, and nothing else of the
request: not its edge beyond the destination it names, its key, its refund address,
its approval or its claimed mint. -/
theorem obligations_read_only_the_request (exit : Exit) (request other : Request)
    (sameOwner : other.owner = request.owner) (sameDeposit : other.deposit = request.deposit)
    (sameTip : other.tip = request.tip)
    (sameDestination : requestDestination other = requestDestination request)
    (sameDatum : other.datum = request.datum)
    (sameReference : other.reference = request.reference) :
    obligations exit other = obligations exit request := by
  cases exit with
  | fold edge => cases edge <;> simp [obligations, *]
  | reject | retract => simp [obligations, *]

end Singular.Statements
