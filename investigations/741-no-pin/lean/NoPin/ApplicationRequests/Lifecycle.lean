import NoPin.ApplicationRequests.LifecycleConditions
import NoPin.ApplicationRequests.Oracle

/-! Hypotheses under #741, not accepted law. Independent observations of the
application lifecycle. Fees, complete public observations, authentic policy
invocations and real output minima remain external premises. -/
namespace NoPin.ApplicationRequests.Lifecycle
open Singular Lean

/- Hypothesis under #741, not accepted law; same transaction data are serializable. -/
deriving instance ToJson, FromJson for ApplicationObservation
/-- Hypothesis under #741, not accepted law; generic definition calls, never theorem names. -/
inductive Surface where
  | action | step | publicTermination
  deriving Repr, BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; complete explicit definition arguments. -/
structure Input where
  query : Query
  observation : ApplicationObservation
  action : ApplicationAction
  deriving ToJson, FromJson
/-- Hypothesis under #741, not accepted law; a named definition and one atomic selector. -/
structure Scenario where
  surface : Surface
  input : Input
  mutation : AppMutation
  deriving ToJson, FromJson
/-- Hypothesis under #741, not accepted law; source-derived constructor names bound by report. -/
def actionName : ApplicationAction → String
  | .configurationCreate .. => "configurationCreate"
  | .bookRegistration .. => "bookRegistration"
  | .bookTermination .. => "bookTermination"
  | .registrationFold .. => "registrationFold"
  | .ownerReclaim .. => "ownerReclaim"
  | .expiredCleanup .. => "expiredCleanup"
  | .terminationFold .. => "terminationFold"
  | .liveUpdate .. => "liveUpdate"
  | .approvalBurn => "approvalBurn"
/-- Hypothesis under #741, not accepted law; all registration effects read actual outputs. -/
def registrationEffect (h : Hash) (c : Codec) (o : ApplicationObservation)
    (a : ApplicationAction) (input : ObservedOutput) (r : RegistrationData) : Bool :=
  match a with
  | .registrationFold _ index => o.interval.lower < o.interval.upper &&
      o.interval.upper ≤ r.processDeadline && match o.outputs[index]? with
      | some holding => holding.credential == r.holdingAddress &&
          holding.datum == .application r.initialDatum && holding.lovelace == r.deposit &&
          quantity holding (activeAsset h c r.registry r.key) == 1 &&
          NoPin.mintQty o.assets (activeAsset h c r.registry r.key) == 1
      | none => false
  | .ownerReclaim _ => o.interval.lower < o.interval.upper &&
      r.processDeadline ≤ o.interval.lower && o.interval.upper ≤ r.reclaimEnd &&
      o.signers.contains r.controller && input.lovelace ≤ paidTo o.outputs r.refundAddress
  | .expiredCleanup _ => o.interval.lower < o.interval.upper && r.reclaimEnd ≤ o.interval.lower &&
      r.deposit ≤ paidTo o.outputs r.refundAddress
  | _ => false
/-- Hypothesis under #741, not accepted law; quantify every actual consuming action. -/
def registrationEffects (h : Hash) (c : Codec) (decode : DecodeApplication)
    (o : ApplicationObservation) : Bool :=
  o.actions.all fun action => match action.inputReference with
  | none => true
  | some ref => match o.inputs.find? (fun input => input.reference == ref) with
    | none => true
    | some input => match decoded decode input with
      | some (.registration r) => registrationEffect h c o action input r
      | _ => true
/-- Hypothesis under #741, not accepted law; burn the exact held registry/key asset. -/
def terminationEffects (h : Hash) (c : Codec) (o : ApplicationObservation) : Bool :=
  o.actions.all fun action => match action with
  | .terminationFold _ registry key => NoPin.mintQty o.assets (activeAsset h c registry key) == -1
  | _ => true
/-- Hypothesis under #741, not accepted law; controller authority and public clock record. -/
def bookingEffects (h : Hash) (c : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (o : ApplicationObservation) : Bool :=
  o.actions.all fun action => match action with
  | .bookRegistration index => match o.outputs[index]? with
    | some output => match decoded decode output with
      | some (.registration r) => o.signers.contains r.controller &&
          o.referenceOutputs.any (fun config =>
            config.credential == release.applicationCredential &&
            exactAssets config [(configurationAsset h c release r.registry, 1)] &&
            o.referenceInputs.contains config.reference && match config.datum with
            | .configuration p => o.interval.lower < o.interval.upper && r.bookedAt == o.interval.upper &&
                o.interval.upper - o.interval.lower ≤ p.bookingWidth &&
                r.processDeadline == r.bookedAt + p.processTime && r.reclaimEnd == r.processDeadline + p.retractTime
            | _ => false)
      | _ => false
    | none => false
  | .bookTermination ref _ => match o.inputs.find? (fun input => input.reference == ref) with
    | some input => match decoded decode input with
      | some (.live control _) => o.signers.contains control.controller
      | _ => false
    | none => false
  | _ => true
/-- Hypothesis under #741, not accepted law; independent additive treasury target. -/
def treasuryEffect (decode : DecodeApplication) (o : ApplicationObservation) : Bool :=
  o.donation == (o.actions.filterMap fun action => match action with
    | .bookTermination ref _ => do
      let input ← o.inputs.find? (fun input => input.reference == ref)
      let .live control _ ← decoded decode input | none
      return control.deposit
    | _ => none).sum
/-- Hypothesis under #741, not accepted law; independent aggregate refund and delivery floors. -/
def paymentEffects (decode : DecodeApplication) (o : ApplicationObservation) : Bool :=
  let debts := o.actions.filterMap fun action => do
    let ref ← action.inputReference
    let input ← o.inputs.find? (fun input => input.reference == ref)
    let .registration r ← decoded decode input | none
    match action with
    | .registrationFold .. => return (r.holdingAddress, r.deposit)
    | .ownerReclaim .. => return (r.refundAddress, input.lovelace)
    | .expiredCleanup .. => return (r.refundAddress, r.deposit)
    | _ => none
  debts.all fun debt =>
    ((debts.filter fun other => other.1 == debt.1).map (·.2)).sum ≤
      ((o.outputs.filter fun out => out.credential == debt.1).map (·.lovelace)).sum
/-- Hypothesis under #741, not accepted law; three literal disjoint interval predicates. -/
def phasesDisjoint (r : RegistrationData) (i : Interval) : Prop :=
  ¬ (i.lower < i.upper ∧ i.upper ≤ r.processDeadline ∧ r.processDeadline ≤ i.lower) ∧
  ¬ (i.lower < i.upper ∧ i.upper ≤ r.reclaimEnd ∧ r.reclaimEnd ≤ i.lower)
/-- Hypothesis under #741, not accepted law; no alternative action spends a genuine pending source. -/
def folderProtection (h : Hash) (c : Codec) (decode : DecodeApplication)
    (release : PublishedRelease) (o : ApplicationObservation) : Bool :=
  o.actions.all fun action => match action.inputReference with
  | none => true
  | some ref => match o.inputs.find? (fun input => input.reference == ref) with
    | none => true
    | some input => match decoded decode input with
      | some (.registration r) =>
          if o.interval.upper ≤ r.processDeadline then
            match action with | .registrationFold .. => true | _ => false
          else true
      | _ =>
          if input.datum == .empty && input.credential == release.applicationCredential then
            match action with
            | .terminationFold _ registry key => quantity input (activeAsset h c registry key) == 1 &&
                NoPin.mintQty o.assets (activeAsset h c registry key) == -1
            | _ => false
          else true
/-- Hypothesis under #741, not accepted law; empty-datum singleton, fee funding and public authenticity.
The top-up design is HELD: this conditional availability does not assert a wallet or inclusion. -/
def TerminationPremises (h : Hash) (c : Codec) (t : TrieCommit) (q : Input) : Prop :=
  PublicFoldPremises h c t (queryDecode q.query) q.query.release q.query.observation.before
    q.query.requests q.query.funding ∧
  q.query.release.applicationPolicy ≠ q.query.release.statePolicy ∧
  q.query.release.applicationCredential ≠ q.query.release.statePolicy ∧
  FiniteEncoding c (publicDomain q.query) ∧ FiniteCollisionFree h c (publicDomain q.query) ∧
  ∃ output registry key, q.query.requests = [.termination output registry key]
/-- Hypothesis under #741, not accepted law; a concrete public transaction is accepted by both layers. -/
abbrev terminationAvailable (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit) (q : Input) : Prop :=
  let built := buildFold h c t q.query.release q.query.observation.before q.query.requests q.query.funding
  fold .none h c t q.query.release built = true ∧
  applicationStep m h c (queryDecode q.query) q.query.release (applicationFoldView built q.query.requests) = true ∧
  built.signers = [] ∧ observedBalance built.spentOutputs built.outputs built.fee built.donation = true
/-- Hypothesis under #741, not accepted law; one named surface per query. -/
def run (surface : Surface) (m : AppMutation) (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (release : PublishedRelease) (q : Input) : Bool :=
  match surface with
  | .action => applicationAction m h c decode release q.observation q.action
  | .step => applicationStep m h c decode release q.observation
  | .publicTermination =>
    let built := buildFold h c t release q.query.observation.before q.query.requests q.query.funding
    fold .none h c t release built && applicationStep m h c decode release (applicationFoldView built q.query.requests)
/-- Hypothesis under #741, not accepted law; finite oracle interpretation is validated upstream. -/
def runScenario (s : Scenario) : Except String Bool :=
  if wellFormed s.input.query then .ok (run s.surface s.mutation (NoPin.lookupHash s.input.query.hashes)
    (queryCode s.input.query) (queryCommit s.input.query) (queryDecode s.input.query)
    s.input.query.release s.input)
  else .error "incomplete-public-interpretation"

end NoPin.ApplicationRequests.Lifecycle
