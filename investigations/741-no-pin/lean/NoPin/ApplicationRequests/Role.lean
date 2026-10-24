import NoPin.ApplicationRequests.Conditions

/-! Hypotheses under #741, not accepted law. Finite role premises distinguish
structured encoding from collision freedom and require both occurring preimages. -/
namespace NoPin.ApplicationRequests
open Singular Lean

/-- Hypothesis under #741, not accepted law; actual state and active role occurrences. -/
def roleDomain (q : Query) : List Preimage :=
  [.state q.seed, .active q.observation.before.identity q.action.key]
/-- Hypothesis under #741, not accepted law; no global cryptographic axiom. -/
def RolePremises (hash : Hash) (code : Codec) (q : Query) : Prop :=
  FiniteEncoding code (roleDomain q) ∧ FiniteCollisionFree hash code (roleDomain q) ∧
  q.output.assets = [(activeAsset hash code q.observation.before.identity q.action.key, 1)]
/-- Hypothesis under #741, not accepted law; minted-token companion binds a real accepted fold. -/
def MintedRolePremises (hash : Hash) (code : Codec) (commit : TrieCommit) (q : Query) : Prop :=
  RolePremises hash code q ∧ fold .none hash code commit q.release q.observation = true ∧
  NoPin.mintQty q.observation.assets
    (activeAsset hash code q.observation.before.identity q.action.key) > 0

/-- Hypothesis under #741, not accepted law; authenticity, phases and ordinary funding, never fold success. -/
def PublicPremises (hash : Hash) (code : Codec) (commit : TrieCommit) (q : Query) : Prop :=
  PublicFoldPremises hash code commit (queryDecode q) q.release q.observation.before q.requests q.funding ∧
  q.release.applicationPolicy ≠ q.release.statePolicy ∧
  FiniteEncoding code (publicDomain q) ∧ FiniteCollisionFree hash code (publicDomain q)
/-- Hypothesis under #741, not accepted law; constructed public fold, empty signers and actual balance. -/
abbrev PublicConclusion (mutation : Mutation) (hash : Hash) (code : Codec) (commit : TrieCommit) (q : Query) : Prop :=
  let observation := buildFold hash code commit q.release q.observation.before q.requests q.funding
  fold mutation hash code commit q.release observation = true ∧ observation.signers = [] ∧
  observation.assets.spent = (q.observation.before.state :: q.requests.map PendingRequest.output ++
    [q.funding.ordinaryInput]).map (·.reference) ∧
  observedBalance observation.spentOutputs observation.outputs observation.fee observation.donation = true

end NoPin.ApplicationRequests
