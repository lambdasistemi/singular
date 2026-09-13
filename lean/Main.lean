import Singular
open Lean Singular

def initial : State := {}
def nft : Representative := representative initial 42
def outA : Output := { representative := nft, destination := 50, datum := 100, value := 20 }
def proposal : Proposal :=
  { registry := 1
    key := 42
    applicationPolicy := 7
    refundAddress := 60
    initial := outA
    scope := [0] }
def req : Request := { id := 1, operation := .insert, proposal,   token := some (insertAsset proposal), destination := 90, authenticatedOrigin := true }
def approval : Approval := { asset := insertAsset proposal, accepted := true }
def wm : Witnesses := { applicationMint := true }
def ws : Witnesses := { applicationSpend := true }
def wn : Witnesses := { nativeSpend := true, representativeMint := true, consumerWithdraw := true }
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

def substituteProposal : Proposal := { proposal with applicationPolicy := 99 }
def substituteReq : Request :=
  { req with proposal := substituteProposal, token := some (insertAsset substituteProposal) }
def substituteApproval : Approval := { approval with asset := insertAsset substituteProposal }
def secondReq : Request := { req with id := 6 }
def secondWa : Asset := { wa with name := .withdraw 1 6 refund }
def twoPending := after pending (.createInsert secondReq approval wm)
def secondCancellation := after twoPending (.mintWithdraw { asset := secondWa, accepted := true } wm)
def outsiderBase := after pending (.mintWithdraw { asset := secondWa, accepted := true } wm)
def outsiderPending := after outsiderBase (.outsider secondReq)
def terminalWa : Asset := { wa with name := .withdraw 1 3 refund }
def terminalCancellation := after deleting (.mintWithdraw { asset := terminalWa, accepted := true } wm)
def freshInitial : State := { initial with config := { initial.config with reuseIdentity := false } }
def freshPending := after freshInitial (.createInsert req approval wm)
def freshLive := after freshPending (.fold [item] plus [] wn)
def freshDeleting := after freshLive (releaseAction .delete)
def freshGone := after freshDeleting (.fold [terminalItem] minus [] wn)
def freshNft : Representative := representative freshGone 42
def freshOut : Output := { outA with representative := freshNft }
def freshProposal : Proposal := { newProposal with initial := freshOut }
def freshReq : Request := { newReq with proposal := freshProposal, token := some (insertAsset freshProposal) }
def freshApproval : Approval := { approval with asset := insertAsset freshProposal }
def freshRepeatPending := after freshGone (.createInsert freshReq freshApproval wm)
def freshSimultaneous := after freshDeleting (.createInsert freshReq freshApproval wm)
def freshItem : FoldItem := { item with request := 4, outputId := 5, output := some freshOut }
def freshPlus : List Delta := [{ asset := freshNft, quantity := 1 }]
def staleProposal : Proposal := { proposal with scope := [0, 1] }
def staleReq : Request := { newReq with proposal := staleProposal, token := some (insertAsset staleProposal) }
def staleApproval : Approval := { approval with asset := insertAsset staleProposal }
def stalePending := after freshGone (.createInsert staleReq staleApproval wm)

structure Case where
  id : String
  status : String := "modeled"
  before : State
  action : Action
  accept : Bool
  expectedReason : String := ""
  deriving ToJson

def cases : List Case := [
  { id := "S03b-configured-issuer-control", before := initial, action := .createInsert req approval wm, accept := true },
  { id := "S07c-second-pending-insert", before := pending, action := .createInsert secondReq approval wm, accept := true },
  { id := "S07d-mint-second-withdraw", before := twoPending, action := .mintWithdraw { asset := secondWa, accepted := true } wm, accept := true },
  { id := "S07e-valid-second-target", before := secondCancellation, action := .withdraw 6 secondWa refund { nativeSpend := true }, accept := true },
  { id := "S11b-mint-terminal-withdraw", before := deleting, action := .mintWithdraw { asset := terminalWa, accepted := true } wm, accept := true },
  { id := "S11c-terminal-withdraw-refused", before := terminalCancellation, action := .withdraw 3 terminalWa refund { nativeSpend := true }, accept := false, expectedReason := "withdraw-insert-only" },
  { id := "S17c-outsider-withdraw-refused", before := outsiderPending, action := .withdraw 6 secondWa refund { nativeSpend := true }, accept := false, expectedReason := "withdraw-insert-only" },
  { id := "S13c-fresh-insert-created", status := "proposed-fresh-identity-profile", before := freshInitial, action := .createInsert req approval wm, accept := true },
  { id := "S13d-fresh-insert-folded", status := "proposed-fresh-identity-profile", before := freshPending, action := .fold [item] plus [] wn, accept := true },
  { id := "S13e-fresh-delete-released", status := "proposed-fresh-identity-profile", before := freshLive, action := releaseAction .delete, accept := true },
  { id := "S13f-fresh-delete-completed", status := "proposed-fresh-identity-profile", before := freshDeleting, action := .fold [terminalItem] minus [] wn, accept := true },
  { id := "S13g-fresh-reinsert-created", status := "proposed-fresh-identity-profile", before := freshGone, action := .createInsert freshReq freshApproval wm, accept := true },
  { id := "S13h-fresh-reinsert-folded", status := "proposed-fresh-identity-profile", before := freshRepeatPending, action := .fold [freshItem] freshPlus [] wn, accept := true },
  { id := "S13i-stale-identity-created", status := "proposed-fresh-identity-profile", before := freshGone, action := .createInsert staleReq staleApproval wm, accept := true },
  { id := "S13j-stale-identity-refused", status := "proposed-fresh-identity-profile", before := stalePending, action := .fold [{ item with request := 4, outputId := 5 }] plus [] wn, accept := false, expectedReason := "representative-identity" },
  { id := "S21c-fresh-batch-staged", status := "proposed-fresh-identity-profile", before := freshDeleting, action := .createInsert freshReq freshApproval wm, accept := true },
  { id := "S21d-fresh-delete-insert", status := "proposed-fresh-identity-profile", before := freshSimultaneous, action := .fold [terminalItem, freshItem] (minus ++ freshPlus) [] wn, accept := true },
  { id := "S21e-fresh-wrong-zero-net", status := "proposed-fresh-identity-profile", before := freshSimultaneous, action := .fold [terminalItem, freshItem] [] [] wn, accept := false, expectedReason := "net-mint-mismatch" },
  { id := "S19c-distinct-action-assets-do-not-net", status := "abstract-disposal", before := pending, action := .fold [item] plus [{ asset := approval.asset, quantity := -1 }, { asset := wa, quantity := 1 }] wn, accept := false, expectedReason := "application-mint-witness" },
  { id := "S10b-release-varied-entry", before := { live with entries := [{ key := 42, value := some .over, incarnation := 8 }], config := { live.config with reuseIdentity := false } }, action := releaseAction .delete, accept := true },
  { id := "S10c-insert-varied-entry", before := { initial with entries := [{ key := 42, value := some .over, incarnation := 8 }] }, action := .createInsert req approval wm, accept := true },
  { id := "S01-approved-insert", before := pending, action := .fold [item] plus [] wn, accept := true },
  { id := "S02-no-approval", before := initial,     action := .createInsert req { approval with accepted := false } wm,     accept := false, expectedReason := "application-approval" },
  { id := "S03-substitute-policy", before := initial,     action := .createInsert substituteReq substituteApproval wm,     accept := false, expectedReason := "insert-binding" },
  { id := "S04-substituted-output", before := pending,     action := .fold [{ item with output := some { outA with datum := 999 } }] plus [] wn,     accept := false, expectedReason := "certified-output" },
  { id := "S05-competing-inserts", before := after pending (.createInsert { req with id := 6 } approval wm),     action := .fold [item, { item with request := 6, outputId := 7 }] [{ asset := nft, quantity := 2 }] [] wn,     accept := false, expectedReason := "occupied-key" },
  { id := "S06-exact-withdraw", status := "conditional-refund-profile", before := cancellation,     action := .withdraw 1 wa refund { nativeSpend := true }, accept := true },
  { id := "S07-insert-cannot-withdraw", before := pending,     action := .withdraw 1 approval.asset refund { nativeSpend := true },     accept := false, expectedReason := "withdraw-binding" },
  { id := "S07b-wrong-pending-withdraw", before := secondCancellation,     action := .withdraw 1 secondWa refund { nativeSpend := true },     accept := false, expectedReason := "withdraw-binding" },
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
  { id := "S17-outsider-output-creation", before := outsiderBase,     action := .outsider secondReq, accept := true },
  { id := "S17b-outsider-refused", before := outsiderPending,     action := .fold [{ item with request := 6 }] plus [] wn, accept := false, expectedReason := "unauthenticated-request" },
  { id := "S18-issuer-not-semantics", status := "conditional-application-contract-fails", before := initial,     action := .createInsert req { approval with conforms := false } wm, accept := true },
  { id := "S19-action-burn-witness", status := "abstract-disposal", before := pending,     action := .fold [item] plus [{ asset := approval.asset, quantity := -1 }] wn, accept := false, expectedReason := "application-mint-witness" },
  { id := "S19b-action-burn-executes", status := "abstract-disposal", before := pending,     action := .fold [item] plus [{ asset := approval.asset, quantity := -1 }] { wn with applicationMint := true }, accept := true },
  { id := "S20-existing-action-movement", status := "abstract-token-location", before := pending,     action := .moveAction approval.asset 0 {}, accept := true },
  { id := "S21-zero-net-delete-insert", status := "proposed-reused-identity-profile", before := simultaneous,     action := .fold [terminalItem, { item with request := 4, outputId := 5 }] [] [] { nativeSpend := true, consumerWithdraw := true }, accept := true },
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
