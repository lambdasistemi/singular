import Singular.Economics

/-! Every pending registration comes from an admitted booking transaction.
Theorems quantify over reachable worlds and arbitrary pool members, never
only over a booking builder or the finite corpus. -/

namespace Singular.Statements

/-- Every pending registration has exact contents, including the minimum tip
and full application binding. Both tags were minted with that very request.
The carrier is a declared allocation, not a measured ledger minimum. -/
theorem booked_request_has_exact_contents (world : World) (reachable : WorldReachable world)
    (booking : RegistrationBooking) (pending : booking ∈ world.pending) :
    exactContents world.registry.config booking.request = true ∧
    booking.trieReadyTagsMinted = [booking.request.trieReadyTag world.registry.config] ∧
    booking.applicationTagsMinted = booking.request.contents.applicationTags := by
  induction reachable with
  | initial registry h => simp at pending
  | @booking before after reach transaction accepted ih =>
    unfold book at accepted
    split at accepted
    next reason => exact nomatch accepted
    next admitted =>
      split at accepted
      next duplicate => exact nomatch accepted
      next fresh =>
        cases accepted
        simp only [List.mem_cons] at pending
        rcases pending with same | old
        · subst booking
          simp only [registrationBookingRefusal] at admitted
          split at admitted
          next dirty => contradiction
          next shape =>
            split at admitted
            next surplus => contradiction
            next value =>
              split at admitted
              next forged => contradiction
              next tags =>
                split at admitted
                next missing => contradiction
                next application =>
                  have shape' : registrationContentsShape before.registry.config transaction.request = true ∧
                      registrationDeclaredLovelace transaction.request ≤ transaction.request.contents.lovelace := by
                    simpa using shape
                  have tags' : transaction.request.contents.trieReadyTags = [transaction.request.trieReadyTag before.registry.config] ∧
                      transaction.trieReadyTagsMinted = [transaction.request.trieReadyTag before.registry.config] := by
                    simpa using tags
                  have application' : transaction.applicationTagsMinted = transaction.request.contents.applicationTags := by
                    simpa using application
                  have amount : transaction.request.contents.lovelace = registrationDeclaredLovelace transaction.request := by
                    omega
                  exact ⟨by simp [exactContents, shape'.1, amount, tags'.1], tags'.2, application'⟩
        · exact ih old
  | @termination before after reach transaction accepted ih =>
    unfold bookTermination at accepted
    split at accepted
    next reason => exact nomatch accepted
    next admitted =>
      split at accepted
      next duplicate => exact nomatch accepted
      next fresh => cases accepted; exact ih pending
  | @rejection before after reach unspent transaction accepted ih =>
    have effect := rejectionAccepted_effect accepted
    subst after
    exact ih (List.mem_filter.mp pending).1

/-- The pool keeps the booking transaction's interval, and the pending
registration's booked time is exactly its upper end. -/
theorem booked_time_is_interval_end (world : World) (reachable : WorldReachable world)
    (booking : RegistrationBooking) (pending : booking ∈ world.pending) :
    booking.request.submittedAt = booking.interval.upper := by
  induction reachable with
  | initial registry h => simp at pending
  | @booking before after reach transaction accepted ih =>
    unfold book at accepted
    split at accepted
    next reason => exact nomatch accepted
    next admitted =>
      split at accepted
      next duplicate => exact nomatch accepted
      next fresh =>
        cases accepted
        simp only [List.mem_cons] at pending
        rcases pending with same | old
        · subst booking
          simp only [registrationBookingRefusal] at admitted
          repeat (split at admitted <;> try simp_all)
          all_goals omega
        · exact ih old
  | @termination before after reach transaction accepted ih =>
    unfold bookTermination at accepted
    split at accepted
    next reason => exact nomatch accepted
    next admitted =>
      split at accepted
      next duplicate => exact nomatch accepted
      next fresh => cases accepted; exact ih pending
  | @rejection before after reach unspent transaction accepted ih =>
    have effect := rejectionAccepted_effect accepted
    subst after
    exact ih (List.mem_filter.mp pending).1

/-- For every actual inclusion time within the original half-open interval,
the booked time is no earlier. Hence the expiry threshold is no earlier than
both windows after inclusion. This states the threshold, not exit admission. -/
theorem booked_time_not_before_inclusion (world : World) (reachable : WorldReachable world)
    (booking : RegistrationBooking) (pending : booking ∈ world.pending)
    (includedAt : Nat) (included : booking.interval.contains includedAt) :
    includedAt ≤ booking.request.submittedAt ∧
    includedAt + world.registry.config.processTime + world.registry.config.retractTime ≤
      booking.request.submittedAt + world.registry.config.processTime + world.registry.config.retractTime := by
  have time := booked_time_is_interval_end world reachable booking pending
  rcases included with ⟨lower, upper⟩
  omega

/-- Every pending registration was booked in a nonempty interval whose width
is at most the pinned maximum. Empty and reversed intervals cannot exploit
natural-number subtraction to pass the width rule. -/
theorem booking_width_within_limit (world : World) (reachable : WorldReachable world)
    (booking : RegistrationBooking) (pending : booking ∈ world.pending) :
    booking.interval.valid ∧ booking.interval.width ≤ world.registry.config.bookingWidth := by
  induction reachable with
  | initial registry h => simp at pending
  | @booking before after reach transaction accepted ih =>
    unfold book at accepted
    split at accepted
    next reason => exact nomatch accepted
    next admitted =>
      split at accepted
      next duplicate => exact nomatch accepted
      next fresh =>
        cases accepted
        simp only [List.mem_cons] at pending
        rcases pending with same | old
        · subst booking
          simp only [registrationBookingRefusal] at admitted
          repeat (split at admitted <;> try simp_all)
          all_goals omega
        · exact ih old
  | @termination before after reach transaction accepted ih =>
    unfold bookTermination at accepted
    split at accepted
    next reason => exact nomatch accepted
    next admitted =>
      split at accepted
      next duplicate => exact nomatch accepted
      next fresh => cases accepted; exact ih pending
  | @rejection before after reach unspent transaction accepted ih =>
    have effect := rejectionAccepted_effect accepted
    subst after
    exact ih (List.mem_filter.mp pending).1

/-- Even a commitment of zero cannot identify the registry's state token.
This separates the identity spaces without assuming anything about hashes. -/
theorem trie_ready_tag_is_not_state_token (c : Config) (commitment : Nat) :
    c.trieReadyTag commitment ≠ c.stateToken := by
  simp [Config.trieReadyTag, Config.stateToken]

/-- Every reachable pending registration holds the tag of its own operation
and nonce, and an application tag bound to its own payload and the same nonce.
The equality is to the computed names, with no injectivity assumption. -/
theorem booked_request_tags_commit_to_own_fields (world : World)
    (reachable : WorldReachable world) (booking : RegistrationBooking)
    (pending : booking ∈ world.pending) :
    booking.request.contents.trieReadyTags =
      [world.registry.config.trieReadyTag
        (trieReadyTagAssetName booking.request.operation booking.request.nonce)] ∧
    ∃ tag : Approval, booking.request.contents.applicationTags = [tag] ∧
      tag.policy = world.registry.config.applicationPolicy ∧ tag.edge = .insertActive ∧
      tag.key = booking.request.key ∧ tag.owner = booking.request.refundAddress ∧
      tag.destination = booking.request.destination ∧
      tag.assetName = applicationTagAssetName booking.request.key booking.request.refundAddress
        booking.request.destination booking.request.nonce := by
  have contents := (booked_request_has_exact_contents world reachable booking pending).1
  simp only [exactContents, Bool.and_eq_true, decide_eq_true_eq] at contents
  refine ⟨contents.2, ?_⟩
  have shape := contents.1.1
  cases tags : booking.request.contents.applicationTags with
  | nil => simp [registrationContentsShape, tags] at shape
  | cons tag rest =>
    cases rest with
    | nil =>
      simp only [registrationContentsShape, tags, Bool.and_eq_true] at shape
      exact ⟨tag, rfl, by simpa [registrationApplicationTagValid] using shape.2⟩
    | cons other rest => simp [registrationContentsShape, tags] at shape

end Singular.Statements
