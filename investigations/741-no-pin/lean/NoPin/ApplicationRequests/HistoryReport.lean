import NoPin.ApplicationRequests.HistoryEvidence
import NoPin.ApplicationRequests.HistoryBindings
import NoPin.ApplicationRequests.Evidence

/-! Compiled hypothetical history inventory, not accepted law. -/
namespace NoPin.ApplicationRequests.HistoryReport
open Lean Elab Command Term Meta

private partial def certifyOrigin (goal : Expr) (fields : List Expr) : TermElabM Expr := do
  match fields with
  | [] =>
    let args := (← whnf goal).getAppArgs
    let proof ← mkEqRefl args.back!
    unless ← isDefEq (← inferType proof) goal do throwError "wrong source endpoint"
    return proof
  | field :: rest =>
    let reduced ← whnf goal
    let .app (.app (.const ``Exists [level]) domain) predicate := reduced
      | throwError "source premise omitted from inversion"
    let child ← certifyOrigin (predicate.beta #[field]) rest
    return mkAppN (Lean.mkConst ``Exists.intro [level]) #[domain, predicate, field, child]

elab "#history_report" : command => do
  let env ← getEnv
  let .inductInfo history ← getConstInfo ``CandidateReachable | throwError "history is not inductive"
  for constructor in history.ctors do
    let name := Name.str `NoPin.ApplicationRequests.HistoryOrigins constructor.getString!
    let source ← getConstInfo constructor
    let inversion ← getConstInfo name
    let stem := match constructor.getString! with
      | "initial" => "initial_reachable" | "genesis" => "second_genesis_reachable"
      | "fold" => "registered_first_reachable" | "neutral" => "booked_reachable"
      | _ => ""
    unless stem != "" do throwError "unwitnessed history constructor: {constructor}"
    let certificateName := Name.str `NoPin.ApplicationRequests.HistoryEvidence ("origin_" ++ constructor.getString!)
    liftTermElabM do
      let witness ← getConstInfo (Name.str `NoPin.ApplicationRequests.HistoryEvidence stem)
      let value := witness.value!.consumeMData
      unless value.getAppFn.constName! == constructor do throwError "wrong constructor witness"
      let goal := mkAppN (Lean.mkConst name) witness.type.getAppArgs
      let certificate ← certifyOrigin goal (value.getAppArgs.toList.drop history.numParams)
      unless ← isDefEq (← inferType certificate) goal do throwError "wrong inversion certificate"
      if !(← getEnv).contains certificateName then
        addDecl (.thmDecl {name := certificateName, levelParams := [], type := goal, value := certificate})
      else
        unless ← isDefEq (← getConstInfo certificateName).type goal do throwError "stale inversion certificate"
    IO.println (Json.mkObj [
      ("family", toJson "history"), ("constructor", toJson constructor.toString),
      ("sourceType", toJson (reprStr source.type)), ("inversion", toJson name.toString),
      ("certificate", toJson certificateName.toString),
      ("inversionType", toJson (reprStr inversion.type)),
      ("inversionValue", toJson (reprStr inversion.value!))]).compress
  IO.println (Json.mkObj [("family", toJson "history"),
    ("constructors", toJson (history.ctors.map toString))]).compress
  for (name, info) in (← getEnv).constants.toList do
    if name.getPrefix == `NoPin.ApplicationRequests.HistoryStatements ||
        (name.toString.startsWith "NoPin.ApplicationRequests.HistoryEvidence." &&
          match info with | .thmInfo _ => true | _ => false) then
      if name.getPrefix == `NoPin.ApplicationRequests.HistoryStatements then
        let stem := match name.getString! with
          | "supply_in_step" => "supply" | "one_live_token" => "one_live"
          | "burn_only_terminating_fold" => "burn" | "no_remint_after_terminal" => "permanence"
          | _ => ""
        unless stem != "" do throwError "unbound history statement: {name}"
        liftTermElabM do
          let witnessName := Name.str `NoPin.ApplicationRequests.HistoryEvidence (stem ++ "_antecedent")
          let claimName := Name.str `NoPin.ApplicationRequests.HistoryEvidence (stem ++ "_claim")
          let positiveName := Name.str `NoPin.ApplicationRequests.HistoryEvidence (stem ++ "_candidate")
          let (parameters, _, body) ← forallMetaTelescope info.type
          let proof := parameters.back!
          let witness := Lean.mkConst witnessName
          unless ← isDefEq (← inferType proof) (← inferType witness) do
            throwError "incomplete history antecedent: {name}"
          proof.mvarId!.assign witness
          unless ← isDefEq body (Lean.mkConst claimName) do throwError "wrong history consequence: {name}"
          unless ← isDefEq (← inferType (Lean.mkConst positiveName)) (Lean.mkConst claimName) do
            throwError "wrong history positive: {name}"
          IO.println (Json.mkObj [("family", toJson "history"), ("binding", toJson name.toString),
            ("witness", toJson witnessName.toString), ("claim", toJson claimName.toString),
            ("positive", toJson positiveName.toString)]).compress
      IO.println (Json.mkObj [("family", toJson "history"), ("name", toJson name.toString),
        ("type", toJson (reprStr info.type)),
        ("axioms", toJson ((← collectAxioms name).toList.map toString)),
        ("doc", toJson ((← findDocString? env name).getD ""))]).compress

end NoPin.ApplicationRequests.HistoryReport

#history_report

namespace NoPin.ApplicationRequests.HistoryReport
open Singular Lean Fixtures HistoryEvidence

/-- Hypothetical history replay input for the existing generic fold surface. -/
def replayQuery (release : PublishedRelease) (o : FoldObservation) : Query :=
  let action := o.changes.head?.getD (.terminate ⟨0, 0⟩ 0)
  let preimages := ([Preimage.state o.before.seed] ++ o.changes.flatMap (changePreimages o) ++
    changePreimages o action).eraseDups
  let codes := preimages.map fun preimage => CodeEntry.mk preimage (code preimage)
  { Evidence.goodQuery .batch with
    release := release
    seed := o.before.seed
    output := o.before.state
    transaction := o.assets
    outputs := o.outputs
    observation := o
    trie := o.before.trie
    action := action
    requests := []
    codes := codes
    hashes := codes.map fun entry => ⟨entry.encoded, hash entry.encoded⟩
    roots := [[], o.before.trie, o.after.trie].eraseDups.map fun trie => ⟨trie, commit trie⟩ }

/-- Hypothetical complete physical world export; no proof fields are serialized. -/
def worldJson (world : CandidateWorld) : Json := Json.mkObj [
  ("registries", toJson world.registries), ("unspent", toJson world.unspent),
  ("spentReferences", toJson world.spentReferences), ("domain", toJson world.domain)]

/-- Hypothetical public definition replay; the separate kernel certificates
establish history premises. The oracle itself never claims ledger validity. -/
def reportCorpus : IO Unit := do
  let firstGenesis := { replayQuery release registerFirst with
    surface := .genesis, transaction := genesisTx, outputs := [first.state, other.state] }
  let otherGenesis := { replayQuery otherRelease registerOther with
    surface := .genesis, transaction := genesisTx, outputs := [first.state, other.state] }
  let secondObservation := { registerFirst with before := second, after := second, changes := [] }
  let secondGenesis := { replayQuery release secondObservation with
    surface := .genesis, transaction := secondGenesisTx, outputs := [second.state] }
  let queries := [("same-seed-first-policy", firstGenesis), ("same-seed-second-policy", otherGenesis),
    ("later-registry-genesis", secondGenesis), ("first-registrations", replayQuery release registerFirst),
    ("other-application-registration", replayQuery otherRelease registerOther),
    ("pending-termination-fold", replayQuery release terminate), ("later-fold-after-terminal", replayQuery release later)]
  for (label, query) in queries do
    let .ok result := runQuery .none query | throw (IO.userError "incomplete history replay observations")
    unless result do throw (IO.userError ("history replay refused: " ++ label))
    IO.println (Json.mkObj [("family", toJson "history"), ("label", toJson label),
      ("scenario", toJson (Scenario.mk query .none)), ("result", toJson result)]).compress
  IO.println (Json.mkObj [("family", toJson "history"),
    ("history", toJson ([initial, genesisWorld, secondGenesisWorld, registeredFirst,
      registeredBoth, booked, terminated, laterWorld].map worldJson)),
    ("otherProjection", toJson ([initial, otherGenesisWorld, otherSecondGenesisWorld,
      otherRegisteredFirst, otherRegisteredBoth, otherBooked, otherTerminated, otherLaterWorld].map worldJson))]).compress

end NoPin.ApplicationRequests.HistoryReport

#eval NoPin.ApplicationRequests.HistoryReport.reportCorpus
