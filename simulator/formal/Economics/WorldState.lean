import Singular.Model
import Singular.Economics.Booking
import Singular.Economics.Termination

/-! Booking-only worlds. Each pending request retains its original booking
transaction, including the observed interval or custody inputs. No transition
here spends a pending request. -/

namespace Singular

/-- Pending registrations together with their original booking transactions. -/
abbrev RequestPool := List RegistrationBooking

/-- The registry component and requests booked but not yet spent. Termination
booking moves an active holding into the pool while leaving its leaf active. -/
structure World where
  registry : RegistryState
  pending : RequestPool := []
  terminations : List TerminationBooking := []
  /-- Cumulative observed treasury donations from accepted economic folds. -/
  treasury : Nat := 0
  deriving BEq, DecidableEq

/-- A booking admits the presented transaction before inserting it. Reusing a
pending output reference is refused rather than duplicating its value or tags.
The original transaction, including its interval, is retained unchanged. -/
def book (world : World) (booking : RegistrationBooking) : Except String World :=
  match registrationBookingRefusal world.registry.config booking with
  | some reason => .error reason
  | none =>
    if world.pending.any (fun pending => decide (pending.request.reference = booking.request.reference)) ||
        world.terminations.any (fun pending => decide (pending.request.reference = booking.request.reference)) then
      .error "request-already-pending"
    else .ok { world with pending := booking :: world.pending }

/-- Move the admitted booking's one active holding out of custody into the
pending termination. The leaf, root, parameters and registrations stay fixed.
References are unique across both kinds of pending request. -/
def bookTermination (world : World) (booking : TerminationBooking) : Except String World :=
  match terminationBookingRefusal world.registry booking with
  | some reason => .error reason
  | none =>
    if world.pending.any (fun p => decide (p.request.reference = booking.request.reference)) ||
        world.terminations.any (fun p => decide (p.request.reference = booking.request.reference)) then
      .error "request-already-pending"
    else .ok {
      world with
      registry := { world.registry with
        held := world.registry.held.filter (fun h => !(h.key == booking.request.key && h.kind == .active)) }
      terminations := booking :: world.terminations }

/-- Several termination outputs in one transaction share the same custody
accounting. Any refused member refuses the whole transaction, with no world
returned and the original pool unchanged. The intermediate calculation holds
the first termination; a later member cannot take its tag again. This differs
from a later transaction's refusal, which leaves the already pending one. -/
def bookTerminations (world : World) (bookings : List TerminationBooking) : Except String World :=
  bookings.foldlM bookTermination world

end Singular
