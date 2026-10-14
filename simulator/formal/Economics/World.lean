import Singular.Model
import Singular.Economics.Booking

/-! Booking-only worlds. The pool retains the transaction that introduced each
request so statements about its original interval have a concrete subject.
Folds and exits will extend this world in later slices. -/

namespace Singular

/-- Pending registrations together with their original booking transactions. -/
abbrev RequestPool := List RegistrationBooking

/-- The registry state and requests booked but not yet spent. This slice has
no exit transition and no transition changing the registry. -/
structure World where
  registry : RegistryState
  pending : RequestPool := []
  deriving BEq, DecidableEq

/-- A booking admits the presented transaction before inserting it. Reusing a
pending output reference is refused rather than duplicating its value or tags.
The original transaction, including its interval, is retained unchanged. -/
def book (world : World) (booking : RegistrationBooking) : Except String World :=
  match registrationBookingRefusal world.registry.config booking with
  | some reason => .error reason
  | none =>
    if world.pending.any (fun pending => decide (pending.request.reference = booking.request.reference)) then
      .error "request-already-pending"
    else .ok { world with pending := booking :: world.pending }

/-- Start with an actually reachable registry and no pending requests. The
existing registry reachability is a premise, not extended or restated here.
Every subsequent world is the result of the real booking function. -/
inductive WorldReachable : World → Prop where
  | initial (registry : RegistryState) (reachable : Reachable registry) :
      WorldReachable ⟨registry, []⟩
  | booking {before after : World} (reachable : WorldReachable before)
      (transaction : RegistrationBooking) (accepted : book before transaction = .ok after) :
      WorldReachable after

end Singular
