import Main.RejectionReadsState

/-! Transactions for the economic refund contract. Each world is produced by
the real booking functions. Amounts are illustrative, not ledger measurements.
The historical test commit records missing retraction admission separately
and preserves the pre-implementation rejection failures. -/

open Singular

namespace RefundControls

structure Control where
  story : String
  world : World
  unspent : EconomicUtxo
  transaction : EconomicTransaction
  members : List (OutRef × RejectReason)
  retract : Bool := false
  expected : Option String

def registration (key position address : Nat) : RegistrationBooking :=
  let original := RejectionReadControls.registration key position
  let r := { original.request with refundAddress := address }
  let application : Approval :=
    { policy := RejectionReadControls.config.applicationPolicy,
      edge := .insertActive, key, owner := address, destination := r.destination,
      assetName := applicationTagAssetName key address r.destination r.nonce }
  { original with
    request := { r with contents := { r.contents with
      applicationTags := [application],
      trieReadyTags := [r.trieReadyTag RejectionReadControls.config] } },
    applicationTagsMinted := [application],
    trieReadyTagsMinted := [r.trieReadyTag RejectionReadControls.config] }

def world : Except String World := do
  let initial ← RejectionReadControls.world
  let withOther ← book initial (registration 9 3 43)
  book withOther (registration 10 4 42)

def payment (address lovelace : Nat) : EconomicOutput :=
  { output := { economicOutput lovelace with
      role := .owner, address := some address, assets := [] },
    contents := { lovelace, trieReadyTags := [], applicationTags := [] } }

def withPayments (tx : EconomicTransaction) (payments : List EconomicOutput) :
    EconomicTransaction :=
  { tx with outputs := payments, transaction.outputs := payments.map (·.output) }

def rejection (w : World) (story : String) (bookings : List RegistrationBooking)
    (payments : List EconomicOutput) (expected : Option String) : Control :=
  let row := RejectionReadControls.lawful w story bookings
    (bookings.map fun _ => .expired) ⟨117, 118⟩
  { story, world := w,
    unspent := RejectionReadControls.observedUnspent w row.unspent,
    transaction := withPayments (RejectionReadControls.observedTransaction row) payments,
    members := row.members, expected }

def retraction (w : World) : Control :=
  let b := registration 6 1 42
  let row := rejection w "a signed retraction returns cost, tip and carrier" [b]
    [payment b.request.refundAddress b.request.contents.lovelace] none
  { row with
    retract := true, transaction.transaction.referenceInputs := [],
    transaction.transaction.validity := some ⟨112, 117⟩,
    transaction.transaction.signers := [b.request.refundAddress] }

def controls (w : World) : List Control :=
  let a := registration 6 1 42
  let b := registration 9 3 43
  let c := registration 10 4 42
  let owed (r : RegistrationBooking) := r.request.contents.lovelace - r.request.declaredTip
  let same := rejection w "two requests at one address receive one summed refund" [a, c]
    [payment a.request.refundAddress (owed a + owed c)] none
  let separate := rejection w "different addresses each receive their own refund" [a, b]
    [payment a.request.refundAddress (owed a), payment b.request.refundAddress (owed b)] none
  let reclaim := retraction w
  let stateInput := RejectionReadControls.input RejectionReadControls.stateReference
  [same, separate,
   rejection w "one rejected request receives held minus tip" [a]
     [payment a.request.refundAddress (owed a)] none,
   rejection w "a rejection refund one lovelace short is refused" [a]
     [payment a.request.refundAddress (owed a - 1)] (some "reject-refund-short"),
   rejection w "a rejection refund sent to another address is refused" [a]
     [payment b.request.refundAddress (owed a)] (some "reject-refund-short"),
   rejection w "one address cannot reuse another address's refund" [a, b]
     [payment a.request.refundAddress (owed a + owed b)] (some "reject-refund-short"),
   { same with
     story := "one request's amount cannot pay two requests at the same address",
     transaction := withPayments same.transaction [payment a.request.refundAddress (owed a)],
     expected := some "reject-refund-short" },
   rejection w "a repeated request cannot receive credit twice" [a, a]
     [payment a.request.refundAddress (owed a)] (some "reject-duplicate-input"),
   rejection w "the registration cost cannot be omitted on rejection" [a]
     [payment a.request.refundAddress a.request.carrierAda] (some "reject-refund-short"),
   reclaim,
   { reclaim with
     story := "a retraction one lovelace short is refused",
     transaction := withPayments reclaim.transaction
       [payment a.request.refundAddress (a.request.contents.lovelace - 1)],
     expected := some "retract-refund-short" },
   { reclaim with
     story := "a retraction cannot withhold the tip",
     transaction := withPayments reclaim.transaction [payment a.request.refundAddress (owed a)],
     expected := some "retract-refund-short" },
   { reclaim with
     story := "the registration cost cannot be omitted on retraction",
     transaction := withPayments reclaim.transaction
       [payment a.request.refundAddress (a.request.contents.lovelace - a.request.registrationCost)],
     expected := some "retract-refund-short" },
   { reclaim with
     story := "a retraction refund sent to another address is refused",
     transaction := withPayments reclaim.transaction
       [payment b.request.refundAddress a.request.contents.lovelace],
     expected := some "retract-refund-short" },
   { reclaim with
     story := "a retraction cannot carry the trie-ready tag out alive",
     transaction := withPayments { reclaim.transaction with trieReadyMint := [] }
       [{ payment a.request.refundAddress a.request.contents.lovelace with
         contents.trieReadyTags := a.request.contents.trieReadyTags }],
     expected := some "retract-tag-not-burned" },
   { reclaim with
     story := "a retraction cannot carry the application tag out alive",
     transaction := withPayments { reclaim.transaction with applicationMint := [] }
       [{ payment a.request.refundAddress a.request.contents.lovelace with
         contents.applicationTags := a.request.contents.applicationTags }],
     expected := some "retract-tag-not-burned" },
   { reclaim with
     story := "a retraction before the reclaim window is refused",
     transaction.transaction.validity := some ⟨111, 113⟩, expected := some "retract-window" },
   { reclaim with
     story := "a retraction starting at the reclaim end is refused",
     transaction.transaction.validity := some ⟨117, 118⟩, expected := some "retract-window" },
   { reclaim with
     story := "a retraction extending past the reclaim end is refused",
     transaction.transaction.validity := some ⟨116, 118⟩, expected := some "retract-window" },
   { reclaim with
     story := "an empty retraction interval is refused",
     transaction.transaction.validity := some ⟨113, 113⟩, expected := some "retract-interval-empty" },
   { reclaim with
     story := "a retraction without an interval is refused",
     transaction.transaction.validity := none, expected := some "retract-interval-missing" },
   { reclaim with
     story := "a retraction without the refund address signature is refused",
     transaction.transaction.signers := [b.request.refundAddress], expected := some "retract-owner" },
   { reclaim with
     story := "an untagged output is not a pending retraction",
     transaction.transaction.inputs := [RejectionReadControls.input ⟨73, 0⟩],
     expected := some "retract-request-not-pending" },
   { reclaim with
     story := "a termination cannot be retracted",
     transaction.transaction.inputs := [RejectionReadControls.input ⟨72, 0⟩],
     expected := some "retract-registration-only" },
   { reclaim with
     story := "a retraction cannot spend one request twice",
     transaction.transaction.inputs := reclaim.transaction.transaction.inputs ++
       reclaim.transaction.transaction.inputs, expected := some "retract-duplicate-input" },
   { reclaim with
     story := "a retraction cannot consume the state",
     transaction.transaction.inputs := stateInput :: reclaim.transaction.transaction.inputs,
     expected := some "retract-state-spent" },
   { reclaim with
     story := "a retraction cannot read the state",
     transaction.transaction.referenceInputs := [stateInput], expected := some "retract-state-read" }]

/-- Judge every recorded transaction through the economic exit. A payment's
purpose is not observable: all lovelace at an address contributes to its floor. -/
def run : IO (List Lean.Json) := do
  let w ← match world with
    | .error why => throw (IO.userError s!"refund booking trace failed: {why}")
    | .ok w => pure w
  let a := registration 6 1 42
  let c := registration 10 4 42
  let amount := a.request.contents.lovelace - a.request.declaredTip
  let otherPurpose := { payment a.request.refundAddress 1 with output.role := .destination }
  let extra := [
    rejection w "separate outputs at one address contribute once each" [a, c]
      [payment a.request.refundAddress amount, payment a.request.refundAddress amount] none,
    rejection w "a payment for another purpose at the refund address counts as received" [a]
      [payment a.request.refundAddress (amount - 1), otherPurpose] none,
    rejection w "another address's payment cannot repair a short refund" [a]
      [payment a.request.refundAddress (amount - 1), payment 99 100] (some "reject-refund-short") ]
  let mut rows := []
  for row in controls w ++ extra do
    let result := if row.retract then retractionAccepted row.world row.unspent row.transaction
      else rejectionAccepted row.world row.unspent
        ⟨row.transaction, RejectionReadControls.stateReference, row.members⟩
    let actual := match result with | .error why => some why | .ok _ => none
    unless actual == row.expected do
      throw (IO.userError s!"{row.story}: expected {repr row.expected}, actual {repr actual}")
    if let .ok after := result then
      unless after.registry == row.world.registry && after.terminations == row.world.terminations do
        throw (IO.userError s!"{row.story}: registry or terminations changed")
      let consumed := if row.retract then 1 else row.members.length
      unless after.pending.length + consumed == row.world.pending.length do
        throw (IO.userError s!"{row.story}: request not removed exactly once")
    rows := rows ++ [Lean.Json.mkObj [
      ("story", Lean.toJson row.story), ("expectedReason", Lean.toJson row.expected),
      ("actualReason", Lean.toJson actual), ("matched", Lean.toJson (actual == row.expected))]]
  let first := retraction w
  let after ← match retractionAccepted w first.unspent first.transaction with
    | .error why => throw (IO.userError s!"retraction replay setup failed: {why}")
    | .ok after => pure after
  let updated := applyEconomicTransaction first.unspent first.transaction
  let again := { first.transaction with identity := first.transaction.identity + 1 }
  let actual := match retractionAccepted after updated again with
    | .error why => some why | .ok _ => none
  unless actual == some "spent-input-missing" do
    throw (IO.userError s!"second retraction: expected spent-input-missing, actual {repr actual}")
  rows := rows ++ [Lean.Json.mkObj [
    ("story", Lean.toJson "a second retraction of the same request is refused"),
    ("expectedReason", Lean.toJson (some "spent-input-missing")),
    ("actualReason", Lean.toJson actual), ("matched", Lean.toJson true)]]
  pure rows

end RefundControls
