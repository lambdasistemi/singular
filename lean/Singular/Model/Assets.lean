import Singular.Model.Primitives

/-! Keyed asset quantities and their sums. -/

namespace Singular
open Lean

/-- Sum a delta list along one token kind. -/
def deltaKind (ds : List (TokenKind × Int)) (k : TokenKind) : Int :=
  ds.foldl (fun n p => if p.1 == k then n + p.2 else n) 0

/-- A minted asset's identity: the token kind and the key the token is about.
On chain it is `(policy of the kind, asset name)`; the model pins the asset name
to the key, so the pair `(kind, key)` names the asset exactly. Mint accounting
is by this pair and never by the kind alone: two keys of one kind are two
different assets, and a fold that swapped them would balance per kind. -/
abbrev Asset := TokenKind × Key

/-- Sum a keyed delta list along one asset. -/
def assetKind (ds : List (Asset × Int)) (x : Asset) : Int :=
  ds.foldl (fun n p => if p.1 == x then n + p.2 else n) 0

/-- Merge two keyed delta lists into their per-asset sum. -/
def assetPlus (a b : List (Asset × Int)) : List (Asset × Int) :=
  ((a.map Prod.fst ++ b.map Prod.fst).eraseDups).map fun x =>
    (x, assetKind a x + assetKind b x)

/-- Two keyed delta lists carry the same per-asset sums. -/
def assetSame (a b : List (Asset × Int)) : Bool :=
  (a.map Prod.fst ++ b.map Prod.fst).all fun x => assetKind a x == assetKind b x

/-- The per-kind total of a keyed delta list: the coarser accounting the keyed
one refines. Two lists can agree at every kind and still differ at an asset,
which is exactly the fault `assetSame` catches and a per-kind sum does not. -/
def assetKindTotal (ds : List (Asset × Int)) (k : TokenKind) : Int :=
  ds.foldl (fun n p => if p.1.1 == k then n + p.2 else n) 0

end Singular
