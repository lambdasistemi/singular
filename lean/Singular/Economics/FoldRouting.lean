import Singular.Economics.FoldProjection

/-! Output categories follow actual token holdings, not addresses or roles.
Carriers and ordinary change are separate even at a shared address. -/

namespace Singular

def foldOrdinary (output : EconomicOutput) : Bool :=
  output.output.stateTokens == 0 && output.contents.trieReadyTags.isEmpty &&
    output.contents.applicationTags.isEmpty && output.singularTags.isEmpty

def foldOrdinaryLovelace (outputs : List EconomicOutput) : Nat :=
  ((outputs.filter foldOrdinary).map (·.output.lovelace)).sum

def foldBareValue (output : EconomicOutput) : Bool :=
  output.output.assets.isEmpty && output.contents.otherAssets.isEmpty

def foldStateShape (c : Config) (output : EconomicOutput) : Bool :=
  decide (output.output.stateTokens = 1 ∧ output.output.stateToken = some c.stateToken ∧
    output.output.datum = .inline ∧ output.output.config = some c ∧
    output.request = none ∧ output.singularTags = [] ∧
    output.contents.trieReadyTags = [] ∧ output.contents.applicationTags = []) &&
    foldBareValue output

/-- Compare quantities on the complete support, including repeated identities
and commitment collisions. No injectivity assumption is used. -/
def foldSameQuantities {α : Type} [DecidableEq α]
    (left right : List (α × Int)) : Bool :=
  (left.map Prod.fst ++ right.map Prod.fst).all fun tag =>
    decide (((left.filter fun p => decide (p.1 = tag)).map Prod.snd).sum =
      ((right.filter fun p => decide (p.1 = tag)).map Prod.snd).sum)

def foldMint (c : Config) (members : List FoldMember) : List (SingularTag × Int) :=
  members.flatMap fun member => match member with
    | .registration b => [(c.singularTag b.request.key, 1)]
    | .termination b => b.request.singularTags.map (fun tag => (tag, -1))

def foldCarrierTags (c : Config) (members : List FoldMember) : List SingularTag :=
  members.filterMap fun member => match member with
    | .registration b => some (c.singularTag b.request.key)
    | .termination _ => none

def foldCarrierRefusal (c : Config) (outputs : List EconomicOutput)
    (member : FoldMember) : Option String := do
  match member with
  | .termination _ => none
  | .registration b =>
    let r := b.request
    let [output] := outputs.filter (fun o => o.singularTags.contains (c.singularTag r.key))
      | return "fold-destination-mismatch"
    if output.output.address != some r.destination || output.output.datumValue != r.datum ||
        output.output.datum != datumFormOf r.datum then return "fold-destination-mismatch"
    if output.output.lovelace != r.carrierAda then return "destination-carrier-mismatch"
    if !decide (output.singularTags = [c.singularTag r.key] ∧ output.output.stateTokens = 0 ∧
        output.request = none ∧ output.contents.trieReadyTags = [] ∧
        output.contents.applicationTags = []) || !foldBareValue output then
      return "fold-destination-mismatch"
    none

def foldRoutingRefusal (world : World) (u : EconomicUtxo) (tx : EconomicTransaction)
    (result : Result) : Option String := do
  let spent := economicSpent u tx
  let [state] := spent.filter (fun o => o.output.stateTokens > 0) | return "fold-state-missing"
  if !foldStateShape world.registry.config state ||
      world.registry.config.root != rootOf world.registry.trie then return "fold-state-mismatch"
  let [continued] := tx.outputs.filter (fun o => o.output.stateTokens > 0)
    | return "fold-state-mismatch"
  if !foldStateShape result.state.config continued then return "fold-state-mismatch"
  if continued.output.lovelace != state.output.lovelace then return "fold-state-value-mismatch"
  let members := foldMembers world tx
  if !requestTagsBurned u tx then return "fold-tag-not-burned"
  if let some why := members.findSome? (foldCarrierRefusal world.registry.config tx.outputs) then return why
  if !foldSameQuantities tx.singularMint (foldMint world.registry.config members) ||
      !decide ((tx.outputs.flatMap (·.singularTags)).Perm (foldCarrierTags world.registry.config members)) then
    return "fold-singular-mismatch"
  if !tx.stateMint.isEmpty || !tx.transaction.mint.isEmpty ||
      !(tx.outputs.all foldBareValue) || !(spent.all foldBareValue) then return "fold-foreign-asset"
  if tx.transaction.donation != (foldObligations members).donation then return "fold-donation-mismatch"
  if foldOrdinaryLovelace spent < tx.transaction.fee then return "fold-fee-funding-short"
  if !balanced u.ledger tx.transaction then return "fold-unbalanced"
  none

end Singular
