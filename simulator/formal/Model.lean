import Singular.Model.Fold
import Singular.Model.Routing
import Singular.Model.Payments
import Singular.Model.Exits
import Singular.Model.Admission
import Singular.Model.Request
import Singular.Model.Transaction
import Singular.Model.Booking

/-! The registry-mode logical model: the trie answers two questions and nothing
else — is this key known, and where in its life is it.

`Leaf ::= Unknown | Known State` with `State ::= Absent | Active | Terminal`.
Seven edge encodings retain their original ordinals. Only registration
(`insertActive`) and permanent retirement (`updateTerminal`) can succeed.
Both require a tuple-bound approval under the pinned application policy;
the other five encodings are refused before approval or trie effects. The
fold sums admitted keyed deltas and refuses a different claimed mint.


Tagged commitments stand for collision-free canonical commitments; the trie is
an authenticated logical map whose root is derived from its content, and an
approval's asset name is a canonical commitment over the tuple it scopes. The
executable consumer supplies the real hashes; the model fixes the complete
preimages. Contract evidence is supplied, not verified application code. A
selected batch is atomic and never skips failures. This is an explicit model
profile, not a ruling on batch construction. -/

namespace Singular
open Lean

/-! The oracle observation surface. Ten total observations under
`Singular.Oracle` — the contract the frozen gate oracle reads. Each is defined
in terms of the real model: they delegate to it, or execute it, never restate
it. A surface that hard-coded answers while the model did something else is the
defect the mutation ledger exists to catch. -/

namespace Oracle

/-- The four admission cases the oracle distinguishes. `mismatched` is an
approval under the correct pinned policy whose `(edge, key, owner, destination)`
tuple does not match — the case that makes approval-asset-binding observable. -/
inductive Approval where
  | none | application | other | mismatched
  deriving Repr, BEq, DecidableEq

/-- Where a minted token goes. -/
inductive Destination where
  | requestOutput
  deriving Repr, BEq, DecidableEq

/-- The reference configuration the observation surface pins: the oracle's
`application` case is an approval minted under this configuration's pinned
application policy. -/
def referenceConfig : Config :=
  { root := rootOf [], minimumTip := 0, processTime := 0, retractTime := 0
  , applicationPolicy := 7, activePolicy := 8 }

/-- A well-formed approval under the reference policy, scoped exactly to the
canonical request of the edge. -/
def canonicalApproval (e : Edge) : Singular.Approval :=
  let r := canonicalRequest e
  { policy := referenceConfig.applicationPolicy, edge := e, key := r.key
  , owner := r.owner, destination := requestDestination r
  , assetName := approvalAssetName e r.key r.owner (requestDestination r) }

/-- The oracle's approval vocabulary, translated into real approvals:
`application` matches the canonical request, `other` carries a foreign policy,
`mismatched` carries the right policy but a perturbed key with an asset name
that binds the wrong tuple — well-formed, and wrong. -/
def toApproval (e : Edge) : Approval → Option Singular.Approval := fun
  | .none => none
  | .application => some (canonicalApproval e)
  | .other =>
    let ap := canonicalApproval e
    some { ap with policy := referenceConfig.applicationPolicy + 100 }
  | .mismatched =>
    let r := canonicalRequest e
    let ap := canonicalApproval e
    let perturbed := approvalAssetName e (r.key + 1) r.owner (requestDestination r)
    some { ap with key := r.key + 1, assetName := perturbed }

/-- The seven-edge from→to column, observed. -/
def transition (e : Edge) (before : Leaf) : Option Leaf :=
  Singular.transition e before

/-- Every delta cell, total: a kind the edge does not move is `0`. -/
def delta (e : Edge) (k : TokenKind) : Int :=
  deltaKind (Singular.delta e) k

/-- The leaf codec, one way. -/
def encode (s : State) : List UInt8 := (encodeState s).toList

/-- The leaf codec, the other way, including bytes that must not decode. -/
def decode (bytes : List UInt8) : Option State := decodeState bytes.toByteArray

/-- Admission for all four approval cases (approval-admission, application-decides-absence-booking and approval-asset-binding), answered
by the real per-request decision at the edge's canonical request. -/
def admits (e : Edge) (a : Approval) : Bool :=
  admitsFor referenceConfig (canonicalRequest e) (toApproval e a)

/-- Routing (token-routing, value-routing), observed. -/
def route (k : TokenKind) : Destination :=
  match Singular.route k (canonicalRequest .insertActive) with
  | .requestOutput => .requestOutput

end Oracle

end Singular
