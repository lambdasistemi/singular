import Singular
open Lean Singular

def initial : State := {}
def nft : Representative := representative initial 42
def outA : Output := { representative := nft, destination := 50, datum := 100, value := 20 }
def proposal : Proposal := { registry := 1, key := 42, applicationPolicy := 7,   initial := outA, scope := [0] }
def req : Request := { id := 1, operation := .insert, proposal,   token := some (insertAsset proposal), destination := 90, authenticatedOrigin := true }
def approval : Approval := { asset := insertAsset proposal, accepted := true }
def wm : Witnesses := { applicationMint := true }
def ws : Witnesses := { applicationSpend := true }
def wn : Witnesses := { nativeSpend := true, representativeMint := true }
def item : FoldItem := { request := 1, outputId := 2, output := some outA }
def plus : List Delta := [{ asset := nft, quantity := 1 }]
def minus : List Delta := [{ asset := nft, quantity := -1 }]
def after (s : State) (a : Action) : State :=
  match step s a with | .ok r => r.state | .error _ => s
def pending := after initial (.createInsert req approval wm)
def live := after pending (.fold [item] plus [] wn)
def terminal (op : Operation) : Request :=
  { req with id := 3, operation := op, token := none, held := some nft }
def releaseAction (op : Operation) : Action :=
  .release 2 (terminal op) { source := 2, request := terminal op, accepted := true } ws
def deleting := after live (releaseAction .delete)
def retiring := after live (releaseAction .update)
def terminalItem : FoldItem := { request := 3 }
def gone := after deleting (.fold [terminalItem] minus [] wn)
def retired := after retiring (.fold [terminalItem] minus [] wn)
def refund : Refund := { destination := 60, value := 20 }
def wa : Asset := { policy := 7, name := .withdraw 1 1 refund }
def cancellation := after pending (.mintWithdraw { asset := wa, accepted := true } wm)
def newProposal : Proposal := { proposal with scope := [1] }
def newReq : Request := { req with id := 4, proposal := newProposal, token := some (insertAsset newProposal) }
def newApproval : Approval := { approval with asset := insertAsset newProposal }
def repeatPending := after gone (.createInsert newReq newApproval wm)
def simultaneous := after deleting (.createInsert newReq newApproval wm)
def successor : ApplicationUTxO := { id := 5, key := 42, output := { outA with datum := 200 } }
def evolution : Action := .evolve 2 successor { source := 2, successor, accepted := true } ws

structure Case where
  id : String
  status : String := "modeled"
  before : State
  action : Action
  accept : Bool
  expectedReason : String := ""
  deriving ToJson

def cases : List Case := [
  { id := "S19c-distinct-action-assets-do-not-net", status := "abstract-disposal", before := pending, action := .fold [item] plus [{ asset := approval.asset, quantity := -1 }, { asset := wa, quantity := 1 }] wn, accept := false, expectedReason := "application-mint-witness" },
  { id := "S10b-release-varied-entry", before := { live with entries := [{ key := 42, value := some .over, incarnation := 8 }], config := { live.config with reuseIdentity := false } }, action := releaseAction .delete, accept := true },
  { id := "S10c-insert-varied-entry", before := { initial with entries := [{ key := 42, value := some .over, incarnation := 8 }] }, action := .createInsert req approval wm, accept := true },
  { id := "S01-approved-insert", before := pending, action := .fold [item] plus [] wn, accept := true },
  { id := "S02-no-approval", before := initial,     action := .createInsert req { approval with accepted := false } wm,     accept := false, expectedReason := "application-approval" },
  { id := "S03-substitute-policy", before := initial,     action := .createInsert req { approval with asset := { approval.asset with policy := 99 } } wm,     accept := false, expectedReason := "insert-binding" },
  { id := "S04-substituted-output", before := pending,     action := .fold [{ item with output := some { outA with datum := 999 } }] plus [] wn,     accept := false, expectedReason := "certified-output" },
  { id := "S05-competing-inserts", before := after pending (.createInsert { req with id := 6 } approval wm),     action := .fold [item, { item with request := 6, outputId := 7 }] [{ asset := nft, quantity := 2 }] [] wn,     accept := false, expectedReason := "occupied-key" },
  { id := "S06-exact-withdraw", status := "conditional-refund-profile", before := cancellation,     action := .withdraw 1 wa refund { nativeSpend := true }, accept := true },
  { id := "S07-insert-cannot-withdraw", before := pending,     action := .withdraw 1 approval.asset refund { nativeSpend := true },     accept := false, expectedReason := "withdraw-binding" },
  { id := "S07b-wrong-pending-withdraw", before := cancellation,     action := .withdraw 1 { wa with name := .withdraw 1 99 refund } refund { nativeSpend := true },     accept := false, expectedReason := "withdraw-binding" },
  { id := "S08-local-evolution", status := "conditional-application-contract", before := live,     action := evolution, accept := true },
  { id := "S09-delete-substituted-update", before := live,     action := .release 2 (terminal .update) { source := 2, request := terminal .delete, accepted := true } ws,     accept := false, expectedReason := "exact-release-authorization" },
  { id := "S10-release-without-registry-read", before := { live with entries := [], config := { live.config with reuseIdentity := false } },     action := releaseAction .delete, accept := true },
  { id := "S11-custody-escape", before := deleting, action := .escape 3,     accept := false, expectedReason := "completion-only-custody" },
  { id := "S12-update-completes", before := retiring, action := .fold [terminalItem] minus [] wn, accept := true },
  { id := "S13-delete-completes", before := deleting, action := .fold [terminalItem] minus [] wn, accept := true },
  { id := "S13b-reinsert", before := repeatPending,     action := .fold [{ item with request := 4, outputId := 5 }] plus [] wn, accept := true },
  { id := "S14-wrong-registry-nft", before := live,     action := .release 2 { (terminal .delete) with held := some { nft with registry := 99 } }       { source := 2, request := { (terminal .delete) with held := some { nft with registry := 99 } }, accepted := true } ws,     accept := false, expectedReason := "terminal-binding" },
  { id := "S15-completed-replay", before := live, action := .fold [item] plus [] wn,     accept := false, expectedReason := "request-unavailable" },
  { id := "S15b-incarnation-replay", before := after gone (.createInsert { req with id := 6 } approval wm),     action := .fold [{ item with request := 6, outputId := 7 }] plus [] wn,     accept := false, expectedReason := "approval-scope" },
  { id := "S16-unrelated-folder", before := pending, action := .fold [item] plus [] wn, accept := true },
  { id := "S17-outsider-output-creation", before := initial,     action := .outsider { req with destination := 999 }, accept := true },
  { id := "S17b-outsider-refused", before := after initial (.outsider { req with destination := 999 }),     action := .fold [item] plus [] wn, accept := false, expectedReason := "unauthenticated-request" },
  { id := "S18-issuer-not-semantics", status := "conditional-application-contract-fails", before := initial,     action := .createInsert req { approval with conforms := false } wm, accept := true },
  { id := "S19-action-burn-witness", status := "abstract-disposal", before := pending,     action := .fold [item] plus [{ asset := approval.asset, quantity := -1 }] wn, accept := false, expectedReason := "application-mint-witness" },
  { id := "S19b-action-burn-executes", status := "abstract-disposal", before := pending,     action := .fold [item] plus [{ asset := approval.asset, quantity := -1 }] { wn with applicationMint := true }, accept := true },
  { id := "S20-existing-action-movement", status := "abstract-token-location", before := pending,     action := .moveAction approval.asset 0 {}, accept := true },
  { id := "S21-zero-net-delete-insert", status := "proposed-reused-identity-profile", before := simultaneous,     action := .fold [terminalItem, { item with request := 4, outputId := 5 }] [] [] { nativeSpend := true }, accept := true },
  { id := "S21b-zero-net-no-spending-witness", before := simultaneous,     action := .fold [terminalItem, { item with request := 4, outputId := 5 }] [] [] {},     accept := false, expectedReason := "native-witness" },
  { id := "N01-register-address-A", status := "proposed-naming-profile", before := pending, action := .fold [item] plus [] wn, accept := true },
  { id := "N02-occupied-name", before := after live (.createInsert { req with id := 6 } approval wm),     action := .fold [{ item with request := 6, outputId := 7 }] plus [] wn, accept := false, expectedReason := "occupied-key" },
  { id := "N06-change-address-B", status := "conditional-application-contract", before := live, action := evolution, accept := true },
  { id := "N07-unauthorized-change", before := live,     action := .evolve 2 successor { source := 2, successor, accepted := false } ws,     accept := false, expectedReason := "application-evolution-authorization" }]

def caseJson (c : Case) : Json :=
  let result := step c.before c.action
  Json.mkObj [("case", toJson c), ("result", match result with
    | .ok r => Json.mkObj [("accepted", toJson true), ("value", toJson r)]
    | .error reason => Json.mkObj [("accepted", toJson false), ("reason", toJson reason)])]
def correct (c : Case) : Bool := match step c.before c.action with
  | .ok _ => c.accept | .error reason => !c.accept && reason == c.expectedReason

def resolutions : List (String × State × Bool × Resolution) := [
  ("N03-resolve-live", live, true, .address 100),
  ("N04-resolve-pending", deleting, true, .pending),
  ("N05-resolve-absent", gone, true, .absent),
  ("N05b-resolve-over", retired, true, .retired),
  ("N06b-resolve-new-address", after live evolution, true, .address 200),
  ("N07b-forged-view", live, false, .unauthenticated)]

def main : IO Unit := do
  let stdout ← IO.getStdout
  for c in cases do
    unless correct c do throw (IO.userError s!"scenario expectation failed: {c.id}: {repr (step c.before c.action)}")
  for (id, s, authenticated, expected) in resolutions do
    unless resolve s 42 authenticated == expected do throw (IO.userError s!"resolution failed: {id}")
  let json := Json.mkObj [("schema", toJson "singular-logical-corpus-v1"),
    ("cases", toJson (cases.map caseJson)),
    ("resolutions", toJson (resolutions.map fun (id, s, authenticated, expected) =>
      Json.mkObj [("id", toJson id), ("before", toJson s), ("key", toJson (42 : Nat)),
        ("authenticated", toJson authenticated), ("expected", toJson expected)]))]
  stdout.putStrLn json.compress
