import Lean

/-! The ledger boundary, independently of any application. Values retain signed
asset entries; quantities are their sums. No cryptographic or acceptance law is
built into these data types. -/

namespace CardanoLedger

abbrev Bytes := List UInt8
abbrev ScriptHash := Bytes
abbrev KeyHash := Bytes
abbrev PolicyId := ScriptHash
abbrev AssetName := Bytes

def AssetName.valid (name : AssetName) : Prop := name.length ≤ 32

structure AssetClass where
  policy : PolicyId
  name : AssetName
  deriving BEq, DecidableEq, Repr

abbrev Assets := List (AssetClass × Int)

def Assets.quantity (assets : Assets) (asset : AssetClass) : Int :=
  (assets.map fun entry => if entry.1 = asset then entry.2 else 0).sum

def Assets.moves (assets : Assets) (policy : PolicyId) : Bool :=
  assets.any fun entry => entry.1.policy == policy && entry.2 != 0

def Assets.onlyBurns (assets : Assets) (policy : PolicyId) : Bool :=
  assets.moves policy && assets.all fun entry =>
    entry.1.policy != policy || entry.2 ≤ 0

structure Value where
  lovelace : Nat
  assets : Assets
  deriving BEq, DecidableEq, Repr

inductive Credential where
  | key (hash : KeyHash)
  | script (hash : ScriptHash)
  deriving BEq, DecidableEq, Repr

structure Address where
  payment : Credential
  stake : Option Credential
  deriving BEq, DecidableEq, Repr

structure OutputRef where
  transaction : Bytes
  index : Nat
  deriving BEq, DecidableEq, Repr

structure Output (Datum : Type) where
  address : Address
  value : Value
  datum : Option Datum
  deriving BEq, DecidableEq

structure Input (Datum : Type) where
  reference : OutputRef
  resolved : Output Datum
  deriving BEq, DecidableEq

structure Withdrawal where
  account : Credential
  amount : Nat
  deriving BEq, DecidableEq, Repr

structure Certificate where
  credential : Credential
  action : Nat
  deriving BEq, DecidableEq, Repr

inductive Purpose where
  | spend (reference : OutputRef)
  | mint (policy : PolicyId)
  | withdraw (account : Credential)
  | certify (index : Nat)
  deriving BEq, DecidableEq, Repr

structure Tx (Datum Redeemer Script : Type) where
  inputs : List (Input Datum)
  referenceInputs : List (Input Datum)
  outputs : List (Output Datum)
  mint : Assets
  withdrawals : List Withdrawal
  certificates : List Certificate
  redeemers : List (Purpose × Redeemer)
  scripts : List Script
  signatories : List KeyHash
  validFrom : Option Nat
  validTo : Option Nat
  deriving BEq, DecidableEq

def Tx.redeemerOf (tx : Tx D R S) (purpose : Purpose) : Option R :=
  ((tx.redeemers.find? fun entry => entry.1 == purpose)).map Prod.snd

def Credential.scriptHash : Credential → Option ScriptHash
  | .key _ => none
  | .script hash => some hash

/-- Every invocation carries its own hash. Repeated input references do not
silently erase an invocation; ledger input uniqueness is a separate law. -/
def Tx.invocations (tx : Tx D R S) : List (Purpose × ScriptHash) :=
  tx.inputs.filterMap (fun input => input.resolved.address.payment.scriptHash.map
      fun hash => (.spend input.reference, hash)) ++
    ((tx.mint.map fun entry => entry.1.policy).eraseDups.filter tx.mint.moves).map
      (fun policy => (.mint policy, policy)) ++
    tx.withdrawals.filterMap (fun withdrawal => withdrawal.account.scriptHash.map
      fun hash => (.withdraw withdrawal.account, hash)) ++
    (tx.certificates.zipIdx.flatMap fun entry =>
      entry.1.credential.scriptHash.toList.map fun hash => (.certify entry.2, hash))

def Tx.invoked (tx : Tx D R S) : List Purpose := tx.invocations.map Prod.fst

def Tx.purposeHash (tx : Tx D R S) (purpose : Purpose) : Option ScriptHash :=
  ((tx.invocations.find? fun entry => entry.1 == purpose)).map Prod.snd

def Purpose.isStaking : Purpose → Bool
  | .withdraw _ | .certify _ => true
  | _ => false

def Output.withoutStaking (output : Output D) : Output D :=
  { output with address := { output.address with stake := none } }

def Input.withoutStaking (input : Input D) : Input D :=
  { input with resolved := input.resolved.withoutStaking }

def Tx.withoutStaking (tx : Tx D R S) : Tx D R S :=
  { tx with inputs := tx.inputs.map Input.withoutStaking
            referenceInputs := tx.referenceInputs.map Input.withoutStaking
            outputs := tx.outputs.map Output.withoutStaking
            withdrawals := [], certificates := []
            redeemers := tx.redeemers.filter fun entry => !entry.1.isStaking }

structure ScriptContext (Datum Redeemer Script : Type) where
  purpose : Purpose
  redeemer : Redeemer
  tx : Tx Datum Redeemer Script

structure Ledger (Datum Redeemer Script : Type) where
  hash : Script → ScriptHash
  evaluate : Script → ScriptContext Datum Redeemer Script → Bool
  accepts : Tx Datum Redeemer Script → Prop

end CardanoLedger
