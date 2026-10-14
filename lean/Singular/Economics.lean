import Singular.Model
import Singular.Economics.Booking
import Singular.Economics.World

/-! Transaction accounting over the unspent outputs. These definitions do not
admit transactions: presence, balance and disjointness are separate judgements.
The caller supplies a fresh transaction identity when applying a transaction. -/

namespace Singular

/-- The unspent set, represented by output references and their outputs.
Ledger states have distinct references; the representation does not manufacture
validity for an arbitrary list. -/
abbrev Utxo := List (OutRef × TxOutput)

def inputsContainReference (inputs : List TxInput) (ref : OutRef) : Bool :=
  inputs.any fun i => decide (i.ref = some ref)

/-- Reference reads are disjoint from the outputs the transaction spends. -/
def disjointInputs (tx : Tx) : Bool :=
  tx.referenceInputs.all fun i =>
    match i.ref with
    | none => true
    | some ref => !inputsContainReference tx.inputs ref

def inputPresent (u : Utxo) (i : TxInput) : Bool :=
  match i.ref with
  | none => false
  | some ref => u.any fun p => decide (p.1 = ref)

/-- Presence only, spent inputs first. A missing reference is not a missing
spending input; neither judgement trusts a value claimed by an input. -/
def inputPresenceRefusal (u : Utxo) (tx : Tx) : Option String :=
  if !(tx.inputs.all (inputPresent u)) then some "spent-input-missing"
  else if !(tx.referenceInputs.all (inputPresent u)) then some "reference-input-missing"
  else none

/-- Raw ledger update: spending removes an output even if also referenced.
Reference preservation requires disjointInputs. The new transaction identity
must be fresh; admission and identity allocation are outside this raw update. -/
def applyTx (u : Utxo) (identity : Nat) (tx : Tx) : Utxo :=
  u.filter (fun p => !inputsContainReference tx.inputs p.1) ++
    tx.outputs.zipIdx.map (fun (output, index) => (⟨identity, index⟩, output))

/-- Read the spent values from the set, once per set entry. Duplicate claims
in the spending list cannot multiply the value available for accounting. -/
def spentOutputs (u : Utxo) (tx : Tx) : List TxOutput :=
  (u.filter fun p => inputsContainReference tx.inputs p.1).map Prod.snd

def outputLovelace (outputs : List TxOutput) : Nat := (outputs.map (·.lovelace)).sum
def outputAssets (outputs : List TxOutput) : List (Asset × Int) := outputs.flatMap (·.assets)

/-- None is the legacy anonymous state-token identity. It remains separate from
every exact policy/name pair, so an identified token cannot be exchanged for it. -/
def stateTokenValue (outputs : List TxOutput) (token : Option TokenId) : Nat :=
  ((outputs.filter fun o => decide (o.stateToken = token)).map (·.stateTokens)).sum

def stateTokenSupport (before after : List TxOutput) : List (Option TokenId) :=
  before.map (·.stateToken) ++ after.map (·.stateToken)

/-- Conservation of lovelace, every registry-scoped native asset and every
state-token identity present on either side. References contribute no value;
fees and donations account for all lovelace not returned through outputs. -/
def balanced (u : Utxo) (tx : Tx) : Bool :=
  let spent := spentOutputs u tx
  outputLovelace spent == outputLovelace tx.outputs + tx.donation + tx.fee &&
  assetSame (outputAssets spent ++ tx.mint) (outputAssets tx.outputs) &&
  (stateTokenSupport spent tx.outputs).all fun token =>
    stateTokenValue spent token == stateTokenValue tx.outputs token

end Singular
