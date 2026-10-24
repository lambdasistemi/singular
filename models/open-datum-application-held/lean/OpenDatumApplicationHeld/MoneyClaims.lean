import OpenDatumApplicationHeld.Money


namespace OpenDatumApplicationHeld.Money
open Singular Lean SingularApplicationHeld


def stageAction : Journey → ApplicationAction → Bool
  | .create, .configurationCreate .. | .registrationBooking, .bookRegistration ..
  | .registrationFold, .registrationFold .. | .update, .liveUpdate ..
  | .terminationBooking, .bookTermination .. | .terminationFold, .terminationFold ..
  | .reclaim, .ownerReclaim .. | .cleanup, .expiredCleanup .. => true
  | _, _ => false

def parametersOf (b : Baseline) : ApplicationParameters :=
  ⟨b.configuration.registrationCost, b.configuration.minimumTip,
    b.configuration.processTime, b.configuration.retractTime, b.configuration.bookingWidth⟩

def oldGenesis (b : Baseline) : RegistryState :=
  ⟨{ b.configuration with root := rootOf [] }, [], []⟩

def builtFor (h : Hash) (c : Codec) (t : TrieCommit) (journey : Journey) (q : Input) : FoldObservation :=
  buildFold h c t q.lifecycle.query.release q.lifecycle.query.observation.before
    [if journey == .registrationFold then q.registration else q.termination] q.lifecycle.query.funding

abbrev FoldPremise (h : Hash) (c : Codec) (t : TrieCommit) (journey : Journey) (q : Input) : Prop :=
  let built := builtFor h c t journey q
  foldConditions h c t q.lifecycle.query.release built = true ∧
  q.lifecycle.observation = applicationFoldView built
    [if journey == .registrationFold then q.registration else q.termination] ∧
  q.lifecycle.query.funding.fee ≤ q.lifecycle.query.funding.ordinaryInput.lovelace ∧
  q.lifecycle.query.funding.processorAddress ≠ built.before.state.credential ∧
  q.lifecycle.query.funding.processorAddress ≠ q.lifecycle.query.release.applicationCredential

abbrev FoldOutcome (m : Mutation) (h : Hash) (c : Codec) (t : TrieCommit)
    (journey : Journey) (q : Input) : Prop :=
  let built := builtFor h c t journey q
  fold .none h c t q.lifecycle.query.release built = true ∧
  batchEffects t built ∧ built.donation = 0 ∧ built.signers = [] ∧
  (if journey == .registrationFold then
    trieGet built.after.trie q.registration.key = .known .active ∧
    SingularApplicationHeld.Assets.mintQty built.assets (activeAsset h c q.registration.registry q.registration.key) = 1
   else trieGet built.after.trie q.termination.key = .known .terminal ∧
    SingularApplicationHeld.Assets.mintQty built.assets (activeAsset h c q.termination.registry q.termination.key) = -1) ∧
  paidTo built.outputs q.lifecycle.query.funding.processorAddress =
    (newAllocation m journey q).folder + q.lifecycle.query.funding.ordinaryInput.lovelace -
      q.lifecycle.query.funding.fee

def updateEffect (decode : DecodeApplication) (o : ApplicationObservation) : Bool :=
  o.actions.all fun action => match action with
  | .liveUpdate ref index => match o.inputs.find? (fun input => input.reference == ref), o.outputs[index]? with
    | some input, some output => match decoded decode input, decoded decode output with
      | some (.live before _), some (.live after _) =>
          before == after && exactAssets output input.assets && before.deposit ≤ output.lovelace &&
          o.signers.contains before.controller
      | _, _ => false
    | _, _ => false
  | _ => true

abbrev CreatePremise (h : Hash) (c : Codec) (t : TrieCommit) (q : Input) : Prop :=
  genesisConditions h c t q.lifecycle.query.release q.lifecycle.query.seed
    q.lifecycle.observation.assets q.lifecycle.observation.outputs = true ∧
  ∀ output ∈ q.lifecycle.observation.outputs,
    (∃ p, output.datum = .configuration p) → output.datum = .configuration (parametersOf q.baseline)

def stageCorrespondence (decode : DecodeApplication) (journey : Journey) (q : Input) : Bool :=
  let o := q.lifecycle.observation
  match journey, q.lifecycle.action with
  | .registrationBooking, .bookRegistration index =>
      o.outputs[index]? == some q.registration.output && match q.registration with
      | .registration output data => decoded decode output == some (.registration data)
      | _ => false
  | .terminationBooking, .bookTermination ref index =>
      o.outputs[index]? == some q.termination.output && match o.inputs.find? (fun input => input.reference == ref) with
      | some input => match decoded decode input with
        | some (.live control _) => control.deposit == q.deposit
        | _ => false
      | none => false
  | .reclaim, .ownerReclaim ref | .cleanup, .expiredCleanup ref =>
      ref == q.registration.output.reference && o.inputs.contains q.registration.output && match q.registration with
      | .registration output data => decoded decode output == some (.registration data)
      | _ => false
  | .update, .liveUpdate ref _ => match o.inputs.find? (fun input => input.reference == ref) with
      | some input => match decoded decode input with
        | some (.live control _) => control.deposit == q.deposit
        | _ => false
      | none => false
  | .create, .configurationCreate .. | .registrationFold, .registrationFold ..
  | .terminationFold, .terminationFold .. => true
  | _, _ => false

def actualMoneyEffect (journey : Journey) (q : Input) : Bool :=
  let o := q.lifecycle.observation
  match journey with
  | .terminationBooking => o.donation == q.deposit
  | .reclaim | .cleanup => match q.registration with
    | .registration output data =>
        (if journey == .reclaim then output.lovelace else data.deposit) ≤ paidTo o.outputs data.refundAddress
    | _ => false
  | _ => o.donation == 0

abbrev NewPremise (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (journey : Journey) (q : Input) : Prop :=
  Correspondence q ∧ q.lifecycle.query.release = release ∧
  RefundLifecycle.applicationStepConditions h c decode release q.lifecycle.observation = true ∧
  stageAction journey q.lifecycle.action = true ∧ q.lifecycle.observation.actions = [q.lifecycle.action] ∧
  stageCorrespondence decode journey q = true ∧
  (if journey == .registrationFold || journey == .terminationFold then FoldPremise h c t journey q else True) ∧
  (if journey == .create then CreatePremise h c t q else True)

abbrev NewClaim (m : Mutation) (h : Hash) (c : Codec) (t : TrieCommit) (decode : DecodeApplication)
    (release : PublishedRelease) (journey : Journey) (q : Input) : Prop :=
  RefundApplication.applicationStep (appMutation m) h c decode release q.lifecycle.observation = true ∧
  RefundLifecycle.registrationEffects h c decode q.lifecycle.observation = true ∧
  RefundLifecycle.terminationEffects h c q.lifecycle.observation = true ∧
  RefundLifecycle.paymentEffects decode q.lifecycle.observation = true ∧
  RefundLifecycle.treasuryEffect decode q.lifecycle.observation = true ∧
  updateEffect decode q.lifecycle.observation = true ∧
  actualMoneyEffect journey q = true ∧
  AllDifferences m journey q ∧
  (if journey == .registrationFold || journey == .terminationFold then FoldOutcome m h c t journey q else True) ∧
  (if journey == .create then Singular.Reachable (oldGenesis q.baseline) ∧
      genesis .none h c t release q.lifecycle.query.seed
        q.lifecycle.observation.assets q.lifecycle.observation.outputs = true else True) ∧
  (if journey == .reclaim then q.lifecycle.observation.signers.contains
      q.baseline.registration.request.refundAddress = true else True)

abbrev OldPremise (q : Input) : Prop := Correspondence q ∧
  registrationBookingRefusal q.baseline.configuration q.baseline.registration = none ∧
  terminationExactContents q.baseline.configuration q.baseline.termination.request = true

abbrev OldClaim (m : Mutation) (q : Input) : Prop :=
  (oldAllocation m .registrationFold q.baseline).holding = q.baseline.registration.request.carrierAda ∧
  (oldAllocation m .registrationFold q.baseline).folder = q.baseline.registration.request.declaredTip ∧
  (oldAllocation m .registrationFold q.baseline).treasury = q.baseline.registration.request.registrationCost ∧
  (oldAllocation m .terminationFold q.baseline).folder = q.baseline.termination.request.declaredTip ∧
  (oldAllocation m .terminationFold q.baseline).treasury = q.baseline.termination.request.carrierAda ∧
  (oldAllocation m .reclaim q.baseline).refund = q.baseline.registration.request.contents.lovelace ∧
  (oldAllocation m .cleanup q.baseline).refund = q.baseline.registration.request.registrationCost + q.deposit

abbrev OldUpdatePremise (world : OpenDatumApplication.World) (ref : Nat) (signers : List Nat) : Prop :=
  ∃ input, OpenDatumApplication.outputAt world ref = some input ∧ input.envelope.control.controller ∉ signers

abbrev OldUpdateClaim (m : Mutation) (world : OpenDatumApplication.World) (ref : Nat)
    (successors : List OpenDatumApplication.Successor) (signers : List Nat) : Prop :=
  (oldUpdate m world ref successors signers).isOk = false

end OpenDatumApplicationHeld.Money
