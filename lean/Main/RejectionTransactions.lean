import Main.RejectionReadsState

/-! Adversarial transaction observations and repeated tag identities. These
controls execute admission, not a builder or a source-text surrogate. -/

open Singular

namespace RejectionReadControls

structure TransactionControl where
  story : String
  world : World
  unspent : EconomicUtxo
  rejection : Rejection
  expected : Option String

def transactionControls (w : World) : List TransactionControl :=
  let row := lawful w "mismatch" [registration 5 0]
    [.mismatch (trieGet w.registry.trie 5)] ⟨102, 103⟩
  let u := observedUnspent w row.unspent
  let r : Rejection := ⟨observedTransaction row, stateReference, row.members⟩
  let control (story : String) (r : Rejection) (expected : Option String) : TransactionControl :=
    ⟨story, w, u, r, expected⟩
  let changedOutput (f : EconomicOutput → EconomicOutput) :=
    u.map fun (ref, o) => (ref, if ref = (registration 5 0).request.reference then f o else o)
  let early := lawful w "one instant before expiry" [registration 6 1] [.expired] ⟨116, 117⟩
  [control "one instant before expiry is too early"
      ⟨observedTransaction early, stateReference, early.members⟩ (some "reject-not-expired"),
   control "a forged lifecycle leaf cannot justify mismatch"
      { r with
        members := [(⟨71, 0⟩, .mismatch .unknown)] } (some "reject-evidence-mismatch"),
   control "an absent validity interval is refused"
      { r with
        transaction.transaction.validity := none } (some "reject-interval-missing"),
   control "an empty validity interval is refused"
      { r with
        transaction.transaction.validity := some ⟨103, 103⟩ } (some "reject-interval-empty"),
   control "an empty batch is refused"
      { r with
        members := [], transaction.transaction.inputs := [] } (some "reject-empty-batch"),
   control "an unrelated spending input cannot join a rejection"
      { r with
        transaction.transaction.inputs := input ⟨73, 0⟩ :: r.transaction.transaction.inputs }
      (some "reject-input-members"),
   control "a state claimed as an ordinary request is still a state spend"
      { r with
        transaction.transaction.inputs := input stateReference :: r.transaction.transaction.inputs,
        transaction.transaction.referenceInputs := [] } (some "reject-state-spent"),
   control "a transaction cannot reuse an unspent creating identity"
      { r with
        transaction.identity := 71 } (some "transaction-identity-not-fresh"),
   { control "duplicate unspent references are refused" r (some "unspent-reference-duplicate") with
      unspent := u ++ u },
   { control "a claimed request value cannot replace the observed value" r
       (some "request-observation-mismatch") with
      unspent := changedOutput fun o => { o with output.lovelace := 999 } },
   { control "a request datum changed after booking is refused" r
       (some "request-observation-mismatch") with
      unspent := changedOutput fun o => { o with request := none } },
   control "missing trie-ready burns are refused"
      { r with
        transaction.trieReadyMint := [] } (some "reject-tag-not-burned"),
   control "a positive tag mint cannot pretend to be a burn"
      { r with
        transaction.trieReadyMint := row.trieReadyBurns.map (·, 1) }
      (some "reject-tag-not-burned"),
   control "a burn of another token cannot discharge the member"
      { r with
        transaction.trieReadyMint := [(⟨999, 1⟩, -1)] } (some "reject-tag-not-burned"),
   control "an extra tag burn without a consumed source is refused"
      { r with
        transaction.trieReadyMint := (⟨999, 1⟩, -1) :: r.transaction.trieReadyMint }
      (some "reject-tag-not-burned"),
   control "a state token cannot be minted alongside a rejection"
      { r with
        transaction.stateMint := [(config.stateToken, 1)] } (some "reject-registry-supply"),
   control "a singular token cannot be minted alongside a rejection"
      { r with
        transaction.singularMint := [(config.singularTag 5, 1)] }
      (some "reject-registry-supply"),
   control "the legacy keyed mint cannot hide singular creation"
      { r with
        transaction.transaction.mint := [((.active, 5), 1)] }
      (some "reject-registry-supply")]

def runTransactionControls : IO (List Lean.Json) := do
  let w ← match world with
    | .error why => throw (IO.userError s!"booking trace: {why}")
    | .ok w => pure w
  let original := registration 5 3
  let evidence := original.request.contents.applicationTags.map fun tag =>
    { tag with signatures := [[7]] }
  let second := { original with
    request.contents.applicationTags := evidence, applicationTagsMinted := evidence }
  let collisionWorld ← match book w second with
    | .error why => throw (IO.userError s!"second same-tag booking: {why}")
    | .ok w => pure w
  let row := lawful collisionWorld "two requests with the same tag identities"
    [registration 5 0, second] [.mismatch (.known .active), .mismatch (.known .active)] ⟨102, 103⟩
  let collision : Rejection := ⟨observedTransaction row, stateReference, row.members⟩
  let collisionInputs := observedUnspent collisionWorld (unspent collisionWorld)
  let missingBurn := { collision with transaction.trieReadyMint :=
    (registration 5 0).request.contents.trieReadyTags.map (·, -1) }
  let aggregated := { collision with
    transaction.trieReadyMint := (registration 5 0).request.contents.trieReadyTags.map (·, -2),
    transaction.applicationMint := (registration 5 0).request.contents.applicationTags.map
      (fun tag => (applicationTagIdentity tag, -2)) }
  let rows := transactionControls w ++ [
    ⟨"two equal tag names require both quantities to burn", collisionWorld, collisionInputs,
      collision, none⟩,
    ⟨"one quantity-two burn discharges equal assets with different authorization evidence",
      collisionWorld, collisionInputs, aggregated, none⟩,
    ⟨"one burn cannot discharge two equal tag names", collisionWorld, collisionInputs,
      missingBurn, some "reject-tag-not-burned"⟩]
  let mut output := []
  for row in rows do
    let actual := match rejectionAccepted row.world row.unspent row.rejection with
      | .error why => some why | .ok _ => none
    unless actual == row.expected do
      throw (IO.userError s!"{row.story}: expected {repr row.expected}, actual {repr actual}")
    output := output ++ [Lean.Json.mkObj [
      ("story", Lean.toJson row.story), ("expectedReason", Lean.toJson row.expected),
      ("actualReason", Lean.toJson actual), ("matched", Lean.toJson (actual == row.expected))]]
  pure output

end RejectionReadControls
