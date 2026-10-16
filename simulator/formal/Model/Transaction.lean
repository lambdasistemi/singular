import Singular.Model.Registry
import Singular.Model.Assets

/-! Transaction inputs, outputs and their roles. -/

namespace Singular
open Lean

/-- The part an input or output plays in a fold transaction. `witness` is the
UTxO a requester holds a witness token at: the place an active or terminal token
lives between the fold that minted it and the fold that consumes it. `owner` is
an output paying a request's owner back. -/
inductive TxRole where
  | state | request | destination | cage | witness | owner
  deriving Repr, BEq, DecidableEq

/-- An input the fold spends: the registry's state UTxO, a request UTxO carrying
its approvals and the lovelace that pays the tip, or a UTxO holding a token the
fold destroys. `assets` is what the input brings in, so a burn has a source and
not merely a negative number in the mint. -/
structure TxInput where
  role : TxRole
  datum : DatumForm
  stateTokens : Nat
  approvals : Nat
  lovelace : Nat
  assets : List (Asset × Int) := []
  /-- The datum value the input's inline datum presents, for a witness. -/
  datumValue : Option Nat := none
  ref : Option OutRef := none
  stateToken : Option TokenId := none
  deriving BEq, DecidableEq

/-- An output the fold produces. `address` is `none` for the state output: the
model has no vocabulary for the registry's own address, and a constant invented
here would be exactly the kind of non-derivation this section exists to remove.
`commitment` is the hash the inline destination datum presents. -/
structure TxOutput where
  role : TxRole
  datum : DatumForm
  address : Option Nat
  stateTokens : Nat
  config : Option Config
  commitment : Option Nat
  assets : List (Asset × Int)
  /-- Ordered logical fields of the custody datum; `[refundAddress]` is the
  refund-only payload. This models field shape, not ledger serialization. -/
  custodyDatum : Option (List Nat) := none
  lovelace : Nat := 0
  /-- The output reference the output's inline datum presents: a retraction's
  return names the request it retracts by it. -/
  reference : Option Nat := none
  /-- The datum value the output's inline datum presents, for a destination
  output: the request's own datum. -/
  datumValue : Option Nat := none
  stateToken : Option TokenId := none
  deriving BEq, DecidableEq

/-- Recover custody identity from one absent asset of quantity one. Neither
the datum nor the request can supply a fallback key. -/
def custodyKey (o : TxOutput) : Option Key :=
  match o.assets with
  | [((.absent, key), 1)] => some key
  | _ => none

/-- The transaction of an admitted fold. -/
structure Tx where
  inputs : List TxInput
  outputs : List TxOutput
  mint : List (Asset × Int)
  signers : List Nat
  refunds : List (Nat × Nat)
  referenceInputs : List TxInput := []
  validity : Option Interval := none
  fee : Nat := 0
  donation : Nat := 0
  deriving BEq, DecidableEq

end Singular
