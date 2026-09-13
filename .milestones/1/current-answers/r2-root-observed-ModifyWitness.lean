import SingularBlaster.EndWitness

namespace SingularBlaster.ModifyWitness

/-! Honest ownerless `Modify` fold (slice 1, snapshot at `5bd7c79`).

Single honest `Update` fold, permissionless (empty signatories): one `Update` inserting
key `0x6162` → value `0x6364` into the empty trie with the empty proof, per MPF vector
#1. Requires the hashing-capable tuple (`ed3126b` dispatches `blake2b_256`): at the
previous pin the run ERRORed on the dispatch refusal (preserved in history).

Why this shape: `Update` with a library-vector proof exercises the real fold path
(`mpf.insert`, root advancement, token preservation) with zero proof invention. The
request carries no ADA (`quantity_of` defaults absent to 0), so no owners accrue and
the refund sub-checks are inert — recorded, not hidden. `mint` is empty, so both
mint-witness implications are vacuous for this single-script run; the multi-validator
mint span stays debt (see `MAPPING.md`).

Out-of-domain guard: the malformed-datum run must ERROR — it fails the
well-formedness predicate, so it is outside `fold_iff`'s domain (NOTE-001), never a
sufficiency violation.

Validity range is hand-built Plutus-interval `Data` (Aiken-convention constructors);
the upper bound sits so far below `submitted_at + process_time` that the outcome is
robust to either `Bool` mapping — recorded in `MAPPING.md` as an open cross-check.
-/

open CardanoLedgerApi.V3 (ScriptContext ScriptInfo TxInfo TxInInfo)
open CardanoLedgerApi.V3.Tx (TxId TxOutRef)
open CardanoLedgerApi.V2.Tx (TxOut OutputDatum)
open CardanoLedgerApi.V1.Credential (Credential PubKeyHash)
open CardanoLedgerApi.V1.Address (Address)
open CardanoLedgerApi.IsData.Class (toTerm)
open PlutusCore.UPLC.CekMachine (cekExecuteProgramWithSemanticVariant State)
open PlutusCore.Data (Data)
open PlutusCore.Integer (Integer)
open PlutusCore.ByteString (ByteString)
open PlutusCore.UPLC.Term (Term Const)
open SingularBlaster.Scripts (targetSemVar)
open SingularBlaster.EndWitness (bs P_SCRIPT KEY_OWNER KEY_OTHER TOKEN_NAME ROOT_ZERO
  TXID_SELF TXID_CTX stateValue stateAddr noPrevPolicies outcome selfRef)

def REQ_KEY : ByteString := bs [0x61, 0x62]
def REQ_VAL : ByteString := bs [0x63, 0x64]
def NEW_ROOT : ByteString :=
  bs [0x57, 0x74, 0x71, 0x0a, 0x44, 0x57, 0xe5, 0x0a, 0x5a, 0x2f, 0xf1, 0xfe,
      0x61, 0x49, 0x39, 0x86, 0x17, 0xc8, 0x95, 0xdd, 0x3f, 0xbd, 0x3b, 0xd8,
      0xca, 0xc5, 0x1e, 0xcc, 0x57, 0x1f, 0x93, 0x19]
def TIP : Integer := 500
def SUBMITTED : Integer := 1000
def PROC_TIME : Integer := 2000
def RETRACT_TIME : Integer := 1000

/-- `StateDatum(State{owner, None, zeros, 500, 2000, 1000})`. -/
def foldDatum (root : ByteString) : Data :=
  Data.Constr 1 [Data.Constr 0
    [ Data.B KEY_OWNER
    , Data.Constr 1 []
    , Data.B root
    , Data.I TIP
    , Data.I PROC_TIME
    , Data.I RETRACT_TIME
    ]]

/-- `RequestDatum(Request{token, other, 0x6162, Insert(0x6364), 500, 1000})`. -/
def foldRequest : Data :=
  Data.Constr 0 [Data.Constr 0
    [ Data.Constr 0 [Data.B TOKEN_NAME]
    , Data.B KEY_OTHER
    , Data.B REQ_KEY
    , Data.Constr 0 [Data.B REQ_VAL]
    , Data.I TIP
    , Data.I SUBMITTED
    ]]

/-- `Modify([UpdateAction([])])`: `Modify` = `Constr 2`, `UpdateAction` = `Constr 0`,
empty `Proof` = empty step list. -/
def foldRedeemer : Data :=
  Data.Constr 2 [Data.List [Data.Constr 0 [Data.List []]]]

/-- Validity range entirely before `SUBMITTED + PROC_TIME` = 3000: upper `Finite 1000`.
Margin makes the outcome robust to either `Bool` mapping (see file doc). -/
def foldRange : Data :=
  Data.Constr 0
    [ Data.Constr 0 [Data.Constr 0 [], Data.Constr 0 []]
    , Data.Constr 0 [Data.Constr 1 [Data.I 1000], Data.Constr 0 []]
    ]

def reqRef : TxOutRef := ⟨TXID_SELF, (1 : Integer)⟩
def reqAddr : Address := ⟨.PubKeyCredential KEY_OTHER, none⟩
def reqOut : TxOut :=
  ⟨reqAddr, [], .OutputDatum foldRequest, none⟩

def foldStateOut : TxOut :=
  ⟨stateAddr, stateValue, .OutputDatum (foldDatum NEW_ROOT), none⟩

def foldStateIn : CardanoLedgerApi.V3.TxInInfo :=
  ⟨selfRef, ⟨stateAddr, stateValue, .OutputDatum (foldDatum ROOT_ZERO), none⟩⟩

def foldTxInfo (range : Data) : TxInfo :=
  ⟨ [foldStateIn, ⟨reqRef, reqOut⟩]
  , []
  , [foldStateOut]
  , (0 : Integer)
  , []
  , []
  , []
  , range
  , []
  , []
  , []
  , TXID_CTX
  , []
  , []
  , Data.Constr 0 []
  , Data.Constr 0 []
  ⟩

def foldCtx : ScriptContext :=
  ⟨foldTxInfo foldRange, foldRedeemer, .SpendingScript selfRef (some (foldDatum ROOT_ZERO))⟩

def runFold (ctx : ScriptContext) (steps : Nat) : State :=
  cekExecuteProgramWithSemanticVariant targetSemVar stateSpend.script
    [noPrevPolicies, toTerm ctx] steps

-- Honest ownerless fold HALTs on the hashing-capable tuple (`ed3126b` dispatches
-- `blake2b_256`, hash-verified against the independent python reference in the probe).
-- At the previous pin (`17cee18`, no crypto builtins) this run ERRORed on the dispatch
-- refusal — preserved in git history + EVIDENCE.md. Malformed datum ERRORs (out-of-domain).
/-- info: ("HALT", "ERROR") -/
#guard_msgs in
#eval (outcome (runFold foldCtx 100000),
       outcome (runFold ⟨foldTxInfo foldRange, foldRedeemer,
         .SpendingScript selfRef (some (Data.Constr 0 []))⟩ 100000))

/-- Rejectability range, robust under either `Bool` mapping: lower `Finite 5000` makes
`is_rejectable` pass via the entirely-after disjunct on both branches
(`3999 < 5000` and `3999 <= 5000`). Upper `PositiveInfinity`. -/
def rejectRange : Data :=
  Data.Constr 0
    [ Data.Constr 0 [Data.Constr 1 [Data.I 5000], Data.Constr 0 []]
    , Data.Constr 0 [Data.Constr 2 [], Data.Constr 0 []]
    ]

/-- `Modify([Rejected])`: `Rejected` = `Constr 1`, no fields. The `Rejected` path calls
only `is_rejectable` (interval ops, no hashing) and leaves the root unchanged — so this
run also settles the interval-decoder question for the `Update` run above (same decoder,
same `Data` shapes): a HALT here proves the `Update` ERROR is not an interval failure. -/
def rejectRedeemer : Data :=
  Data.Constr 2 [Data.List [Data.Constr 1 []]]

def rejectStateOut : TxOut :=
  ⟨stateAddr, stateValue, .OutputDatum (foldDatum ROOT_ZERO), none⟩

def rejectTxInfo : TxInfo :=
  ⟨ [foldStateIn, ⟨reqRef, reqOut⟩]
  , []
  , [rejectStateOut]
  , (0 : Integer)
  , []
  , []
  , []
  , rejectRange
  , []
  , []
  , []
  , TXID_CTX
  , []
  , []
  , Data.Constr 0 []
  , Data.Constr 0 []
  ⟩

def rejectCtxOut : ScriptContext :=
  ⟨rejectTxInfo, rejectRedeemer, .SpendingScript selfRef (some (foldDatum ROOT_ZERO))⟩

-- Honest ownerless rejection fold must HALT (no owner signature anywhere).
/-- info: "HALT" -/
#guard_msgs in
#eval outcome (runFold rejectCtxOut 100000)

-- R2-packet funded-reject leg (NOTE-024/NOTE-123): the same Rejected shape
-- with the request carrying 2,000,000 lovelace, so the refund sub-checks
-- execute for real instead of staying inert. `validModify` with one owner
-- and fee 0 demands `totalRefunded == 2,000,000 - 500 (tip)` exactly
-- (`owed = maxRefunded`), paid to the request owner (KEY_OTHER) after the
-- state output. Root stays zeros: consumption with refund, no registry
-- trace — the precise R2 divergence from the abstract model.
def rejectFundedReqOut : TxOut :=
  ⟨reqAddr
  , [(Data.B "", Data.Map [(Data.B "", Data.I 2000000)])]
  , .OutputDatum foldRequest, none⟩

def rejectFundedRefundOut : TxOut :=
  ⟨reqAddr
  , [(Data.B "", Data.Map [(Data.B "", Data.I 1999500)])]
  , .NoOutputDatum, none⟩

def rejectFundedTxInfo : TxInfo :=
  ⟨ [foldStateIn, ⟨reqRef, rejectFundedReqOut⟩]
  , []
  , [rejectStateOut, rejectFundedRefundOut]
  , (0 : Integer)
  , []
  , []
  , []
  , rejectRange
  , []
  , []
  , []
  , TXID_CTX
  , []
  , []
  , Data.Constr 0 []
  , Data.Constr 0 []
  ⟩

/-- info: "HALT" -/
#guard_msgs in
#eval outcome (runFold ⟨rejectFundedTxInfo, rejectRedeemer,
  .SpendingScript selfRef (some (foldDatum ROOT_ZERO))⟩ 100000)

end SingularBlaster.ModifyWitness
