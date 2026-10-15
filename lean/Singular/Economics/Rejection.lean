import Singular.Economics.Observation

/-! A rejection reads one authenticated state output and consumes its members
atomically. This judgement never calls the historical fold/rejection exit. -/

namespace Singular

structure Rejection where
  transaction : EconomicTransaction
  stateReference : OutRef
  members : List (OutRef × RejectReason)
  deriving BEq, DecidableEq

/-- Logical authenticated read against the current trie, not Merkle proof
bytes. A concrete ledger consumer must implement that authentication. -/
def registrationRejectionGround (world : World) (r : RegistrationRequest)
    (interval : Interval) (ground : RejectReason) : Option String :=
  match ground with
  | .mismatch leaf =>
    if leaf != trieGet world.registry.trie r.key then some "reject-evidence-mismatch"
    else if (transition .insertActive leaf).isSome then some "reject-compatible"
    else none
  | .expired =>
    if interval.lower < r.submittedAt + world.registry.config.processTime +
        world.registry.config.retractTime then some "reject-not-expired"
    else none

/-- Termination mismatch uses the update edge and the current leaf. Reachable
carried supply proves that leaf active; expiry has no termination rule. -/
def terminationRejectionGround (world : World) (r : TerminationRequest)
    (ground : RejectReason) : Option String :=
  match ground with
  | .mismatch leaf =>
    if leaf != trieGet world.registry.trie r.key then some "reject-evidence-mismatch"
    else if (transition .updateTerminal leaf).isSome then some "reject-compatible"
    else none
  | .expired => some "reject-termination-no-expiry"

def rejectionMemberRefusal (world : World) (interval : Interval)
    (member : OutRef × RejectReason) : Option String :=
  match world.pending.find? (fun b => b.request.reference == member.1) with
  | some b => registrationRejectionGround world b.request interval member.2
  | none =>
    match world.terminations.find? (fun b => b.request.reference == member.1) with
    | some b =>
      match terminationRejectionGround world b.request member.2 with
      | some why => some why
      | none => some "reject-termination"
    | none => some "reject-request-not-pending"

def rejectionStateRefusal (world : World) (u : EconomicUtxo) (r : Rejection) : Option String :=
  if !inputsContainReference r.transaction.transaction.referenceInputs r.stateReference then
    some "reject-state-reference-missing"
  else match economicLookup u r.stateReference with
  | none => some "reference-input-missing"
  | some o =>
    if o.output.stateTokens != 1 || o.output.role != .state then some "reject-state-token-missing"
    else match o.output.stateToken with
    | none => some "reject-state-token-missing"
    | some token =>
      if token.policy != world.registry.config.stateToken.policy then some "reject-foreign-state"
      else if token.name != world.registry.config.stateToken.name then some "reject-state-token-name"
      else if o.output.datum != .inline then some "reject-state-datum"
      else match o.output.config with
      | none => some "reject-state-datum"
      | some config =>
        if config.root != rootOf world.registry.trie then some "reject-stale-state"
        else if config != world.registry.config then some "reject-state-configuration"
        else none

/-- Reject every spent state output, regardless of the input's claimed role
or token. An overlap receives its own reason before the general state spend. -/
def rejectionInputsRefusal (u : EconomicUtxo) (r : Rejection) : Option String :=
  let tx := r.transaction.transaction
  if inputsContainReference tx.inputs r.stateReference &&
      inputsContainReference tx.referenceInputs r.stateReference then some "reject-state-overlap"
  else if (spentOutputs u.ledger tx).any (fun o => o.stateTokens > 0 || o.role == .state) then
    some "reject-state-spent"
  else if ¬ (tx.inputs.map (·.ref)).Nodup ∨ ¬ (r.members.map Prod.fst).Nodup then
    some "reject-duplicate-input"
  else if !disjointInputs tx then some "reject-input-overlap"
  else inputPresenceRefusal u.ledger tx

/-- The observed mint and outputs cannot introduce registry state or singular
tokens. Only registration request inputs can survive member admission. -/
def rejectionSupplyUnchanged (u : EconomicUtxo) (tx : EconomicTransaction) : Bool :=
  tx.transaction.mint.isEmpty && tx.stateMint.isEmpty && tx.singularMint.isEmpty &&
    (economicSpent u tx).all (fun o => o.output.stateTokens == 0 &&
      o.output.assets.isEmpty && o.singularTags.isEmpty && o.contents.otherAssets.isEmpty) &&
    tx.outputs.all (fun o => o.output.stateTokens == 0 && o.output.assets.isEmpty &&
      o.singularTags.isEmpty && o.contents.otherAssets.isEmpty)

def rejectionRefusal (world : World) (u : EconomicUtxo) (r : Rejection) : Option String := do
  if let some why := rejectionInputsRefusal u r then return why
  if let some why := rejectionStateRefusal world u r then return why
  if let some why := economicObservationRefusal world u r.transaction then return why
  let some interval := r.transaction.transaction.validity | return "reject-interval-missing"
  if ¬ interval.valid then return "reject-interval-empty"
  if r.members.isEmpty then return "reject-empty-batch"
  if ¬ (r.transaction.transaction.inputs.map (·.ref)).Perm
      (r.members.map fun m => some m.1) then return "reject-input-members"
  if let some why := r.members.findSome? (rejectionMemberRefusal world interval) then return why
  if !requestTagsBurned u r.transaction then return "reject-tag-not-burned"
  if !rejectionSupplyUnchanged u r.transaction then return "reject-registry-supply"
  none

def rejectionEffect (world : World) (r : Rejection) : World :=
  { world with pending := world.pending.filter fun b =>
      !(r.members.any fun m => m.1 == b.request.reference) }

/-- A refused batch yields no intermediate world. Accepted batches remove
their pending registrations once; the ledger update is applyEconomicTransaction.
Refund floors, fees and ledger balance are deliberately separate obligations. -/
def rejectionAccepted (world : World) (u : EconomicUtxo) (r : Rejection) : Except String World :=
  match rejectionRefusal world u r with
  | some why => .error why
  | none => .ok (rejectionEffect world r)

theorem rejectionAccepted_effect {world after : World} {u : EconomicUtxo} {r : Rejection}
    (accepted : rejectionAccepted world u r = .ok after) : after = rejectionEffect world r := by
  unfold rejectionAccepted at accepted
  split at accepted
  · contradiction
  · cases accepted; rfl

end Singular
