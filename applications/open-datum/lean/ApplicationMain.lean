import OpenDatumApplication

/-! # The application driver executable

* `corpus` / `ledgers` print the generated corpus / ledgers;
* `run appStep` reads ONE scenario from standard input and prints its run;
* `write DIR` writes `DIR/corpus.json` and `DIR/ledgers.json`;
* `check DIR` fails unless:
  - the regenerated corpus and ledgers equal the committed files;
  - every committed scenario replays from its own JSON to its recorded run;
  - each check notices a controlled alteration: a changed recorded outcome is
    caught by replay and by the corpus comparison, and a dropped ledger row by
    the ledger comparison;
  - the ledger's proof status is the one the compiled statements establish
    (`OpenDatumApplication.Audit.compiledStatements`), and the reconciliation
    refuses each tampered report: a missing, extra, renamed or duplicated
    statement and a custom axiom; while a report of `sorryAx` for a row the
    ledger calls proved, a changed declaration header and a flipped status are
    each noticed by the ledger comparison;
  - each definition mutant of the law runs at least one scenario differently
    from the committed corpus;
  - every genesis and accepted step of every scenario observes the invariant,
    and every accepting constructor has a reached accepted step;
  - at the invariant boundary the ordinary reached world is consistent and the
    identical-duplicate world is not, its accepted update leaving two outputs
    of one key, while the observation without its occurrence clause would
    admit it.

Any parse failure, unknown mode or failed check exits non-zero. -/

open Lean
open OpenDatumApplication
open OpenDatumApplication.Driver
open Singular

def readStdin : IO String := do
  let stdin ← IO.getStdin
  let mut text := ""
  repeat
    let line ← stdin.getLine
    if line.isEmpty then break
    text := text ++ line
  pure text

def parseOrFail (what text : String) : IO Json :=
  match Json.parse text with
  | .ok j => pure j
  | .error e => throw (IO.userError s!"{what} is not JSON: {e}")

def orFail {α : Type} (what : String) : Except String α → IO α
  | .ok a => pure a
  | .error e => throw (IO.userError s!"{what}: {e}")

/-- Report one check and count it as failed unless it holds. -/
def report (ok : Bool) (line : String) : IO Nat := do
  let tag := if ok then "PASS" else "FAIL"
  IO.println s!"{tag} {line}"
  pure (if ok then 0 else 1)

/-- The ledger rows the compiled statements establish. -/
def compiledRows : IO (List StatementStatus) :=
  orFail "compiled statements" (reconcileStatements OpenDatumApplication.Audit.compiledStatements)

/-- Whether an attempted reconciliation is refused for the intended reason. -/
def refusedFor (reason : String) : Except String (List StatementStatus) → Bool
  | .error e => e.startsWith reason
  | .ok _ => false

/-- One ledger row's status replaced, as a hand edit of the committed file would. -/
def flipFirstStatus (ledgers : Json) : Json :=
  match ledgers.getObjVal? "theorems", ledgers.getObjVal? "atoms" with
  | .ok (.arr rows), .ok atoms =>
    let flipped := rows.modify 0 fun row => row.setObjVal! "status" (toJson "STATED")
    Json.mkObj [("theorems", Json.arr flipped), ("atoms", atoms)]
  | _, _ => Json.null

/-- The inserted envelope, observed: the request codec, the booking and
selection refusals, the registry holding and the root transaction a fold builds.
Every value is computed by the model or the root; none is typed. -/
def datumChecks : IO Nat := do
  let mut failed := 0
  let valid := insertRequest 5 (envelopeFor 5 payload0)
  let roundTrips := fun (r : Request) => (requestFromJson (requestToJson r)).toOption == some r
  failed := failed + (← report (roundTrips valid && roundTrips { valid with datum := none })
    "codec: a request carrying its datum and one carrying none each round-trip exactly")
  let unflagged := Json.mkObj [("edge", toJson Edge.insertActive), ("key", toJson (5 : Nat))]
  failed := failed + (← report
    ((requestFromJson unflagged).toOption.map (·.datum) == some none)
    "codec: a request that does not say carries no datum, the root default")
  let badFlag := Json.mkObj [("edge", toJson Edge.insertActive), ("key", toJson (5 : Nat))
    , ("datum", toJson "yes")]
  failed := failed + (← report (requestFromJson badFlag).toOption.isNone
    "codec: a datum that is not a value is refused")
  let g := genesis app0 cfg0 app0.registry
  let refusedNoDatum := match appStep g bookingNoDatum with
    | .error why => why == "app-envelope-datum"
    | .ok _ => false
  failed := failed + (← report (refusedNoDatum && (appStep g (bookInsertKey 5)).toOption.isSome)
    "booking: the valid insertion is accepted, and the same booking carrying no datum is refused app-envelope-datum")
  let selected := (appStep bookedWorld selectionFold).toOption.isSome
  let unselected := match appStep unnamedPendingWorld selectionFold with
    | .error why => why == "fold-envelope-datum"
    | .ok _ => false
  failed := failed + (← report (selected && unselected)
    "selection: the fold accepts the booked insertion, and refuses fold-envelope-datum when its pending request carries no datum")
  let envelope := some (envelopeHash (envelopeFor 5 payload0))
  let inlineHeld := ordinaryWorld.registry.held.any fun h =>
    h.key == 5 && h.kind == .active && h.datum == envelope
  failed := failed + (← report inlineHeld
    "delivery: after the insertion fold the registry holds key 5's active token with its envelope as its datum")
  let insertion? := bookedWorld.pending.head?.map (·.request)
  let destinations := match insertion? with
    | some r => match Singular.txOf bookedWorld.registry r (r.deposit + r.tip) with
      | .ok tx => (tx.outputs.filter (·.role == .destination)).map fun o => (o.datum, o.datumValue)
      | .error _ => []
    | none => []
  failed := failed + (← report (destinations == [(.inline, envelope)])
    "delivery: the transaction the root builds for that insertion has one destination output, carrying the envelope inline")
  let terminating := reachWorld (insertKey 5 ++ [.bookTerminate (terminateRequest 5) 0 [controller]])
  let termination? := (terminating.pending.find? (·.request.edge == .updateTerminal)).map (·.request)
  let termOk := match termination? with
    | some r => match Singular.txOf terminating.registry r (r.deposit + r.tip) with
      | .ok tx =>
        !(tx.outputs.any (·.role == .destination)) &&
          (tx.inputs.filter (·.role == .witness)).map (fun i => (i.datum, i.datumValue))
            == [(.inline, envelope)]
      | .error _ => false
    | none => false
  failed := failed + (← report termOk
    "termination: the root transaction has no destination output, and the witness it burns is spent with the envelope its insertion delivered, inline")
  pure failed

def check (dir : String) : IO UInt32 := do
  let corpus ← parseOrFail "corpus.json" (← IO.FS.readFile s!"{dir}/corpus.json")
  let ledgers ← parseOrFail "ledgers.json" (← IO.FS.readFile s!"{dir}/ledgers.json")
  let rows ← compiledRows
  let ledgersNow := ledgersJsonOf rows
  let mut failed := 0
  failed := failed + (← report (corpusJson == corpus)
    "the regenerated corpus equals the committed corpus")
  failed := failed + (← report (ledgersNow == ledgers)
    "the regenerated ledgers equal the committed ledgers")
  let diffs ← orFail "replay" (replayDiffs corpus)
  failed := failed + (← report diffs.isEmpty
    s!"every committed scenario replays from its own JSON ({diffs.length} differing: {diffs})")
  let altered ← orFail "alteration" (alterFirstOutcome corpus)
  let alteredDiffs ← orFail "replay of the altered corpus" (replayDiffs altered)
  failed := failed + (← report (!alteredDiffs.isEmpty)
    s!"control: replay notices one altered recorded outcome ({alteredDiffs})")
  failed := failed + (← report (corpusJson != altered)
    "control: the corpus comparison notices one altered recorded outcome")
  let droppedRow : Json := Json.mkObj
    [("theorems", Json.arr ((theoremLedgerOf rows).getArr?.toOption.getD #[]).pop)
    , ("atoms", atomLedger)]
  failed := failed + (← report (ledgersNow != droppedRow)
    "control: the ledger comparison notices one dropped theorem row")
  -- The proof status is compiled, and every tampered report is refused.
  let audited := OpenDatumApplication.Audit.compiledStatements
  let proved := rows.filter (·.status == "PROVED")
  failed := failed + (← report (audited.length == statementNames.length)
    s!"the compiled statements are the ledger's extent: {audited.length} discovered, {statementNames.length} in the ledger, {proved.length} proved")
  failed := failed + (← report
    (sha256Hex "abc" == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" &&
      sha256Hex "" == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    "control: SHA-256 answers its published test vectors")
  match audited with
  | first@(name, axioms, header) :: rest =>
    failed := failed + (← report (refusedFor "missing-report" (reconcileStatements rest))
      "control: a report missing one statement is refused")
    failed := failed + (← report (refusedFor "extra-report" (reconcileStatements
        (audited ++ [("OpenDatumApplication.Statements.not_a_statement", axioms, header)])))
      "control: a report naming a statement the ledger lacks is refused")
    failed := failed + (← report (refusedFor "missing-report" (reconcileStatements
        ((name ++ "_renamed", axioms, header) :: rest)))
      "control: a report renaming one statement is refused")
    failed := failed + (← report (refusedFor "duplicate-report" (reconcileStatements
        (first :: audited)))
      "control: a report listing one statement twice is refused")
    failed := failed + (← report (refusedFor "custom-axiom" (reconcileStatements
        ((name, axioms ++ ["OpenDatumApplication.customAxiom"], header) :: rest)))
      "control: a statement depending on a custom axiom is refused")
    failed := failed + (← report (refusedFor "missing-report" (reconcileStatements []))
      "control: an empty report is refused")
    let sorried := (reconcileStatements ((name, axioms ++ ["sorryAx"], header) :: rest)).toOption
    failed := failed + (← report (sorried.any fun rs =>
        (rs.find? (·.name == name)).any (·.status == "STATED") && ledgersJsonOf rs != ledgers)
      "control: a statement depending on sorryAx is computed STATED, and the ledger calling it proved notices")
    let rehashed := (reconcileStatements ((name, axioms, header ++ " ") :: rest)).toOption
    failed := failed + (← report (rehashed.any fun rs => ledgersJsonOf rs != ledgers)
      "control: a declaration header changed by one byte changes its row's hash, and the ledger comparison notices")
    failed := failed + (← report (flipFirstStatus ledgers != ledgersNow &&
        flipFirstStatus ledgers != Json.null)
      "control: a hand-flipped status in the committed ledger is noticed")
  | [] =>
    failed := failed + (← report false "the compiled statement table is empty")
  for (name, law) in mutants do
    let moved ← orFail s!"mutant {name}" (differingUnder law corpus)
    failed := failed + (← report (!moved.isEmpty)
      s!"control: definition mutant {name} runs {moved.length} scenarios differently: {moved}")
  failed := failed + (← report inconsistentReached.isEmpty
    s!"every genesis and every accepted step of every scenario observes the invariant ({inconsistentReached})")
  let exercised := ["bookInsert", "bookTerminate", "update", "fold", "reject"]
  failed := failed + (← report (exercised.all acceptedConstructors.contains)
    s!"every accepting constructor has a reached accepted step: {acceptedConstructors}")
  let ordinaryAfter := match appStep ordinaryWorld boundaryUpdate with
    | .ok w' => appConsistentB w'
    | .error _ => false
  failed := failed + (← report (appConsistentB ordinaryWorld && ordinaryAfter)
    "boundary: the ordinary reached world is consistent, and so is its updated successor")
  let duplicateAfter := match appStep duplicatedWorld boundaryUpdate with
    | .ok w' => some (appConsistentB w')
    | .error _ => none
  failed := failed + (← report (!appConsistentB duplicatedWorld && duplicateAfter == some false)
    "boundary: the identical-duplicate world is outside the invariant; its accepted update leaves two outputs of one key")
  failed := failed + (← report (appConsistentBWith false duplicatedWorld)
    "control: without the occurrence clause the observation would admit the identical-duplicate world")
  failed := failed + (← datumChecks)
  IO.println s!"application checks: {failed} failed"
  pure (if failed == 0 then 0 else 1)

def main (args : List String) : IO UInt32 := do
  match args with
  | ["corpus"] =>
    IO.println corpusJson.pretty
    pure 0
  | ["ledgers"] =>
    IO.println (ledgersJsonOf (← compiledRows)).pretty
    pure 0
  | ["write", dir] =>
    IO.FS.writeFile s!"{dir}/corpus.json" (corpusJson.pretty ++ "\n")
    IO.FS.writeFile s!"{dir}/ledgers.json" ((ledgersJsonOf (← compiledRows)).pretty ++ "\n")
    IO.println s!"wrote {dir}/corpus.json and {dir}/ledgers.json"
    pure 0
  | ["check", dir] => check dir
  | ["run", "appStep"] =>
    let j ← parseOrFail "scenario" (← readStdin)
    match scenarioFromJson j with
    | .ok s =>
      IO.println (runScenario s).pretty
      pure 0
    | .error e =>
      IO.eprintln s!"scenario does not decode: {e}"
      pure 2
  | _ =>
    IO.eprintln "usage: open-datum-application corpus | ledgers | write DIR | check DIR | run appStep"
    pure 2
