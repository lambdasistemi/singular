import Main.Base
import Main.Transactions
import Main.Payments
import Main.Exits
import Main.Retraction
import Main.Economics
import Singular.Driver
import Singular.Economics
open Singular
open Singular.Driver
open Lean

/-! The generic registry-mode corpus: the two admitted edges and the excluded
wire tags refused with their observable reasons, the codec both ways, the
read bound to the intermediate root, custody and custody-lovelace-refund value flow, the mint
check and the zero-request rule. Expectations are authored from the mandate;
results are computed from the model. -/

def batchOk : Bool :=
  match foldBatch s0
    [ { req .insertActive 5 42 555 with claimed := [(.active, 1)] }
    , { req .insertActive 6 42 556 with claimed := [(.active, 1)] } ] with
  | .ok _ => true | .error _ => false

/-- Illustrative amounts, not network measurements. The carrier is a declared
allocation; these controls do not determine any ledger minimum ada. -/
def registrationConfig : Config :=
  { cfg with
    registryId := 31, registrationCost := 17, minimumTip := 3,
    bookingWidth := 2, processTime := 10, retractTime := 5 }

def registrationApplicationTag : Approval :=
  { policy := registrationConfig.applicationPolicy, edge := .insertActive,
    key := 5, owner := 42, destination := 555,
    assetName := approvalAssetName .insertActive 5 42 555 }

def lawfulRegistrationBooking : RegistrationBooking :=
  let c := registrationConfig
  { request :=
      { reference := ⟨71, 0⟩, registryId := c.registryId, key := 5,
        refundAddress := 42, destination := 555, submittedAt := 102,
        registrationCost := 17, declaredTip := 3, carrierAda := 2,
        contents :=
          { lovelace := 22, applicationTags := [registrationApplicationTag],
            syntaxTags := [c.syntaxTag], otherAssets := [] } },
    interval := ⟨100, 102⟩, syntaxTagsMinted := [c.syntaxTag],
    applicationTagsMinted := [registrationApplicationTag] }

/-- Each row changes the lawful booking at one enforcement boundary. Reasons
are compared exactly; refusing the lawful row or refusing for another reason
fails the corpus. A short carrier means held value below the declared sum. -/
def registrationBookingControls : List (String × Config × RegistrationBooking × Option String) :=
  let c := registrationConfig
  let b := lawfulRegistrationBooking
  let r := b.request
  let contents := r.contents
  let dirty (story : String) (request : RegistrationRequest) :=
    (story, c, { b with request }, some "dirty-request")
  let tagVariants :=
    [ ("no syntax tag is minted", []),
      ("two syntax tags are minted", [c.syntaxTag, c.syntaxTag]),
      ("another registry's syntax tag is minted", [{ c.syntaxTag with policy := c.registryId + 1 }]),
      ("another syntax tag name is minted", [{ c.syntaxTag with name := c.syntaxTag.name + 1 }]) ]
  [ ("a lawful registration is booked", c, b, none)
  , ("a larger declared tip is booked", c,
      { b with request := { r with declaredTip := 8, contents := { contents with lovelace := 27 } } }, none)
  , ("the old fee pin does not constrain booking", { c with maxFee := 100 }, b, none)
  , dirty "an extra asset is refused"
      { r with contents := { contents with otherAssets := [(⟨99, 2⟩, 1)] } }
  , dirty "a wrong registration cost is refused"
      { r with registrationCost := 16, contents := { contents with lovelace := 21 } }
  , dirty "a tip below the minimum is refused"
      { r with declaredTip := 2, contents := { contents with lovelace := 21 } }
  , dirty "held value short of the declared carrier is refused"
      { r with contents := { contents with lovelace := 21 } }
  , dirty "an application tag for another operation is refused"
      { r with contents := { contents with applicationTags := [{ registrationApplicationTag with edge := .updateTerminal }] } }
  , dirty "an application tag for another key is refused"
      { r with contents := { contents with applicationTags := [{ registrationApplicationTag with key := 6 }] } }
  , dirty "an application tag for another refund address is refused"
      { r with contents := { contents with applicationTags := [{ registrationApplicationTag with owner := 43 }] } }
  , dirty "an application tag for another destination is refused"
      { r with contents := { contents with applicationTags := [{ registrationApplicationTag with destination := 556 }] } }
  , dirty "an application tag of another policy is refused"
      { r with contents := { contents with applicationTags := [{ registrationApplicationTag with policy := 9 }] } }
  , dirty "an application tag with another commitment is refused"
      { r with contents := { contents with applicationTags := [{ registrationApplicationTag with assetName := 0 }] } }
  , dirty "a missing application tag is refused"
      { r with contents := { contents with applicationTags := [] } }
  , dirty "two application tags are refused"
      { r with contents := { contents with applicationTags := [registrationApplicationTag, registrationApplicationTag] } }
  , dirty "a request for another registry is refused" { r with registryId := c.registryId + 1 }
  , ("lovelace beyond the declared contents is refused", c,
      { b with request := { r with contents := { contents with lovelace := 23 } } }, some "hidden-surplus")
  , ("the booked time cannot be backdated", c,
      { b with request := { r with submittedAt := 101 } }, some "backdated-booking")
  , ("the booked time cannot be moved beyond the interval", c,
      { b with request := { r with submittedAt := 103 } }, some "backdated-booking")
  , ("an interval wider than the limit is refused", c,
      { b with interval := ⟨99, 102⟩ }, some "booking-too-wide")
  , ("an empty interval is refused", c,
      { b with interval := ⟨102, 102⟩ }, some "invalid-booking-interval")
  , ("a reversed interval is refused", c,
      { b with interval := ⟨103, 102⟩ }, some "invalid-booking-interval")
  , ("a syntax tag must be held by the pending request", c,
      { b with request := { r with contents := { contents with syntaxTags := [] } } }, some "forged-syntax-tag")
  , ("a second held syntax tag is refused", c,
      { b with request := { r with contents := { contents with syntaxTags := [c.syntaxTag, c.syntaxTag] } } }, some "forged-syntax-tag")
  , ("an application tag must be minted with its request", c,
      { b with applicationTagsMinted := [] }, some "dirty-request")
  , ("a second application tag cannot be minted", c,
      { b with applicationTagsMinted := [registrationApplicationTag, registrationApplicationTag] }, some "dirty-request") ] ++
  tagVariants.map (fun (story, tags) =>
    (story, c, { b with syntaxTagsMinted := tags }, some "forged-syntax-tag"))

def registrationBookingRows : List Json :=
  registrationBookingControls.map fun (story, config, booking, expected) =>
    Json.mkObj [("story", toJson story), ("config", toJson config),
      ("booking", toJson booking), ("expectedReason", toJson expected),
      ("actualReason", toJson (registrationBookingRefusal config booking))]

/-- Exercise the real pool update with all the admission rows and a two-booking
history. Failed bookings return only a reason, and cannot produce a new pool. -/
def registrationWorldControl : Except String Unit := do
  for (story, config, booking, expected) in registrationBookingControls do
    let before : World := { registry := { s0 with config } }
    match book before booking, expected with
    | .ok after, none =>
      unless after.registry == before.registry && after.pending == [booking] do
        throw s!"booking changed the registry or lost its request: {story}"
    | .error actual, some reason =>
      unless actual == reason do throw s!"booking step: {story}: expected {reason}, actual {actual}"
    | _, _ => throw s!"booking step disagrees with admission: {story}"
  let first := lawfulRegistrationBooking
  let second := { first with request := { first.request with reference := ⟨72, 0⟩ } }
  let initial : World := { registry := { s0 with config := registrationConfig } }
  let once ← book initial first
  let twice ← book once second
  unless twice.registry == initial.registry && twice.pending == [second, first] do
    throw "two bookings must preserve the registry and both original transactions"
  unless (match book twice first with
    | .error reason => reason == "request-already-pending"
    | .ok _ => false) do
    throw "a repeated pending reference must be refused for its own reason"

/-- A termination starts from two keys registered by real model steps. No
active leaf or holding is seeded. Amounts are illustrative declarations. -/
def terminationWorld : Except String World := do
  let first ← step { s0 with config := registrationConfig } (req .insertActive 5 42 555)
  let second ← step first.state (req .insertActive 6 43 556)
  return { registry := second.state }

set_option autoImplicit false

/-- Read the custody input from the producing state. The application tag uses
zero in Approval's historical owner slot because a termination has no refund
address; that slot confers no signing requirement. -/
def terminationBookingFor (world : World) (key : Key) (reference : OutRef) :
    Except String TerminationBooking := do
  let some holding := world.registry.held.find? (fun h => h.key == key && h.kind == .active)
    | throw "control setup did not produce the active holding"
  let c := world.registry.config
  let tag : Approval :=
    { policy := c.applicationPolicy, edge := .updateTerminal, key,
      owner := 0, destination := holding.output,
      assetName := approvalAssetName .updateTerminal key 0 holding.output }
  return {
    request := {
      reference, registryId := c.registryId, key, destination := holding.output,
      declaredTip := 3, carrierAda := 2, singularTags := [c.singularTag key],
      contents := { lovelace := 5, applicationTags := [tag], syntaxTags := [c.syntaxTag] } },
    custodyInputs := [holding], syntaxTagsMinted := [c.syntaxTag],
    applicationTagsMinted := [tag] }

/-- Each control has an exact oracle, including the lawful rows. Both the
held tag and its mint are checked independently, with cardinality above one. -/
def terminationBookingControls : Except String
    (List (String × World × TerminationBooking × Option String)) := do
  let world ← terminationWorld
  let b ← terminationBookingFor world 5 ⟨81, 0⟩
  let c := world.registry.config
  let r := b.request
  let value := r.contents
  let some tag := value.applicationTags.head? | throw "control setup lost the application tag"
  let some singular := r.singularTags.head? | throw "control setup lost the singular tag"
  let row story request reason := (story, world, { b with request }, some reason)
  let tagRows := [
    ("no syntax tag", []), ("two syntax tags", [c.syntaxTag, c.syntaxTag]),
    ("another registry's syntax tag", [{ c.syntaxTag with policy := c.registryId + 1 }]),
    ("another syntax tag name", [{ c.syntaxTag with name := c.syntaxTag.name + 1 }]) ]
  let applicationRows := [
    ("another operation", { tag with edge := .insertActive }),
    ("another key", { tag with key := 6 }),
    ("another destination", { tag with destination := tag.destination + 1 }),
    ("another application policy", { tag with policy := tag.policy + 1 }),
    ("another application commitment", { tag with assetName := tag.assetName + 1 }),
    ("a refund owner in the application tuple", { tag with owner := 42 }) ]
  return [
    ("a lawful termination takes its singular tag from custody", world, b, none),
    ("a larger declared tip is accepted", world,
      { b with request := { r with declaredTip := 8, contents := { value with lovelace := 10 } } }, none),
    ("the old fee pin is independent of the minimum tip",
      { world with registry := { world.registry with config := { c with maxFee := 100 } } }, b, none),
    row "another key's singular tag is refused"
      { r with singularTags := [c.singularTag 6] } "forged-singular-tag",
    row "another registry's singular tag is refused"
      { r with singularTags := [{ singular with registryId := c.registryId + 1 }] } "forged-singular-tag",
    row "another policy's singular tag is refused"
      { r with singularTags := [{ singular with token := { singular.token with policy := singular.token.policy + 1 } }] } "forged-singular-tag",
    row "no singular tag is refused" { r with singularTags := [] } "forged-singular-tag",
    row "two singular tags are refused" { r with singularTags := [singular, singular] } "forged-singular-tag",
    ("a singular tag not taken from custody is refused", world,
      { b with custodyInputs := [] }, some "forged-singular-tag"),
    ("two custody input claims are refused", world,
      { b with custodyInputs := b.custodyInputs ++ b.custodyInputs }, some "forged-singular-tag"),
    ("another custody output cannot supply the tag", world,
      { b with custodyInputs := b.custodyInputs.map (fun h => { h with output := h.output + 1 }) },
      some "forged-singular-tag"),
    ("a key without active custody is refused",
      { registry := { s0 with config := c } }, b, some "singular-tag-not-in-custody"),
    row "an extra asset is refused"
      { r with contents := { value with otherAssets := [(⟨99, 2⟩, 1)] } } "dirty-request",
    row "a tip below the minimum is refused"
      { r with declaredTip := 2, contents := { value with lovelace := 4 } } "dirty-request",
    row "a refund address is refused" { r with refundAddress := some 42 } "dirty-request",
    row "a booked time is refused" { r with submittedAt := some 102 } "dirty-request",
    row "held value below the declared contents is refused"
      { r with contents := { value with lovelace := 4 } } "dirty-request",
    row "surplus beyond the declarations is refused"
      { r with contents := { value with lovelace := 6 } } "hidden-surplus",
    row "no application tag is refused"
      { r with contents := { value with applicationTags := [] } } "forged-application-tag",
    row "two application tags are refused"
      { r with contents := { value with applicationTags := [tag, tag] } } "forged-application-tag",
    ("the application tag must be minted with the request", world,
      { b with applicationTagsMinted := [] }, some "forged-application-tag"),
    ("a second application tag cannot be minted", world,
      { b with applicationTagsMinted := [tag, tag] }, some "forged-application-tag") ] ++
    applicationRows.map (fun (story, changed) => row (story ++ " is refused")
      { r with contents := { value with applicationTags := [changed] } } "forged-application-tag") ++
    tagRows.flatMap (fun (story, tags) => [
      row (story ++ " held is refused")
        { r with contents := { value with syntaxTags := tags } } "forged-syntax-tag",
      (story ++ " minted is refused", world, { b with syntaxTagsMinted := tags }, some "forged-syntax-tag") ])

def terminationControlRows : Except String (List Json) := do
  let controls ← terminationBookingControls
  controls.mapM fun (story, world, booking, expected) => do
    let actual := terminationBookingRefusal world.registry booking
    unless actual == expected do
      throw s!"termination booking: {story}: expected {repr expected}, actual {repr actual}"
    match bookTermination world booking, expected with
    | .ok after, none =>
      unless after.registry.trie == world.registry.trie &&
          after.registry.config == world.registry.config &&
          after.pending == world.pending && after.terminations == booking :: world.terminations &&
          kindCount after.registry .active booking.request.key == 0 &&
          kindCount after.registry .active 6 == kindCount world.registry .active 6 do
        throw s!"termination booking lost custody or changed unrelated state: {story}"
    | .error reason, some expectedReason =>
      unless reason == expectedReason do throw s!"termination step: {story}: {reason}"
    | _, _ => throw s!"termination step disagrees with admission: {story}"
    return Json.mkObj [("story", toJson story), ("config", toJson world.registry.config),
      ("heldBefore", toJson world.registry.held), ("booking", toJson booking),
      ("expectedReason", toJson expected), ("actualReason", toJson actual)]

/-- Test repeated bookings both as separate calls and within one atomic
transaction. A refusal must leave the original one-request pool intact. -/
def terminationPoolControls : Except String Unit := do
  let world ← terminationWorld
  let first ← terminationBookingFor world 5 ⟨81, 0⟩
  let second ← terminationBookingFor world 6 ⟨81, 1⟩
  let repeated := { first with request := { first.request with reference := ⟨82, 0⟩ } }
  let repeatedWithin := { first with request := { first.request with reference := ⟨81, 1⟩ } }
  let once ← bookTermination world first
  unless (match bookTermination once repeated with
    | .error reason => reason == "singular-tag-not-in-custody" | .ok _ => false) do
    throw "a later second termination must be refused because its tag has left custody"
  unless once.terminations == [first] && kindCount once.registry .active 5 == 0 do
    throw "a failed second termination changed the pending pool"
  unless (match bookTermination once repeatedWithin with
    | .error reason => reason == "singular-tag-not-in-custody" | .ok _ => false) do
    throw "a second output of the same transaction cannot take the intermediate world's tag"
  unless once.terminations == [first] do
    throw "the intermediate calculation must still contain just the first termination"
  unless (match bookTerminations world [first, repeatedWithin] with
    | .error reason => reason == "singular-tag-not-in-custody" | .ok _ => false) do
    throw "two terminations of one key in one transaction must be refused"
  unless world.terminations.isEmpty && kindCount world.registry .active 5 == 1 do
    throw "the refused whole transaction must leave its original pool and custody unchanged"
  let both ← bookTerminations world [first, second]
  unless both.terminations == [second, first] && both.registry.held.isEmpty do
    throw "two different keys may each move their singular tag from custody"
  let mixed ← book once lawfulRegistrationBooking
  unless mixed.terminations == [first] && mixed.pending == [lawfulRegistrationBooking] &&
      mixed.registry == once.registry do
    throw "registration booking must preserve a pending termination"

def main : IO Unit := do
  let stdout ← IO.getStdout
  let terminationRows ← match terminationControlRows with
    | .ok rows => pure rows
    | .error reason => throw (IO.userError reason)
  match terminationPoolControls with
  | .ok () => pure ()
  | .error reason => throw (IO.userError reason)
  match registrationWorldControl with
  | .ok () => pure ()
  | .error reason => throw (IO.userError reason)
  for (story, config, booking, expected) in registrationBookingControls do
    let actual := registrationBookingRefusal config booking
    unless actual == expected do
      throw (IO.userError s!"registration booking: {story}: expected {repr expected}, actual {repr actual}")
  match parameterPreservationControl with
  | .ok () => pure ()
  | .error reason => throw (IO.userError reason)
  unless parameterCodecControl do
    throw (IO.userError "economic parameter defaults, pins or roundtrip failed")
  for (story, correct) in stateIdentityControls do
    unless correct do throw (IO.userError s!"state token identity: {story}")
  for (story, correct) in economicControls do
    unless correct do throw (IO.userError s!"transaction vocabulary: {story}")
  for c in cases do
    unless correct c do
      throw (IO.userError s!"scenario expectation failed: {c.id}: {caseActualString c}")
  unless batchOk do throw (IO.userError "GF02 batch-accepted failed")
  unless batchEmpty == some "empty-fold" do throw (IO.userError "GF01 empty-fold failed")
  unless batchMint == some "net-mint-mismatch" do throw (IO.userError "GF03 mint failed")
  for (id, expectNonEmpty, paid) in adaRows do
    let ok := if expectNonEmpty then !paid.isEmpty && paid.all (fun p => p.1 == 91) else paid.isEmpty
    unless ok do throw (IO.userError s!"{id}: {repr paid}")
  for (id, expectSome, res, _) in codecRows do
    let ok := if expectSome then res.isSome else res.isNone
    unless ok do throw (IO.userError s!"{id} failed")
  unless configRow do throw (IO.userError "GD-config roundtrip failed")
  -- transaction-correspondence: the transaction row and the keyed mint rows are verdicts, not claims
  unless (match txResult with | .ok _ => true | .error _ => false) do
    throw (IO.userError "Transaction correspondence insertActive transaction was refused")
  unless (match txBuilt with | .ok _ => true | .error _ => false) do
    throw (IO.userError "Transaction correspondence the model built no transaction for an admitted insertActive")
  unless txSecondReason == "key-exists" do
    throw (IO.userError s!"Transaction correspondence second insertActive: {txSecondReason}")
  unless approvalsIn txRequest == 1 do throw (IO.userError "Transaction correspondence approval count")
  unless lovelaceCoversTip cfg txLovelace do throw (IO.userError "Transaction correspondence tip not covered")
  unless destinationDatumBinds txRequest do throw (IO.userError "Transaction correspondence destination datum")
  unless openAdmitsEveryTuple cfg do throw (IO.userError "Transaction correspondence open policy admission")
  unless !crossRegistrySeparation cfg otherRegistry txRequest do
    throw (IO.userError "Transaction correspondence cross-registry separation is a non-goal, not a promise")
  unless (match foldActions s0 keyedWrongKey with | .ok _ => true | .error _ => false) do
    throw (IO.userError "Transaction correspondence wrong-key batch: a request failed to apply, so the refusal is not the keyed guard's")
  unless foldReason (foldBatch s0 keyedAccepted) == "" do
    throw (IO.userError "Transaction correspondence keyed accepted row refused")
  unless foldReason (foldBatch s0 keyedWrongKey) == "net-mint-mismatch" do
    throw (IO.userError s!"Transaction correspondence wrong-key row: {foldReason (foldBatch s0 keyedWrongKey)}")
  -- #177: the transaction an admitted updateTerminal builds is a verdict too
  unless (match retireResult with | .ok _ => true | .error _ => false) do
    throw (IO.userError "Transaction correspondence updateTerminal was refused at a booked key")
  unless (match retireTx with | .ok _ => true | .error _ => false) do
    throw (IO.userError "Transaction correspondence the model built no transaction for an admitted updateTerminal")
  unless retireBurnSourced do
    throw (IO.userError s!"Transaction correspondence updateTerminal burns {repr retireBurned} and its inputs spend {repr retireSpent}: the burn has no source")
  unless retireOutputsPositive do
    throw (IO.userError "Transaction correspondence updateTerminal: an output is left holding a quantity an output cannot hold")
  unless (match retireTx with
      | .ok tx => tx.refunds == [(retireRequest.owner, retireRequest.deposit)] && tx.signers.isEmpty
      | .error _ => false) do
    throw (IO.userError "Transaction correspondence updateTerminal: refunds are not the deposit back to the owner, or a signer is required")
  for (id, expected, before) in retirementRefusalRows do
    unless retireRefusal before == expected do
      throw (IO.userError s!"{id}: {retireRefusal before} (expected {expected})")
  unless signerFailures.isEmpty do
    throw (IO.userError s!"a fold requires a signer: {signerFailures}")
  unless admissionFailures.isEmpty do
    throw (IO.userError s!"retraction admission: {admissionFailures}")
  unless admittedExitFailures.isEmpty do
    throw (IO.userError s!"admitted exit: {admittedExitFailures}")
  unless judgementFailures.isEmpty do
    throw (IO.userError s!"judgement: {judgementFailures}")
  unless leafByte .unknown == 0xFF do
    throw (IO.userError "the unknown lookup answer lost its 0xFF codec byte")
  unless batchEmpty.isSome && batchMint.isSome do throw (IO.userError "fold rows failed")
  let foldJson := foldRows.map fun p =>
    Json.mkObj [("id", p.1), ("ok", p.2.1), ("reason", p.2.2),
      ("verified", Json.mkObj [("empty", batchEmpty == some "empty-fold"),
        ("batch", batchOk), ("mint", batchMint == some "net-mint-mismatch")])]
  let adaJson := adaRows.map fun p =>
    Json.mkObj [("id", p.1), ("paidTo", toJson ((p.2.2).map (·.1)))]
  let codecJson := codecRows.map fun p =>
    Json.mkObj [("id", p.1), ("decodes", p.2.2.1.isSome), ("expectedDecodes", p.2.1),
      ("bytes", toJson p.2.2.2)]
  let json := Json.mkObj
    [ ("schema", toJson "singular-logical-corpus-v2")
    , ("terminationBookings", toJson terminationRows)
    , ("registrationBookings", toJson registrationBookingRows)
    , ("cases", toJson (cases.map caseJson))
    , ("folds", toJson foldJson)
    , ("ada", toJson adaJson)
    , ("codec", toJson codecJson)
    , ("configRoundtrip", toJson configRow)
    , ("economicControls", toJson (economicControls.map fun (story, result) =>
        Json.mkObj [("story", toJson story), ("result", toJson result)]))
    , ("tokenPolicies", tokenPoliciesJson)
    , ("transactions", Json.arr #[transactionRowJson, retirementRowJson])
    , ("keyedMintRows", Json.arr
        #[ keyedMintRowJson "GK01-two-keys-accepted" keyedAccepted
         , keyedMintRowJson "GK02-same-kind-wrong-key-refused" keyedWrongKey ])
    , ("model", toJson cfg) ]
  stdout.putStrLn json.compress
