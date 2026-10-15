import Singular.Economics.Observation

/-! The economic requests use the registry's unchanged batch transition.
This projection restores custody only for that mathematical transition. -/

namespace Singular

/-- Pending records selected in spending-input order. The booking itself is
retained so the adapter cannot manufacture a pending economic request. -/
inductive FoldMember where
  | registration (booking : RegistrationBooking)
  | termination (booking : TerminationBooking)
  deriving BEq, DecidableEq

def foldMemberAt (world : World) (reference : OutRef) : Option FoldMember :=
  match world.pending.find? (fun b => b.request.reference == reference) with
  | some b => some (.registration b)
  | none => (world.terminations.find? (fun b => b.request.reference == reference)).map
      FoldMember.termination

def foldMembers (world : World) (tx : EconomicTransaction) : List FoldMember :=
  tx.transaction.inputs.filterMap fun input => input.ref.bind (foldMemberAt world)

def FoldMember.tip : FoldMember → Nat
  | .registration b => b.request.declaredTip
  | .termination b => b.request.declaredTip

def FoldMember.donation : FoldMember → Nat
  | .registration b => b.request.registrationCost
  | .termination b => b.request.contents.lovelace - b.request.declaredTip

def FoldMember.carrier : FoldMember → Nat
  | .registration b => b.request.carrierAda
  | .termination _ => 0

def FoldMember.held : FoldMember → Nat
  | .registration b => b.request.contents.lovelace
  | .termination b => b.request.contents.lovelace

/-- The old approval is syntactic input to the retained registry law only.
It has no authorization meaning. Economic admission authenticates a booked
application tag for registration and requires none for termination. -/
def foldLegacyRequest (c : Config) (member : FoldMember) : Request :=
  let (edge, key, owner, destination, datum, submittedAt) := match member with
    | .registration b => (.insertActive, b.request.key, b.request.refundAddress,
        b.request.destination, b.request.datum, b.request.submittedAt)
    | .termination b => (.updateTerminal, b.request.key, 0, b.request.destination, none, 0)
  let approval : Approval :=
    { policy := c.applicationPolicy, edge, key, owner, destination,
      assetName := approvalAssetName edge key owner destination }
  { edge, key, owner, output := destination, datum, submittedAt,
    registryId := c.registryId, claimed := delta edge, approval := some approval }

/-- Restore all pending custody holdings for the legacy registry calculation;
the economic world itself continues to keep those tokens in requests. -/
def foldProjectedRegistry (world : World) : RegistryState :=
  { world.registry with held := world.registry.held ++ world.terminations.flatMap (·.custodyInputs) }

def foldRemainingTerminations (world : World) (tx : EconomicTransaction) : List TerminationBooking :=
  world.terminations.filter fun b => !inputsContainReference tx.transaction.inputs b.request.reference

/-- Undo the custody projection for every termination not spent in this fold.
The result trie, root, configuration and other registry components are the
ones produced by the unchanged registry batch. -/
def foldRegistryEffect (world : World) (tx : EconomicTransaction) (result : Result) : RegistryState :=
  { result.state with held := result.state.held.filter fun holding =>
      !(holding.kind == .active && (foldRemainingTerminations world tx).any
        (fun b => b.request.key == holding.key)) }

structure FoldObligations where
  donation : Nat
  tips : Nat
  carriers : Nat
  deriving BEq, DecidableEq

def foldObligations (members : List FoldMember) : FoldObligations :=
  { donation := (members.map FoldMember.donation).sum,
    tips := (members.map FoldMember.tip).sum,
    carriers := (members.map FoldMember.carrier).sum }

end Singular
