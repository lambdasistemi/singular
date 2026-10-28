import OpenDatumApplicationHeld.RefundLifecycleClaims
import SingularApplicationHeld.Statements

/-! The application-held open-datum model beside the current one. -/

namespace OpenDatumApplicationHeld.RefundLifecycle.Proofs
open Singular Lean SingularApplicationHeld

local instance : LawfulBEq OutRef where
  eq_of_beq := by
    intro a b same
    cases a
    cases b
    simp_all [BEq.beq, instBEqOutRef.beq]
  rfl := by
    intro a
    cases a
    simp [BEq.beq, instBEqOutRef.beq]
local instance : LawfulBEq RegistrationPhase where
  eq_of_beq := by
    intro a b same
    cases a <;> cases b <;> first | rfl | exact False.elim (Bool.noConfusion same)
  rfl := by intro a; cases a <;> rfl

local instance : LawfulBEq TokenId where
  eq_of_beq := SingularApplicationHeld.Proofs.token_eq _ _
  rfl := by
    intro a
    cases a
    simp [BEq.beq, instBEqTokenId.beq]

set_option maxHeartbeats 2000000
set_option maxRecDepth 8192

@[simp] theorem appGuard_none (site : AppGuard) (b : Bool) : appGuard .none site b = b := rfl

theorem action_eq (h : Hash) (c : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (o : ApplicationObservation) (a : ApplicationAction) :
    applicationAction .none h c decode release o a =
      applicationActionConditions h c decode release o a := by
  cases a <;> rfl

theorem step_eq (h : Hash) (c : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (o : ApplicationObservation) :
    applicationStep .none h c decode release o = applicationStepConditions h c decode release o := by
  have actions : RefundApplication.applicationAction .none h c decode release o =
      applicationActionConditions h c decode release o := funext (action_eq h c decode release o)
  unfold applicationStep RefundApplication.applicationStep applicationStepConditions
  rw [actions]
  rfl

theorem accepted_actions (h : Hash) (c : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (o : ApplicationObservation)
    (accepted : applicationStep .none h c decode release o = true) :
    ∀ a ∈ o.actions, applicationAction .none h c decode release o a = true := by
  simp only [applicationStep, RefundApplication.applicationStep, Bool.and_eq_true] at accepted
  exact List.all_eq_true.mp accepted.1.1.2

theorem termination_effects (h : Hash) (c : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (o : ApplicationObservation)
    (accepted : applicationStep .none h c decode release o = true) :
    terminationEffects h c o = true := by
  apply List.all_eq_true.mpr
  intro a member
  have ha := accepted_actions h c decode release o accepted a member
  cases a <;> try rfl
  case terminationFold ref registry key =>
    simp only [applicationAction, RefundApplication.applicationAction,
      OpenDatumApplicationHeld.applicationAction, ApplicationAction.inputReference] at ha
    repeat' first
      | (split at ha)
      | (simp_all [terminationSpend])

theorem approval_open (h : Hash) (c : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (o : ApplicationObservation)
    (outside : o.inputs.all (fun input => input.credential != release.applicationCredential) = true)
    (actions : o.actions = [.approvalBurn]) (donation : o.donation = 0)
    (mint : o.assets.mint.all (fun entry => entry.1.policy != release.applicationPolicy ||
      SingularApplicationHeld.Assets.mintQty o.assets entry.1 ≤ 0) = true) :
    applicationStep .none h c decode release o = true := by
  have empty : (o.inputs.filter fun input => input.credential == release.applicationCredential) = [] := by
    apply List.filter_eq_nil_iff.mpr
    intro input member
    have hi := List.all_eq_true.mp outside input member
    simpa using hi
  simpa [applicationStep, RefundApplication.applicationStep, actions, empty,
    appGuard_none, applicationAction, RefundApplication.applicationAction,
    OpenDatumApplicationHeld.applicationAction, requestValueSplit, requiredPayments,
    requiredTreasury, birth, donation, ApplicationAction.inputReference,
    ApplicationAction.birthIndex] using mint

theorem burn_maps (h : Hash) (c : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (o : ApplicationObservation) (actions : List ApplicationAction)
    (only : actions.all (· == .approvalBurn) = true) :
    actions.filterMap ApplicationAction.inputReference = [] ∧
    actions.filterMap (birth h c decode release o) = [] := by
  induction actions with
  | nil => exact ⟨rfl, rfl⟩
  | cons a rest ih =>
    have both : (a == .approvalBurn) = true ∧ rest.all (· == .approvalBurn) = true := by
      simpa only [List.all_cons, Bool.and_eq_true] using only
    have same : a = .approvalBurn := by
      cases a <;> first | rfl | exact False.elim (Bool.noConfusion both.1)
    subst a
    simpa [ApplicationAction.inputReference, birth] using ih both.2

theorem burn_only (h : Hash) (c : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (o : ApplicationObservation)
    (accepted : applicationStep .none h c decode release o = true) :
    burnOnlyEffect release o = true := by
  unfold burnOnlyEffect
  split
  · rename_i only
    obtain ⟨refs, births⟩ := burn_maps h c decode release o o.actions only
    simp only [applicationStep, RefundApplication.applicationStep, appGuard_none, refs,
      births, Bool.and_eq_true] at accepted
    have empty : (o.inputs.filter fun input => input.credential == release.applicationCredential) = [] := by
      have size := accepted.1.1.1.1.1.2
      have zero : (o.inputs.filter fun input => input.credential == release.applicationCredential).length = 0 := by
        have reverse : 0 = (o.inputs.filter fun input => input.credential == release.applicationCredential).length := by
          simpa only [beq_iff_eq] using size
        exact reverse.symm
      exact List.length_eq_zero_iff.mp zero
    simp only [Bool.and_eq_true]
    constructor
    · apply List.all_eq_true.mpr
      intro input member
      have absent := List.filter_eq_nil_iff.mp empty input member
      simpa using absent
    · simpa using accepted.1.2
  · rfl

theorem booking_effects (h : Hash) (c : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (o : ApplicationObservation)
    (accepted : applicationStep .none h c decode release o = true) :
    bookingEffects h c decode release o = true := by
  apply List.all_eq_true.mpr
  intro a member
  have ha := accepted_actions h c decode release o accepted a member
  cases a <;> try rfl
  case bookRegistration index =>
    simp only [applicationAction, RefundApplication.applicationAction,
      OpenDatumApplicationHeld.applicationAction] at ha
    dsimp only [Id.run, pure, bind] at ha ⊢
    repeat' first | (split at ha) | (split) | (solve | simp_all)
    all_goals
      try dsimp only [Id.run, pure, bind] at ha ⊢
      simp only [registrationBook, appGuard_none, Bool.and_eq_true, List.any_eq_true] at ha
      simp_all only [Option.some.injEq, ApplicationDatum.registration.injEq]
      simp only [Bool.and_eq_true]
      refine ⟨by trivial, ?_⟩
      rcases ha.1.2 with ⟨configuration, member, hc⟩
      apply List.any_eq_true.mpr
      refine ⟨configuration, member, ?_⟩
      cases hd : configuration.datum <;>
        simp_all [configurationRead, configurationShape, registrationClock,
          nonemptyInterval, Bool.and_eq_true]
  case bookTermination ref index =>
    simp only [applicationAction, RefundApplication.applicationAction,
      OpenDatumApplicationHeld.applicationAction, ApplicationAction.inputReference] at ha
    dsimp only [Id.run, pure, bind] at ha ⊢
    repeat' first | (split at ha) | (split) | (solve | simp_all [terminationBook])



theorem member_le_sum (xs : List Nat) (n : Nat) (member : n ∈ xs) : n ≤ xs.sum := by
  induction xs with
  | nil => simp at member
  | cons x xs ih =>
    simp only [List.mem_cons] at member
    simp only [List.sum_cons]
    rcases member with rfl | member
    · omega
    · have := ih member; omega


theorem debt_paid (h : Hash) (c : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (o : ApplicationObservation)
    (accepted : applicationStep .none h c decode release o = true)
    (address amount : Nat) (member : (address, amount) ∈ requiredPayments decode o) :
    amount ≤ paidTo o.outputs address := by
  have floors : (requiredPayments decode o).all (fun entry =>
      (((requiredPayments decode o).filter fun other => other.1 == entry.1).map (·.2)).sum ≤
        paidTo o.outputs entry.1) = true := by
    simp only [applicationStep, RefundApplication.applicationStep, Bool.and_eq_true,
      requestValueSplit, appGuard_none] at accepted
    exact accepted.2.1
  have floor := List.all_eq_true.mp floors (address, amount) member
  have included : amount ∈ (((requiredPayments decode o).filter fun other => other.1 == address).map (·.2)) := by
    apply List.mem_map.mpr
    exact ⟨(address, amount), List.mem_filter.mpr ⟨member, by simp⟩, rfl⟩
  have bounded := member_le_sum _ amount included
  have bound : _ ≤ paidTo o.outputs address := of_decide_eq_true floor
  exact Nat.le_trans bounded bound


theorem processing_bounds (r : RegistrationData) (i : Interval)
    (phase : classifyPhase r i = .processing) : i.lower < i.upper ∧ i.upper ≤ r.processDeadline := by
  unfold classifyPhase at phase
  repeat' first | (split at phase) | (solve | simp_all [nonemptyInterval])


theorem reclaim_bounds (r : RegistrationData) (i : Interval)
    (phase : classifyPhase r i = .reclaim) :
    i.lower < i.upper ∧ r.processDeadline ≤ i.lower ∧ i.upper ≤ r.reclaimEnd := by
  unfold classifyPhase at phase
  repeat' first | (split at phase) | (solve | simp_all [nonemptyInterval])


theorem cleanup_bounds (r : RegistrationData) (i : Interval)
    (phase : classifyPhase r i = .cleanup) : i.lower < i.upper ∧ r.reclaimEnd ≤ i.lower := by
  unfold classifyPhase at phase
  repeat' first | (split at phase) | (solve | simp_all [nonemptyInterval])


theorem registration_not_empty (decode : DecodeApplication) (input : ObservedOutput)
    (r : RegistrationData) (hd : decoded decode input = some (.registration r)) : input.datum ≠ .empty := by
  intro empty
  simp [decoded, empty] at hd


theorem registration_action (h : Hash) (c : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (o : ApplicationObservation) (a : ApplicationAction)
    (ref : OutRef) (input : ObservedOutput) (r : RegistrationData)
    (href : a.inputReference = some ref)
    (found : o.inputs.find? (fun input => input.reference == ref) = some input)
    (hd : decoded decode input = some (.registration r))
    (ha : applicationAction .none h c decode release o a = true) :
    RefundApplication.registrationSpend .none h c release a input r o = true := by
  have ne := registration_not_empty decode input r hd
  cases a <;> simp_all [ApplicationAction.inputReference, applicationAction,
    RefundApplication.applicationAction, OpenDatumApplicationHeld.applicationAction,
    RefundApplication.registrationSpend, registrationSpend, terminationSpend, terminationShape,
    decoded]
  all_goals
    dsimp only [Id.run, pure, bind] at ha
    repeat' first | (split at ha) | (solve | simp_all)
  all_goals
    have empty : input.datum = .empty := by
      cases datum : input.datum <;> simp_all [BEq.beq, instBEqOutputDatum.beq]
    exact ne empty


theorem registration_effects (h : Hash) (c : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (o : ApplicationObservation)
    (accepted : applicationStep .none h c decode release o = true) :
    registrationEffects h c decode o = true := by
  apply List.all_eq_true.mpr
  intro a member
  cases href : a.inputReference with
  | none => simp [href]
  | some ref =>
    cases found : o.inputs.find? (fun input => input.reference == ref) with
    | none => simp [href, found]
    | some input =>
      cases hd : decoded decode input with
      | none => simp [href, found, hd]
      | some datum =>
        cases datum with
        | live control payload => simp [href, found, hd]
        | registration r =>
          simp only [href, found, hd]
          have ha := registration_action h c decode release o a ref input r href found hd
            (accepted_actions h c decode release o accepted a member)
          cases a <;> simp_all only [ApplicationAction.inputReference, Option.some.injEq, reduceCtorEq]
          all_goals subst ref
          all_goals simp only [RefundApplication.registrationSpend, registrationSpend,
            appGuard_none, Bool.and_eq_true, reduceCtorEq, and_false] at ha
          case registrationFold reference index =>
            have phase : classifyPhase r o.interval = .processing := by
              exact beq_iff_eq.mp ha.2.1
            have bounds := processing_bounds r o.interval phase
            simpa only [registrationEffect, Bool.and_eq_true, decide_eq_true_eq] using
              And.intro bounds ha.2.2
          case ownerReclaim reference =>
            have phase : classifyPhase r o.interval = .reclaim := by
              exact beq_iff_eq.mp ha.2.1
            have bounds := reclaim_bounds r o.interval phase
            have debt : (r.refundAddress, input.lovelace) ∈ requiredPayments decode o := by
              unfold requiredPayments
              apply List.mem_filterMap.mpr
              exact ⟨.ownerReclaim reference, member, by simp [ApplicationAction.inputReference, found, hd]⟩
            have paid := debt_paid h c decode release o accepted _ _ debt
            simpa only [registrationEffect, Bool.and_eq_true, decide_eq_true_eq] using
              And.intro (And.intro (And.intro (And.intro bounds.1 bounds.2.1) bounds.2.2) ha.2.2) paid
          case expiredCleanup reference =>
            have phase : classifyPhase r o.interval = .cleanup := by
              exact beq_iff_eq.mp ha.2
            have bounds := cleanup_bounds r o.interval phase
            have debt : (r.refundAddress, r.deposit) ∈ requiredPayments decode o := by
              unfold requiredPayments
              apply List.mem_filterMap.mpr
              exact ⟨.expiredCleanup reference, member, by simp [ApplicationAction.inputReference, found, hd]⟩
            have paid := debt_paid h c decode release o accepted _ _ debt
            simpa only [registrationEffect, Bool.and_eq_true, decide_eq_true_eq] using
              And.intro (And.intro bounds.1 bounds.2) paid


theorem unique_find {α : Type} (xs : List α) (p : α → Bool) (a : α)
    (member : a ∈ xs) (pa : p a = true) (one : (xs.filter p).length = 1) :
    xs.find? p = some a := by
  induction xs with
  | nil => simp at member
  | cons x xs ih =>
    by_cases px : p x = true
    · have empty : xs.filter p = [] := by
        apply List.length_eq_zero_iff.mp
        simpa [List.filter_cons, px] using one
      rcases List.mem_cons.mp member with rfl | inside
      · simp [px]
      · have bad := List.mem_filter.mpr ⟨inside, pa⟩
        simp [empty] at bad
    · have inside : a ∈ xs := by
        rcases List.mem_cons.mp member with rfl | inside
        · exact False.elim (px pa)
        · exact inside
      have next : (xs.filter p).length = 1 := by simpa [List.filter_cons, px] using one
      simpa [List.find?_cons, px] using ih inside next


theorem action_source (h : Hash) (c : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (o : ApplicationObservation) (a : ApplicationAction)
    (ref : OutRef) (href : a.inputReference = some ref)
    (ha : applicationAction .none h c decode release o a = true) :
    ∃ input, o.inputs.find? (fun input => input.reference == ref) = some input ∧
      (o.inputs.filter fun input => input.reference == ref).length = 1 := by
  cases a <;> simp_all [ApplicationAction.inputReference, applicationAction,
    RefundApplication.applicationAction, OpenDatumApplicationHeld.applicationAction]
  all_goals
    dsimp only [Id.run, pure, bind] at ha
    repeat' first | (split at ha) | (solve | simp_all [requestInput, appGuard_none])
  all_goals
    simp only [requestInput, appGuard_none, Bool.and_eq_true, beq_iff_eq] at *
    grind


theorem configuration_refused (h : Hash) (c : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (o : ApplicationObservation) (a : ApplicationAction)
    (ref : OutRef) (input : ObservedOutput) (parameters : ApplicationParameters)
    (href : a.inputReference = some ref)
    (found : o.inputs.find? (fun input => input.reference == ref) = some input)
    (datum : input.datum = .configuration parameters) :
    applicationAction .none h c decode release o a = false := by
  cases a <;> simp_all [ApplicationAction.inputReference, applicationAction,
    RefundApplication.applicationAction, OpenDatumApplicationHeld.applicationAction,
    terminationSpend, terminationShape, decoded, datum]
  all_goals
    dsimp only [Id.run, pure, bind]
    repeat' first | split | (solve | simp_all [BEq.beq, instBEqOutputDatum.beq])


theorem configuration_protected (h : Hash) (c : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (o : ApplicationObservation)
    (accepted : applicationStep .none h c decode release o = true) :
    configurationProtected release o = true := by
  have coverage : (o.inputs.filter fun output => output.credential == release.applicationCredential).all
      (fun input => (o.actions.filterMap ApplicationAction.inputReference).contains input.reference) = true := by
    simp only [applicationStep, RefundApplication.applicationStep, appGuard_none, Bool.and_eq_true] at accepted
    exact accepted.1.1.1.1.2
  apply List.all_eq_true.mpr
  intro input member
  by_cases credential : input.credential = release.applicationCredential
  · cases datum : input.datum <;> simp [datum, credential]
    rename_i parameters
    have covered := List.all_eq_true.mp coverage input (List.mem_filter.mpr ⟨member, by simp [credential]⟩)
    have inRefs : input.reference ∈ o.actions.filterMap ApplicationAction.inputReference := by simpa using covered
    obtain ⟨a, am, href⟩ := List.mem_filterMap.mp inRefs
    have ha := accepted_actions h c decode release o accepted a am
    obtain ⟨selected, found, one⟩ := action_source h c decode release o a input.reference href ha
    have actual := unique_find o.inputs (fun output => output.reference == input.reference) input member (by simp) one
    have refused := configuration_refused h c decode release o a input.reference input parameters href actual datum
    simp [refused] at ha
  · simp [credential]


theorem countP_le_count_filterMap {α β : Type} [BEq β] [LawfulBEq β] (xs : List α)
    (p : α → Bool) (f : α → Option β) (x : β) (selected : ∀ a, p a = true → f a = some x) :
    xs.countP p ≤ (xs.filterMap f).count x := by
  induction xs with
  | nil => simp
  | cons a rest ih =>
    cases pa : p a
    · rw [List.countP_cons_of_neg (by simp [pa])]
      cases fa : f a with
      | none => rw [List.filterMap_cons_none fa]; exact ih
      | some b =>
        rw [List.filterMap_cons_some fa, List.count_cons]
        split <;> omega
    · have fa := selected a pa
      rw [List.countP_cons_of_pos (by simp [pa]), List.filterMap_cons_some fa, List.count_cons_self]
      omega


theorem configuration_minted_once (h : Hash) (c : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (o : ApplicationObservation)
    (accepted : applicationStep .none h c decode release o = true)
    (registry : TokenId) (seed : OutRef) (index : Nat)
    (member : ApplicationAction.configurationCreate registry seed index ∈ o.actions) :
    configurationCreations registry o.actions = 1 ∧
      SingularApplicationHeld.Assets.mintQty o.assets (configurationAsset h c release registry) = 1 := by
  have created := accepted_actions h c decode release o accepted _ member
  rw [action_eq] at created
  unfold applicationActionConditions at created
  dsimp only [Id.run, pure, bind] at created
  split at created
  · unfold configurationCreateConditions at created
    simp only [Bool.and_eq_true, beq_iff_eq] at created
    have mint : SingularApplicationHeld.Assets.mintQty o.assets (configurationAsset h c release registry) = 1 := by
      omega
    have fresh := created.2
    unfold freshAssetConditions at fresh
    simp only [Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq, Int.ofNat_eq_natCast] at fresh
    have births : (o.actions.filterMap (birthConditions h c decode release o)).count
        (configurationAsset h c release registry) = 1 := by omega
    have bound : configurationCreations registry o.actions ≤
        (o.actions.filterMap (birthConditions h c decode release o)).count
          (configurationAsset h c release registry) :=
      countP_le_count_filterMap o.actions _ (birthConditions h c decode release o) _
        (by
          intro action chosen
          cases action <;> simp at chosen
          rename_i created _ _
          have same : created = registry := chosen
          subst same
          rfl)
    have lower : 0 < configurationCreations registry o.actions :=
      List.countP_pos_iff.mpr ⟨_, member, by simp⟩
    exact ⟨by omega, mint⟩
  · simp at created


theorem termination_quantity (h : Hash) (c : Codec) (release : PublishedRelease)
    (o : ApplicationObservation) (input : ObservedOutput) (registry : TokenId) (key : Key)
    (member : input ∈ o.inputs)
    (spend : terminationSpend .none h c release input registry key o = true) :
    quantity input (activeAsset h c registry key) = 1 := by
  simp only [terminationSpend, appGuard_none, Bool.and_eq_true] at spend
  have shape := spend.1.1.1
  simp only [terminationShape, appGuard_none, Bool.and_eq_true] at shape
  have qty := SingularApplicationHeld.Proofs.public_exact_at input _ shape.2
    (activeAsset h c registry key)
  have burned := spend.1.1.2
  simp only [approvalBurned, appGuard_none, decide_eq_true_eq] at burned
  have mint : SingularApplicationHeld.Assets.mintQty o.assets (activeAsset h c registry key) = -1 := beq_iff_eq.mp spend.1.2
  by_cases same : activeAsset h c registry key = terminationApproval h c release registry key
  · have bound := member_le_sum (o.inputs.map fun out => quantity out (terminationApproval h c release registry key))
      (quantity input (terminationApproval h c release registry key)) (List.mem_map.mpr ⟨input, member, rfl⟩)
    simp [same] at qty
    rw [same] at mint
    simp only [approvalsConsumed, Int.ofNat_eq_natCast] at burned
    omega
  · simpa [same, Ne.symm same] using qty


theorem folder_protected (h : Hash) (c : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (o : ApplicationObservation)
    (accepted : applicationStep .none h c decode release o = true) :
    folderProtection h c decode release o = true := by
  apply List.all_eq_true.mpr
  intro a member
  have ha := accepted_actions h c decode release o accepted a member
  cases href : a.inputReference with
  | none => simp
  | some ref =>
    cases found : o.inputs.find? (fun input => input.reference == ref) with
    | none => simp [found]
    | some input =>
      have im := List.mem_of_find?_eq_some found
      cases hd : decoded decode input with
      | some datum =>
        cases datum with
        | registration r =>
          simp only [found, hd]
          split
          · rename_i early
            have spend := registration_action h c decode release o a ref input r href found hd ha
            cases a <;> simp_all [ApplicationAction.inputReference,
              RefundApplication.registrationSpend, registrationSpend, classifyPhase, nonemptyInterval]
            all_goals split at spend <;> simp_all
          · rfl
        | live control payload =>
          have notEmpty : input.datum ≠ .empty := by
            intro empty
            simp [decoded, empty] at hd
          have ne : (input.datum == .empty) = false := by
            cases datum : input.datum <;> simp_all [BEq.beq, instBEqOutputDatum.beq]
          simp [found, hd, ne]
      | none =>
        simp only [found, hd]
        split
        · rename_i empty
          have ed : input.datum = .empty := by
            cases datum : input.datum <;> simp_all [BEq.beq, instBEqOutputDatum.beq]
          cases a <;> simp_all [ApplicationAction.inputReference, applicationAction,
            RefundApplication.applicationAction, OpenDatumApplicationHeld.applicationAction, decoded, ed]
          all_goals
            dsimp only [Id.run, pure, bind] at ha
            repeat' first | (split at ha) | (solve | simp_all)
          all_goals
            rename_i registry key guard
            have spend : terminationSpend .none h c release input registry key o = true := by assumption
            have qty := termination_quantity h c release o input registry key im spend
            simp only [terminationSpend, appGuard_none, Bool.and_eq_true] at spend
            simp_all
        · rfl


theorem termination_available (h : Hash) (c : Codec) (t : TrieCommit) (q : Input)
    (premises : TerminationPremises h c t q) : terminationAvailable .none h c t q := by
  rcases premises with ⟨pub, policies, credentials, encoding, collision, output, registry, key, requests⟩
  have p : PublicPremises h c t q.query := ⟨pub, policies, encoding, collision⟩
  have conclusion := SingularApplicationHeld.Statements.public_fold_constructed h c t q.query p
  refine ⟨conclusion.1, ?_, conclusion.2.1, conclusion.2.2.2⟩
  let built := buildFold h c t q.query.release q.query.observation.before q.query.requests q.query.funding
  let v := applicationFoldView built q.query.requests
  change applicationStep .none h c (queryDecode q.query) q.query.release v = true
  have member : PendingRequest.termination output registry key ∈ q.query.requests := by simp [requests]
  have source := pub.2.2.2.2.2.2.2.2.2.2.2.2 _ member
  have registryEq : registry = q.query.observation.before.identity := source.1
  have auth : terminationShape .none h c q.query.release output registry key = true := source.2.1
  have shape := auth
  simp only [terminationShape, appGuard_none, Bool.and_eq_true] at shape
  have outputCred : output.credential = q.query.release.applicationCredential := beq_iff_eq.mp shape.1.1
  have outputEmpty : output.datum = .empty := by
    cases datum : output.datum <;> simp_all [BEq.beq, instBEqOutputDatum.beq]
  have recognized := pub.2.2.2.1
  have stateAssets := SingularApplicationHeld.Proofs.recognized_assets h c q.query.release
    q.query.observation.before.seed q.query.observation.before.state recognized
  have stateCred : q.query.observation.before.state.credential = q.query.release.statePolicy := by
    simp only [recognizeState, SingularApplicationHeld.Proofs.applyGuard_none, Bool.and_eq_true] at recognized
    exact beq_iff_eq.mp recognized.1.1.1.1.1
  have ordinaryAssets := pub.2.2.2.2.2.2.2.1
  have ordinaryCred := pub.2.2.2.2.2.2.2.2.1
  have inputs : v.inputs = [q.query.observation.before.state, output, q.query.funding.ordinaryInput] := by
    simp [v, applicationFoldView, built, requests, PendingRequest.output, SingularApplicationHeld.Proofs.public_build_inputs]
  have actions : v.actions = [.terminationFold output.reference registry key] := by
    simp [v, applicationFoldView, requests]
  have appInputs : (v.inputs.filter fun input => input.credential == q.query.release.applicationCredential) = [output] := by
    rw [inputs]
    simp [stateCred, Ne.symm credentials, outputCred, ordinaryCred]
  have distinct : (v.inputs.map (·.reference)).Nodup := by
    rw [inputs]
    simpa [requests] using pub.2.2.2.2.2.2.2.2.2.2.1
  have unique := SingularApplicationHeld.Proofs.public_input_unique v.inputs distinct output (by simp [inputs])
  have spent : v.assets.spent = v.inputs.map (·.reference) := by
    rw [inputs]
    simp [v, applicationFoldView, built, requests, PendingRequest.output, SingularApplicationHeld.Proofs.public_build_spent]
  have request : requestInput .none v output.reference output = true := by
    simp [requestInput, spent, unique.2.1, unique.2.2]
  have different : activeAsset h c registry key ≠ terminationApproval h c q.query.release registry key := by
    intro same
    have eq := congrArg TokenId.policy same
    simp only [activeAsset, terminationApproval, registryEq, pub.2.2.2.2.1, stateAsset] at eq
    exact policies eq.symm
  have noStateApproval : stateAsset h c q.query.release q.query.observation.before.seed ≠
      terminationApproval h c q.query.release registry key := by
    intro same
    exact policies (congrArg TokenId.policy same).symm
  have outputApproval := SingularApplicationHeld.Proofs.public_exact_at output _ shape.2
    (terminationApproval h c q.query.release registry key)
  have approvalQty : quantity output (terminationApproval h c q.query.release registry key) = 1 := by
    simpa [different] using outputApproval
  have total : approvalsConsumed v (terminationApproval h c q.query.release registry key) = 1 := by
    have stateZero : quantity q.query.observation.before.state
        (terminationApproval h c q.query.release registry key) = 0 := by
      simp [quantity, stateAssets, noStateApproval]
    have fundingZero : quantity q.query.funding.ordinaryInput
        (terminationApproval h c q.query.release registry key) = 0 := by
      simp [quantity, ordinaryAssets]
    simp [approvalsConsumed, inputs, stateZero, fundingZero, approvalQty]
  have mint := SingularApplicationHeld.Proofs.public_build_mint_at h c t q.query p _ member
  have mintApproval : SingularApplicationHeld.Assets.mintQty v.assets (terminationApproval h c q.query.release registry key) = -1 := mint.1
  have mintActive : SingularApplicationHeld.Assets.mintQty v.assets (activeAsset h c registry key) = -1 := mint.2
  have burned : approvalBurned .none v (terminationApproval h c q.query.release registry key) = true := by
    simp [approvalBurned, total, mintApproval]
  have invoked : v.assets.invoked.contains registry.policy = true := by
    have reg : registry.policy = q.query.release.statePolicy := by
      rw [registryEq, pub.2.2.2.2.1]
      rfl
    simp [v, applicationFoldView, built, SingularApplicationHeld.buildFold, reg]
  have action : applicationAction .none h c (queryDecode q.query) q.query.release v
      (.terminationFold output.reference registry key) = true := by
    simp [applicationAction, RefundApplication.applicationAction, OpenDatumApplicationHeld.applicationAction,
      ApplicationAction.inputReference, unique.1, request, terminationSpend, auth, burned, mintActive, Id.run, pure, bind]
    simpa using invoked
  have mintList : v.assets.mint = [(activeAsset h c registry key, -1),
      (terminationApproval h c q.query.release registry key, -1)] := by
    simpa [v, applicationFoldView, built, requests, SingularApplicationHeld.Proofs.publicApproval,
      SingularApplicationHeld.Proofs.publicApprovalPreimage, SingularApplicationHeld.Proofs.publicSign,
      terminationApproval] using SingularApplicationHeld.Proofs.public_build_mint_maps h c t q.query p
  have mintOnly : v.assets.mint.all (fun entry => entry.1.policy != q.query.release.applicationPolicy ||
      SingularApplicationHeld.Assets.mintQty v.assets entry.1 ≤ 0) = true := by
    rw [mintList]
    simp [mintActive, mintApproval]
  have donation : v.donation = 0 := rfl
  have emptyDecode : decoded (queryDecode q.query) output = none := by simp [decoded, outputEmpty]
  simpa [applicationStep, RefundApplication.applicationStep, appInputs, actions,
    ApplicationAction.inputReference, ApplicationAction.birthIndex, action, birth,
    requestValueSplit, requiredPayments, unique.1, emptyDecode, requiredTreasury, donation] using mintOnly

end OpenDatumApplicationHeld.RefundLifecycle.Proofs
