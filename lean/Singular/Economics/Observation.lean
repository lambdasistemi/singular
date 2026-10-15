import Singular.Economics.Transaction
import Singular.Economics.WorldState

/-! Economic observations beside the historical fold transaction. Every value
and datum below is read from an output, never from a spending input's claims.
These observations do not assert ledger balance or execute a tag policy. -/

namespace Singular

inductive EconomicRequest where
  | registration (request : RegistrationRequest)
  | termination (request : TerminationRequest)
  deriving BEq, DecidableEq

structure EconomicOutput where
  output : TxOutput
  contents : BookingContents
  singularTags : List SingularTag := []
  request : Option EconomicRequest := none
  deriving BEq, DecidableEq

abbrev EconomicUtxo := List (OutRef × EconomicOutput)

/-- Mint entries are signed quantities, not a declaration that burning passed.
Outputs have one observation each, in the same order as the historical Tx.
The identity is the ledger-allocated fresh transaction identity. -/
structure EconomicTransaction where
  transaction : Tx
  identity : Nat
  outputs : List EconomicOutput
  trieReadyMint : List (TokenId × Int)
  applicationMint : List (TokenId × Int)
  stateMint : List (TokenId × Int) := []
  singularMint : List (SingularTag × Int) := []
  deriving BEq, DecidableEq

def EconomicUtxo.ledger (u : EconomicUtxo) : Utxo :=
  u.map fun (ref, observed) => (ref, observed.output)

def economicLookup (u : EconomicUtxo) (ref : OutRef) : Option EconomicOutput :=
  (u.find? fun entry => entry.1 == ref).map Prod.snd

def economicSpent (u : EconomicUtxo) (tx : EconomicTransaction) : List EconomicOutput :=
  (u.filter fun p => inputsContainReference tx.transaction.inputs p.1).map Prod.snd

def applyEconomicTransaction (u : EconomicUtxo) (tx : EconomicTransaction) : EconomicUtxo :=
  u.filter (fun p => !inputsContainReference tx.transaction.inputs p.1) ++
    tx.outputs.zipIdx.map (fun (output, index) => (⟨tx.identity, index⟩, output))

/-- Read the complete request datum and contents, including its value, from
the unspent output. A pending record alone cannot authenticate a claimed input. -/
def observesRegistration (u : EconomicUtxo) (r : RegistrationRequest) : Bool :=
  match economicLookup u r.reference with
  | none => false
  | some o => decide (o.request = some (.registration r) ∧ o.contents = r.contents ∧
      o.singularTags = [] ∧ o.output.role = .request ∧ o.output.datum = .inline ∧
      o.output.lovelace = r.contents.lovelace ∧ o.output.stateTokens = 0 ∧
      o.output.assets = [])

def observesTermination (u : EconomicUtxo) (r : TerminationRequest) : Bool :=
  match economicLookup u r.reference with
  | none => false
  | some o => decide (o.request = some (.termination r) ∧ o.contents = r.contents ∧
      o.singularTags = r.singularTags ∧ o.output.role = .request ∧
      o.output.datum = .inline ∧ o.output.lovelace = r.contents.lovelace ∧
      o.output.stateTokens = 0 ∧ o.output.assets = [])

/-- Consistency is checked for all pending outputs, also when sweeping. This
prevents a false tag-free observation at a pending reference bypassing its exit. -/
def observesWorld (world : World) (u : EconomicUtxo) : Bool :=
  world.pending.all (fun b => observesRegistration u b.request) &&
    world.terminations.all (fun b => observesTermination u b.request)

def economicObservationRefusal (world : World) (u : EconomicUtxo)
    (tx : EconomicTransaction) : Option String :=
  if ¬ (u.map Prod.fst).Nodup then some "unspent-reference-duplicate"
  else if !(u.all fun p => p.1.tx != tx.identity) then some "transaction-identity-not-fresh"
  else if !observesWorld world u then some "request-observation-mismatch"
  else if tx.outputs.map (·.output) != tx.transaction.outputs ||
      !(tx.outputs.all fun o => o.output.lovelace == o.contents.lovelace) then
    some "output-observation-mismatch"
  else none

/-- Quantity equality on the union of supports counts collisions and repeated
entries. It assumes no injectivity of either computed tag name. -/
def exactBurns {α : Type} [DecidableEq α] (held : List α) (mint : List (α × Int)) : Bool :=
  (held ++ mint.map Prod.fst).all fun tag =>
    decide (((mint.filter fun p => decide (p.1 = tag)).map Prod.snd).sum =
      -(Int.ofNat (held.count tag)))

/-- Authorization evidence belongs to the observed request. Mint accounting
uses only the asset's policy and name, including when two tuples share a name. -/
def applicationTagIdentity (tag : Approval) : TokenId := ⟨tag.policy, tag.assetName⟩

def requestTagsBurned (u : EconomicUtxo) (tx : EconomicTransaction) : Bool :=
  let spent := economicSpent u tx
  exactBurns (spent.flatMap (·.contents.trieReadyTags)) tx.trieReadyMint &&
    exactBurns ((spent.flatMap (·.contents.applicationTags)).map applicationTagIdentity)
      tx.applicationMint &&
    tx.outputs.all (fun o => o.contents.trieReadyTags.isEmpty && o.contents.applicationTags.isEmpty)

end Singular
