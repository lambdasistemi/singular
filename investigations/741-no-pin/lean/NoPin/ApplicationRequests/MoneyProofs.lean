import NoPin.ApplicationRequests.MoneyClaims
import NoPin.ApplicationRequests.RefundLifecycleStatements
import OpenDatumApplication.Statements

/-! Hypothetical money proof helpers; frozen definitions and statements are unchanged. -/
namespace NoPin.ApplicationRequests.Money.Proofs
open Singular Lean
set_option maxHeartbeats 2000000
set_option maxRecDepth 8192

local instance : LawfulBEq TokenId where
  eq_of_beq := NoPin.ApplicationRequests.Proofs.token_eq _ _
  rfl := by intro a; cases a; simp [reduceBEq]
local instance : LawfulBEq ProtectedControl where
  eq_of_beq := by intro a b h; cases a; cases b; simp_all [reduceBEq]
  rfl := by intro a; cases a; simp [reduceBEq]
local instance : LawfulBEq RegistrationData where
  eq_of_beq := by intro a b h; cases a; cases b; simp_all [reduceBEq]
  rfl := by intro a; cases a; simp [reduceBEq]
local instance : LawfulBEq ApplicationDatum where
  eq_of_beq := by intro a b h; cases a <;> cases b <;> simp_all [reduceBEq]
  rfl := by intro a; cases a <;> simp [reduceBEq]

theorem effects (h : Hash) (c : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (o : ApplicationObservation)
    (accepted : RefundApplication.applicationStep .none h c decode release o = true) :
    RefundLifecycle.registrationEffects h c decode o = true ∧
    RefundLifecycle.terminationEffects h c o = true ∧
    RefundLifecycle.paymentEffects decode o = true ∧
    RefundLifecycle.treasuryEffect decode o = true ∧ updateEffect decode o = true := by
  refine ⟨RefundLifecycle.Proofs.registration_effects h c decode release o accepted,
    RefundLifecycle.Proofs.termination_effects h c decode release o accepted, ?_, ?_, ?_⟩
  · simp only [RefundApplication.applicationStep, Bool.and_eq_true, requestValueSplit,
      RefundLifecycle.Proofs.appGuard_none] at accepted
    exact accepted.2.1
  · simp only [RefundApplication.applicationStep, Bool.and_eq_true, requestValueSplit,
      RefundLifecycle.Proofs.appGuard_none] at accepted
    exact accepted.2.2
  · apply List.all_eq_true.mpr
    intro a member
    have ha := RefundLifecycle.Proofs.accepted_actions h c decode release o accepted a member
    cases a <;> try rfl
    case liveUpdate ref index =>
      simp only [RefundLifecycle.applicationAction, RefundApplication.applicationAction,
        NoPin.ApplicationRequests.applicationAction, ApplicationAction.inputReference] at ha
      dsimp only [Id.run, pure, bind] at ha ⊢
      repeat' first | (split at ha) | (split) | (solve | simp_all [liveUpdate,
        RefundLifecycle.Proofs.appGuard_none, Bool.and_eq_true, beq_iff_eq])

theorem allocations (journey : Journey) (q : Input) (p : Correspondence q) :
    AllDifferences .none journey q := by
  cases hr : q.registration with
  | termination output registry key => simp [Correspondence, hr] at p
  | registration output data =>
    cases ht : q.termination with
    | registration output data => simp [Correspondence, ht] at p
    | termination term registry key =>
      simp only [Correspondence, hr, ht, PendingRequest.output] at p
      intro party
      cases journey <;> cases party <;>
        simp [reduceBEq, Journey.ctorIdx, Difference, oldAllocation, newAllocation, rulingFor, Allocation.at,
          amountAt, foldObligations, FoldMember.carrier, FoldMember.tip, FoldMember.donation,
          refundAmount, registrationDeclaredLovelace, terminationDeclaredLovelace,
          PendingRequest.bid, hr, ht, PendingRequest.output] <;> omega

theorem old_allocations (q : Input) (p : OldPremise q) : OldClaim .none q := by
  have amounts := p.1
  unfold Correspondence at amounts
  simp [reduceBEq, Journey.ctorIdx, OldClaim, oldAllocation, amountAt, foldObligations, FoldMember.carrier,
    FoldMember.tip, FoldMember.donation, refundAmount]
  omega

theorem old_unsigned (world : OpenDatumApplication.World) (ref : Nat)
    (successors : List OpenDatumApplication.Successor) (signers : List Nat)
    (p : OldUpdatePremise world ref signers) : OldUpdateClaim .none world ref successors signers := by
  obtain ⟨input, found, unsigned⟩ := p
  unfold OldUpdateClaim
  cases result : oldUpdate .none world ref successors signers with
  | error why => rfl
  | ok after =>
    have update : OpenDatumApplication.updateStep OpenDatumApplication.Law.standard
        world ref successors signers = .ok after := by
      simpa [oldUpdate, amountAt, OpenDatumApplication.Law.standard] using result
    obtain ⟨before, successor, found', signed, rest⟩ :=
      (OpenDatumApplication.Statements.update_inversion world after ref successors signers).mp update
    have same : before = input := Option.some.inj (found'.symm.trans found)
    exact False.elim (unsigned (by simpa [same] using signed))

end NoPin.ApplicationRequests.Money.Proofs
