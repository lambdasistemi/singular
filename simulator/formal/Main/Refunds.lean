import Main.RejectionReadsState

/-! Transactions for the economic refund contract. Each world is produced by
the real booking functions. Amounts are illustrative, not ledger measurements.
The initial control runner records missing retraction admission separately;
the historical test commit preserves that pre-implementation evidence. -/

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

/-- Run every evaluable row rather than stopping after the first mismatch.
No legacy retraction substitutes for the missing economic judgement. -/
def runRed : IO Unit := do
  let w ← match world with
    | .error why => throw (IO.userError s!"refund booking trace failed: {why}")
    | .ok w => pure w
  let mut failed := 0
  let mut unavailable := 0
  for row in controls w do
    if row.retract then
      unavailable := unavailable + 1
      IO.println s!"COULD-NOT-EVALUATE: {row.story}; expected={repr row.expected}; economic retraction judgement absent"
    else
      let actual := match rejectionAccepted row.world row.unspent
          ⟨row.transaction, RejectionReadControls.stateReference, row.members⟩ with
        | .error why => some why | .ok _ => none
      let matched := actual == row.expected
      unless matched do failed := failed + 1
      IO.println s!"{if matched then "PASS" else "FAIL"}: {row.story}; expected={repr row.expected}; actual={repr actual}"
  IO.println "COULD-NOT-EVALUATE: a second retraction of the same request is refused; requires the first accepted economic retraction and its unspent update"
  unavailable := unavailable + 1
  IO.println s!"refund controls: mismatches={failed}; could-not-evaluate={unavailable}"
  unless failed == 0 && unavailable == 0 do
    throw (IO.userError "economic refund contract is not implemented")

end RefundControls
