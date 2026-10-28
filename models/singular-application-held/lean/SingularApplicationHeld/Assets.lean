import Singular.Model.Registry

/-! The application-held Singular model beside the current one, to be removed
with it in #743. -/

namespace SingularApplicationHeld.Assets
open Singular Lean

/-- minimal ledger-boundary observation. -/
structure TxOutput where
  assets : List (TokenId × Nat)
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- maps to future #679/#680 vocabulary, carries no laws. -/
structure TxView where
  spent : List OutRef
  outputs : List TxOutput
  mint : List (TokenId × Int)
  invoked : List Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- complete asset quantity observation. -/
def mintQty (tx : TxView) (asset : TokenId) : Int :=
  ((tx.mint.filter (fun entry => entry.1 == asset)).map (·.2)).sum
/-- explicit finite hash interpretation. -/
structure HashEntry where
  input : List Nat
  output : Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

end SingularApplicationHeld.Assets
