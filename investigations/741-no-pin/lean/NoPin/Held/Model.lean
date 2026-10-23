import NoPin.Identity
import Singular.Statements.FoldTermination
import Singular.Statements.Preservation

/-! Hypotheses for #741, not accepted law. The economic judgements are imported,
not replaced. Physical application address and logical custody are independent.
Cancellation, pending updates and the controller's combined payment remain unruled. -/

namespace NoPin.Held
open Singular Lean

/-- Hypothesis under #741, not accepted law; retained application control. -/
structure Control where
  registry : TokenId
  key : Key
  controller : Nat
  deposit : Nat
  deriving BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; origin is authenticated external evidence. -/
structure Holding where
  reference : OutRef
  family : Nat
  control : Control
  token : TokenId
  quantity : Nat
  provenance : TokenId
  rootHolding : Singular.Holding
  payload : Nat
  lovelace : Nat
  deriving BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; same-output request observation. -/
structure Pending where
  holding : Holding
  booking : TerminationBooking
  deriving BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; disjoint states even at one address. -/
inductive LockedOutput where
  | live (holding : Holding)
  | pending (termination : Pending)
  deriving BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; pure application-to-economic projection. -/
structure ApplicationState where
  registry : RegistryState
  registrations : RequestPool
  outputs : List LockedOutput
  treasury : Nat
  deriving BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; accepted wire constructors only. -/
inductive LiveSpend where
  | update | release
  deriving BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; actual output payment observation. -/
structure LocalPayment where
  index : Nat
  controller : Nat
  lovelace : Nat
  deriving BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; no state or request script address. -/
structure LocalTransaction where
  assets : TxView
  spent : List Pending
  payments : List LocalPayment
  deriving BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; accepted root observations, no second fold. -/
structure FoldObservation where
  before : World
  after : World
  unspent : EconomicUtxo
  transaction : EconomicTransaction
  deriving BEq, DecidableEq
/-- Hypothesis under #741, not accepted law; public function cases. -/
inductive Case where
  | liveUpdate | liveRelease | genuine | booking | rebooking
  | pendingRelease | projection | coupling | discovery | consumption | economicAvailability
  deriving BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; single atomic decision sites only. -/
inductive Guard where
  | liveUpdate | liveRelease | ownToken | quantity | provenance | rootKey | rootKind
  | pendingReference | pendingValue | pendingContents | pendingCustody
  | sourceMember | bookLive | bookSigner | bookFamily | bookControl | bookToken
  | bookPayload | bookReference | bookValue | bookDeposit | bookRoot | rebooking
  | releaseGenuine | releaseSpent | releaseOnce | releaseBurn | releasePayments
  | projectionLive | projectionPending | couplingObservation | couplingFold
  | couplingSelected | couplingTerminal | discoveryPending | consumptionReference
  | availabilityAccepted
  deriving BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; selectors are investigation controls. -/
inductive Mutation where
  | none | flip (guard : Guard)
  deriving BEq, DecidableEq, ToJson, FromJson
/-- Hypothesis under #741, not accepted law; one selected guard changes. -/
def guard (m : Mutation) (site : Guard) (value : Bool) : Bool :=
  if m == .flip site then !value else value
/-- Hypothesis under #741, not accepted law; extract physical held-token observation. -/
def holdingOf : LockedOutput → Holding
  | .live h => h
  | .pending p => p.holding
/-- Hypothesis under #741, not accepted law; address-independent category projection. -/
def projectWith (m : Mutation) (s : ApplicationState) : World :=
  { registry := { s.registry with held := s.outputs.filterMap fun o =>
      if guard m .projectionLive (match o with | .live _ => true | _ => false)
      then some (holdingOf o).rootHolding else none },
    pending := s.registrations,
    terminations := s.outputs.filterMap fun o => match o with
      | .pending p => if guard m .projectionPending true then some p.booking else none
      | .live _ => none,
    treasury := s.treasury }
/-- Hypothesis under #741, not accepted law; actual projection, no typed supply count. -/
def project (s : ApplicationState) : World := projectWith .none s
/-- Hypothesis under #741, not accepted law; classify the two accepted live spend paths. -/
def liveSpend (m : Mutation) (action : LiveSpend) (o : LockedOutput) : Bool :=
  guard m (match action with | .update => .liveUpdate | .release => .liveRelease)
    (match o with | .live _ => true | .pending _ => false)
/-- Hypothesis under #741, not accepted law; exact identity and supplied origin.
Root registry/asset correspondence is an external statement premise, not supplied by a datum. -/
def genuine (m : Mutation) (hash : Hash) (code : Codec) (c : Config) (o : LockedOutput) : Bool :=
  let h := holdingOf o
  guard m .ownToken (h.token == roleAsset hash code h.control.registry .witness h.control.key) &&
  guard m .quantity (h.quantity == 1) &&
  guard m .provenance (h.provenance == h.token) &&
  guard m .rootKey (h.rootHolding.key == h.control.key) &&
  guard m .rootKind (h.rootHolding.kind == .active) &&
  match o with
  | .live _ => true
  | .pending p =>
    guard m .pendingReference (h.reference == p.booking.request.reference) &&
    guard m .pendingValue (h.lovelace == p.booking.request.contents.lovelace) &&
    guard m .pendingContents (terminationExactContents c p.booking.request) &&
    guard m .pendingCustody (p.booking.custodyInputs == [h.rootHolding] &&
      p.booking.request.key == h.control.key)
/-- Hypothesis under #741, not accepted law; controller-only transition, exact root admission.
The root judgement supplies contents/tags; no local reimplementation of those guards. -/
def book (m : Mutation) (hash : Hash) (code : Codec) (s : ApplicationState)
    (source : LockedOutput) (p : Pending) (signers : List Nat) : Bool :=
  match source with
  | .pending _ => guard m .rebooking false
  | .live h =>
    guard m .sourceMember (s.outputs.contains source) &&
    guard m .bookLive (genuine .none hash code s.registry.config source) &&
    guard m .bookSigner (signers.contains h.control.controller) &&
    guard m .bookFamily (p.holding.family == h.family) &&
    guard m .bookControl (p.holding.control == h.control) &&
    guard m .bookToken (p.holding.token == h.token && p.holding.quantity == 1 &&
      p.holding.provenance == h.provenance && p.holding.rootHolding == h.rootHolding) &&
    guard m .bookPayload (p.holding.payload == h.payload) &&
    guard m .bookReference (p.holding.reference == p.booking.request.reference &&
      p.holding.reference != h.reference) &&
    guard m .bookValue (p.holding.lovelace == p.booking.request.contents.lovelace) &&
    guard m .bookDeposit (h.control.deposit <= p.holding.lovelace) &&
    guard m .bookRoot ((bookTermination (project s) p.booking).isOk)
/-- Hypothesis under #741, not accepted law; replace the selected live observation once. -/
def bookEffect (s : ApplicationState) (source : LockedOutput) (p : Pending) : ApplicationState :=
  { s with outputs := .pending p :: s.outputs.erase source }
/-- Hypothesis under #741, not accepted law; additive local deposits, not registryOwed. -/
def releasedTo (ps : List Pending) (family controller : Nat) : Nat :=
  ((ps.filter fun p => p.holding.family == family && p.holding.control.controller == controller)
    .map (·.holding.control.deposit)).sum
/-- Hypothesis under #741, not accepted law; each observed output counted once.
This supplies no equivalent of the registry's settlement eligibility or aggregate duties. -/
def localPayments (tx : LocalTransaction) (controller : Nat) : Nat :=
  ((tx.payments.filter fun p => p.controller == controller).map (·.lovelace)).sum
/-- Hypothesis under #741, not accepted law; local release only. No folder signer.
Duplicate payment indices refuse; correspondence to ledger outputs is still a premise. -/
def pendingRelease (m : Mutation) (hash : Hash) (code : Codec) (c : Config)
    (p : Pending) (tx : LocalTransaction) : Bool :=
  guard m .releaseGenuine (genuine .none hash code c (.pending p)) &&
  guard m .releaseSpent (tx.spent.contains p && tx.assets.spent.contains p.holding.reference) &&
  guard m .releaseOnce (decide (tx.assets.spent.Nodup ∧
    (tx.spent.map (·.holding.reference)).Nodup ∧ (tx.payments.map (·.index)).Nodup)) &&
  guard m .releaseBurn (mintQty tx.assets p.holding.token == -1) &&
  guard m .releasePayments (releasedTo tx.spent p.holding.family p.holding.control.controller <=
    localPayments tx p.holding.control.controller)
/-- Hypothesis under #741, not accepted law; per-key correspondence only.
Full value, script invocation and lineage correspondence remain upstream obligations. -/
def observationCorrespondence (registry : TokenId) (key : Key) (token : TokenId)
    (tx : TxView) (o : FoldObservation) : Prop :=
  tx.spent = o.transaction.transaction.inputs.filterMap (·.ref) ∧
  mintQty tx token = ((o.transaction.singularMint.filter fun entry =>
    decide (entry.1 = o.before.registry.config.singularTag key)).map (·.2)).sum ∧
  token.policy = registry.policy
/-- Hypothesis under #741, not accepted law; explicit policy-contract premise.
It is not established by the accepted witness policy's Modify co-presence test. -/
def couplingCheck (m : Mutation) (registry : TokenId) (key : Key) (token : TokenId)
    (tx : TxView) (o : FoldObservation) : Bool :=
  guard m .couplingObservation (decide (observationCorrespondence registry key token tx o)) &&
  guard m .couplingFold (foldAccepted o.before o.unspent o.transaction == .ok o.after) &&
  guard m .couplingSelected ((foldMembers o.before o.transaction).any fun member =>
    match member with | .termination b => b.request.key == key | _ => false) &&
  guard m .couplingTerminal (trieGet o.after.registry.trie key == .known .terminal)
/-- Hypothesis under #741, not accepted law; same-key terminal guarantee is assumed explicitly. -/
abbrev BurnCoupling (registry : TokenId) (key : Key) (token : TokenId)
    (tx : TxView) (o : FoldObservation) : Prop :=
  mintQty tx token = -1 → couplingCheck .none registry key token tx o = true
/-- Hypothesis under #741, not accepted law; complete public pending observations required. -/
def discoverWith (m : Mutation) (s : ApplicationState) : List Pending :=
  s.outputs.filterMap fun o => match o with
    | .pending p => if guard m .discoveryPending true then some p else none
    | .live _ => none
/-- Hypothesis under #741, not accepted law; no private booking input. -/
def discover (s : ApplicationState) : List Pending := discoverWith .none s
/-- Hypothesis under #741, not accepted law; only actually spent pending references leave.
The registry's terminal result comes separately from the accepted fold observation. -/
def consumeWith (m : Mutation) (s : ApplicationState) (tx : EconomicTransaction) : ApplicationState :=
  { s with outputs := s.outputs.filter fun o => match o with
      | .live _ => true
      | .pending p => !guard m .consumptionReference
          (inputsContainReference tx.transaction.inputs p.holding.reference) }
/-- Hypothesis under #741, not accepted law; pending filtering, no independent registry effect. -/
def consume (s : ApplicationState) (tx : EconomicTransaction) : ApplicationState := consumeWith .none s tx
/-- Hypothesis under #741, not accepted law; economic-only witness, excludes application release. -/
def economicAvailability (m : Mutation) (s : ApplicationState) (p : Pending)
    (time funding fee : Nat) : Bool :=
  let w := project s
  guard m .availabilityAccepted ((foldAccepted w (terminationWitnessUnspent w funding)
    (terminationWitnessTransaction w p.booking time funding fee)).isOk)

end NoPin.Held
