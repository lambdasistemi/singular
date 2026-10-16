import CardanoLedger
import Singular.Model.Admission

/-! Registry policies, their binding and the explicit state-script agreement. -/

namespace Singular.LedgerBoundary
open CardanoLedger

inductive RegistryScript where
  | state
  | witness (kind : TokenKind) (registry : AssetClass)
  | other (code : Nat)
  deriving BEq, DecidableEq

inductive RegistryRedeemer where
  | fold
  | other (code : Nat)
  deriving BEq, DecidableEq

inductive RegistryDatum where
  | state (value : RegistryState)
  | other (code : Nat)
  deriving BEq, DecidableEq

abbrev RegistryTx := CardanoLedger.Tx RegistryDatum RegistryRedeemer RegistryScript
abbrev RegistryContext := ScriptContext RegistryDatum RegistryRedeemer RegistryScript

structure RegistryWorld where
  hash : RegistryScript → ScriptHash
  stateRule : RegistryContext → Bool
  otherRule : Nat → RegistryContext → Bool
  accepts : RegistryTx → Prop

def RegistryWorld.policyId (world : RegistryWorld) (kind : TokenKind)
    (registry : AssetClass) : PolicyId := world.hash (.witness kind registry)

def foldPresent (world : RegistryWorld) (registry : AssetClass) (tx : RegistryTx) : Bool :=
  tx.inputs.any fun input =>
    input.resolved.address.payment == .script (world.hash .state) &&
    input.resolved.value.assets.quantity registry == 1 &&
    tx.redeemerOf (.spend input.reference) == some .fold

def witnessDecision (world : RegistryWorld) (kind : TokenKind)
    (registry : AssetClass) (ctx : RegistryContext) : Bool :=
  match kind with
  | .active | .absent => foldPresent world registry ctx.tx
  | .terminal => ctx.tx.mint.onlyBurns (world.policyId kind registry) ||
      foldPresent world registry ctx.tx

def RegistryWorld.ledger (world : RegistryWorld) :
    Ledger RegistryDatum RegistryRedeemer RegistryScript where
  hash := world.hash
  evaluate := fun script ctx => match script with
    | .state => world.stateRule ctx
    | .witness kind registry => witnessDecision world kind registry ctx
    | .other code => world.otherRule code ctx
  accepts := world.accepts

structure Pins where
  absent : PolicyId
  active : PolicyId
  terminal : PolicyId
  deriving BEq, DecidableEq

def Pins.policy (pins : Pins) : TokenKind → PolicyId
  | .absent => pins.absent
  | .active => pins.active
  | .terminal => pins.terminal

def Bound (world : RegistryWorld) (pins : Pins) (registry : AssetClass) : Prop :=
  ∀ kind, pins.policy kind = world.policyId kind registry

def ScriptsOccur (_world : RegistryWorld) (registry : AssetClass) (tx : RegistryTx)
    (script : RegistryScript) : Prop :=
  script ∈ tx.scripts ∨ script = .state ∨ ∃ kind, script = .witness kind registry

/-- Remove the first matching terminal holding, leaving duplicate attestations
and all nonmatching holdings alone. A discard is not a registry fold. -/
def discardTerminal (state : RegistryState) (key : Key) (output : Nat) : RegistryState :=
  { state with held := state.held.eraseP fun holding =>
      holding.key == key && holding.kind == .terminal && holding.output == output }

end Singular.LedgerBoundary
