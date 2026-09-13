import SingularBlaster.AppliedCheck
import SingularBlaster.DdfcScripts
import SingularBlaster.EndWitness
import SingularBlaster.ModifyWitness
import SingularBlaster.DdfcParams

namespace SingularBlaster.DdfcSpan

/-! ddfc COMPONENT span (candidate `ddfc4e9`, accepted component — not final).

ONE composed transaction shape executed through THREE compiled programs, each
with its own purpose but sharing inputs/outputs/mint/redeemers:

- `state.spend Modify([UpdateAction([])])` (0-param `2bf61b…`): empty-trie
  insert `0x6162 → 0x6364` (mpf v2.0.0 both partitions — the snapshot
  `NEW_ROOT` is reused as the expected root, and the HALT confirms it),
  five-field datum with `representative_policy = 53828b96…` preserved;
- `representative MintRepresentative` (applied `53828b96…`, single arg):
  `exact_movement` mints the named representative exactly once, riding the
  application `Fold` named in `tx.redeemers`;
- `application.spend Fold([repName])` (0-param `52dbf57b…`): insert fold —
  the mechanically computed `insert_approval_name` burns exactly once,
  continuation carries the same record plus the representative under the
  EXPECTED policy read from the spent five-field state (E-001 binding).

No signatories anywhere (permissionless); the MPF request input carries no
lovelace, so the refund block is inert (`n = 0`).

Discrimination legs on datum-only / mint-only mutations of the same shape:
- foreign-policy mint (`e001_attacker` policy carrying the right name):
  application `Fold` ERRORs at the `representative-policy` mint-quantity
  check — sound now that the honest leg HALTs on the identical shape
  (only the mint policy differs). This IS the E-001 refusal, witnessed;
- state output datum with an altered `representative_policy`: `Modify`
  ERRORs at the preservation check (before root/refund checks);
- malformed state datum: ERROR (out-of-domain guard).

Stated limits (not hidden): C3/C4 discharge is recorded in EVIDENCE/MAPPING
against the declared grading (sameNet on the model representative asset;
MPF-root refinement stays stated R1-analog debt) — finite execution is
never quantified proof. `REQ_SCRIPT` address binding is untested at CEK
scope. First-failure untraced (no trace API).
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
open PlutusCore.UPLC.Term (Term Program Version Const)
open SingularBlaster.Scripts (targetSemVar)
open SingularBlaster.EndWitness (KEY_OTHER KEY_OWNER outcome ROOT_ZERO)
open SingularBlaster.ModifyWitness (REQ_KEY REQ_VAL NEW_ROOT foldRange)
open SingularBlaster.AppliedCheck (progParts verEq)
open SingularBlaster.DdfcParams (DDFC_STATE DDFC_APP DDFC_REP DDFC_FOREIGN
  SPAN_CONTROL SPAN_COMMIT SPAN_APPROVAL SPAN_REP SPAN_CAGE SPAN_H1 SPAN_H2 SPAN_REFUND
  DDFC_CUSTODY)

def ST_TXID : ByteString := ⟨String.mk ((List.replicate 32 0xD0).map Char.ofNat)⟩

/-- Ascending policy order (ledger `Value` maps are ascending; stdlib 2.2.0
`dict.do_get` early-exits `None` on descent — A-004, verified in the pinned
source). Order is COMPUTED here, never hand-arranged per variant (a hand-swap
fixes honest `5382` and breaks foreign `1ab2` — the trap A-004 names).
TRAP NEAR-MISS, OWNED 2026-09-12: the first version of this comparator
delegated to Lean `String.compare`, and the author (me) then "caught" it
red-handed ordering snapshot-`ce76` before `52db` — except the constant in
play was ddfc-`2bf6` (`0x2b < 0x52`, correctly true under every order).
The confusion was mine (snapshot vs ddfc bytes), not the library's; the
old comparator agreed with byte order on every in-play pair. Kept anyway:
char-level recursion is byte-exact BY CONSTRUCTION below 0x100 instead of
by trust in `String.compare` semantics above 0x80 (never verified in-lane).
Moral preserved from F-002: generate-or-verify mechanically — including
the verifier's own eyes. -/
def byteLt : List Char → List Char → Bool
  | [], [] => false
  | [], _ :: _ => true
  | _ :: _, [] => false
  | a :: as, b :: bs => a < b || (a == b && byteLt as bs)

def policyLt (a b : ByteString) : Bool :=
  byteLt a.data.toList b.data.toList

-- Unit guards on the exact policies in play (fail loudly if any hash moves).
-- All four are plain first-byte decisions (0x1a/0x2b/0x52/0x53).
/-- info: (true, false, true, true) -/
#guard_msgs in
#eval (policyLt DDFC_APP DDFC_REP,
       policyLt DDFC_REP DDFC_APP,
       policyLt DDFC_FOREIGN DDFC_APP,
       policyLt DDFC_STATE DDFC_APP)

/-- Map-order checker, both levels: outer policy keys strictly ascending
and every inner token map strictly ascending. Every mint/value fixture
below is asserted through this per build — no eyeball ordering. -/
def outerKeys : List (Data × Data) → List ByteString
  | [] => []
  | (Data.B k, _) :: rest => k :: outerKeys rest
  | _ :: rest => outerKeys rest

def keysAscending : List ByteString → Bool
  | [] => true
  | [_] => true
  | a :: b :: rest => policyLt a b && keysAscending (b :: rest)

def innerSorted : List (Data × Data) → Bool
  | [] => true
  | (_, Data.Map pairs) :: rest =>
    keysAscending (outerKeys pairs) && innerSorted rest
  | _ :: rest => innerSorted rest

def valueMapsSorted (v : List (Data × Data)) : Bool :=
  keysAscending (outerKeys v) && innerSorted v
def RQ_TXID : ByteString := ⟨String.mk ((List.replicate 32 0xD1).map Char.ofNat)⟩
def CL_TXID : ByteString := ⟨String.mk ((List.replicate 32 0xD2).map Char.ofNat)⟩
def SPAN_TXID : ByteString := ⟨String.mk ((List.replicate 32 0xD3).map Char.ofNat)⟩

/-- Five-field `StateDatum(State{root, 500, 2000, 1000, repPolicy})`:
outer `Constr 1`, inner `Constr 0`, new field appended fifth (handoff). -/
def ddfcDatum (root repPolicy : ByteString) : Data :=
  Data.Constr 1 [Data.Constr 0
    [ Data.B root
    , Data.I 500
    , Data.I 2000
    , Data.I 1000
    , Data.B repPolicy
    ]]

def stateAddr5 : Address := ⟨.ScriptCredential DDFC_STATE, none⟩
def appAddr : Address := ⟨.ScriptCredential DDFC_APP, none⟩

def stateInValue : List (Data × Data) :=
  [ (Data.B "", Data.Map [(Data.B "", Data.I 2000000)])
  , (Data.B DDFC_STATE, Data.Map [(Data.B SPAN_CAGE, Data.I 1)])
  ]

def stateRef : TxOutRef := ⟨ST_TXID, (0 : Integer)⟩
def reqRef : TxOutRef := ⟨RQ_TXID, (1 : Integer)⟩
def claimRef : TxOutRef := ⟨CL_TXID, (2 : Integer)⟩

def spanStateIn : TxInInfo :=
  ⟨stateRef, ⟨stateAddr5, stateInValue,
    .OutputDatum (ddfcDatum ROOT_ZERO DDFC_REP), none⟩⟩

/-- MPF request: `RequestDatum(Request{token, owner, 0x6162, Insert(0x6364),
500, 1000})` — token and tip match the cage/state above. -/
def spanReqDatum : Data :=
  Data.Constr 0 [Data.Constr 0
    [ Data.Constr 0 [Data.B SPAN_CAGE]
    , Data.B KEY_OTHER
    , Data.B REQ_KEY
    , Data.Constr 0 [Data.B REQ_VAL]
    , Data.I 500
    , Data.I 1000
    ]]

def spanReqIn : TxInInfo :=
  ⟨reqRef, ⟨⟨.PubKeyCredential KEY_OTHER, none⟩, [],
    .OutputDatum spanReqDatum, none⟩⟩

def spanStateOut (repPolicy : ByteString) : TxOut :=
  ⟨stateAddr5, stateInValue, .OutputDatum (ddfcDatum NEW_ROOT repPolicy), none⟩

/-- Four-field naming record, contract encoding (`none = Constr 0 []`):
`NamingDatum(record)` outer `Constr 0`. `NoDestination` (always well-formed),
32-byte commitment, quorum (1, [H2]). -/
def spanRecord : Data :=
  Data.Constr 0 [Data.Constr 0
    [ Data.B SPAN_CONTROL
    , Data.Constr 0 []
    , Data.B SPAN_COMMIT
    , Data.Constr 0 [Data.I 1, Data.List [Data.B SPAN_H2]]
    ]]

def claimValue : List (Data × Data) :=
  [ (Data.B "", Data.Map [(Data.B "", Data.I 5000000)])
  , (Data.B DDFC_APP, Data.Map [(Data.B SPAN_APPROVAL, Data.I 1)])
  ]

def contValue : List (Data × Data) :=
  [ (Data.B "", Data.Map [(Data.B "", Data.I 5000000)])
  , (Data.B DDFC_REP, Data.Map [(Data.B SPAN_REP, Data.I 1)])
  ]

def spanClaimIn : TxInInfo :=
  ⟨claimRef, ⟨appAddr, claimValue, .OutputDatum spanRecord, none⟩⟩

def spanContOut : TxOut :=
  ⟨appAddr, contValue, .OutputDatum spanRecord, none⟩

/-- `Modify([UpdateAction([])])` — same wire shape as the snapshot leg. -/
def spanModifyRedeemer : Data :=
  Data.Constr 2 [Data.List [Data.Constr 0 [Data.List []]]]

/-- `Fold([repName])`: `ApplicationRedeemer.Fold` = `Constr 2`. -/
def spanFoldData : Data :=
  Data.Constr 2 [Data.List [Data.B SPAN_REP]]

/-- `MintRepresentative`: first constructor, no fields. -/
def spanMintRedeemer : Data := Data.Constr 0 []

def spanMintW : List (Data × Data) :=
  [(Data.B DDFC_APP, Data.Map [(Data.B SPAN_REFUND, Data.I (-1))])]

def spanClaimWValue : List (Data × Data) :=
  [ (Data.B "", Data.Map [(Data.B "", Data.I 5000000)])
  , (Data.B DDFC_APP, Data.Map [(Data.B SPAN_REFUND, Data.I 1)])
  ]

def spanContWValue : List (Data × Data) :=
  [(Data.B "", Data.Map [(Data.B "", Data.I 5000000)])]

def spanClaimWIn : TxInInfo :=
  ⟨claimRef, ⟨appAddr, spanClaimWValue, .OutputDatum spanRecord, none⟩⟩

def spanContWOut : TxOut :=
  ⟨appAddr, spanContWValue, .OutputDatum spanRecord, none⟩

/-- `Fold([])`: withdraw-approval path — approval must be canonical-shaped. -/
def spanFoldWData : Data :=
  Data.Constr 2 [Data.List []]

def spanTxInfoW : TxInfo :=
  ⟨ [spanStateIn, spanReqIn, spanClaimWIn]
  , [], [spanStateOut DDFC_REP, spanContWOut], (0 : Integer)
  , spanMintW
  , [], [], foldRange, [], [(.Spending claimRef, spanFoldWData)], []
  , SPAN_TXID, [], [], Data.Constr 0 [], Data.Constr 0 []
  ⟩

def runSpanAppW (steps : Nat) : State :=
  cekExecuteProgramWithSemanticVariant targetSemVar ddfcAppSpend.script
    [toTerm (⟨spanTxInfoW, spanFoldWData,
       .SpendingScript claimRef (some spanRecord)⟩ : ScriptContext)] steps
-- Isolation leg (withdraw path): shared fold machinery without the
-- insert-specific derivations. HALT isolates the insert-branch refusal;
-- ERROR implicates shared machinery (burn/continuation/record/state).
/-- info: "HALT" -/
#guard_msgs in
#eval outcome (runSpanAppW 200000)

/-- `InsertApproval{controller, control, commitment}` = `Constr 1` (mint
redeemer index 1; `WithdrawApproval` keeps 0). Mints the approval under test. -/
def spanInsertApprovalRedeemer : Data :=
  Data.Constr 1 [Data.B SPAN_H1, Data.B SPAN_CONTROL, Data.B SPAN_COMMIT]

def spanMintApprovalMint : List (Data × Data) :=
  [(Data.B DDFC_APP, Data.Map [(Data.B SPAN_APPROVAL, Data.I 1)])]

def spanTxInfoMintApproval : TxInfo :=
  ⟨ [spanStateIn, spanReqIn, spanClaimIn]
  , [], [spanStateOut DDFC_REP, spanContOut], (0 : Integer)
  , spanMintApprovalMint
  , [], [], foldRange, [SPAN_H1], [], []
  , SPAN_TXID, [], [], Data.Constr 0 [], Data.Constr 0 []
  ⟩

def runSpanAppMintApproval (steps : Nat) : State :=
  cekExecuteProgramWithSemanticVariant targetSemVar ddfcAppSpend.script
    [toTerm (⟨spanTxInfoMintApproval, spanInsertApprovalRedeemer,
       .MintingScript DDFC_APP⟩ : ScriptContext)] steps

-- Isolation leg (mint purpose): the insert-approval derivation through the
-- real bytes, with no state/record/continuation involved. HALT proves the
-- preimage (domain || 0x00 || control || commitment); ERROR convicts it.
/-- info: "HALT" -/
#guard_msgs in
#eval outcome (runSpanAppMintApproval 200000)

def spanRecordClaimValue : List (Data × Data) :=
  [ (Data.B "", Data.Map [(Data.B "", Data.I 5000000)])
  , (Data.B DDFC_REP, Data.Map [(Data.B SPAN_REP, Data.I 1)])
  ]

def spanRecordClaimIn : TxInInfo :=
  ⟨claimRef, ⟨appAddr, spanRecordClaimValue, .OutputDatum spanRecord, none⟩⟩

def spanCustodyOut : TxOut :=
  ⟨⟨.ScriptCredential DDFC_CUSTODY, none⟩,
   [(Data.B "", Data.Map [(Data.B "", Data.I 2000000)]),
    (Data.B DDFC_REP, Data.Map [(Data.B SPAN_REP, Data.I 1)])],
   .NoOutputDatum, none⟩

/-- `Retire{representatives}` = `Constr 3` (payload ignored by the validator). -/
def spanRetireData : Data :=
  Data.Constr 3 [Data.List []]

def spanTxInfoRetire : TxInfo :=
  ⟨ [spanStateIn, spanRecordClaimIn]
  , [], [spanStateOut DDFC_REP, spanCustodyOut], (0 : Integer)
  , [], [], [], foldRange, [SPAN_H1], [], []
  , SPAN_TXID, [], [], Data.Constr 0 [], Data.Constr 0 []
  ⟩

def runSpanAppRetire (steps : Nat) : State :=
  cekExecuteProgramWithSemanticVariant targetSemVar ddfcAppSpend.script
    [toTerm (⟨spanTxInfoRetire, spanRetireData,
       .SpendingScript claimRef (some spanRecord)⟩ : ScriptContext)] steps

-- Isolation leg (retire path): `expected_rep_policy` + custody mechanics
-- with no approval-name or rep-name derivation. HALT proves the state
-- lookup and quantity checks; ERROR implicates them instead of the names.
/-- info: "HALT" -/
#guard_msgs in
#eval outcome (runSpanAppRetire 200000)

def spanMint (repPolicy : ByteString) : List (Data × Data) :=
  let repEntry := (Data.B repPolicy, Data.Map [(Data.B SPAN_REP, Data.I 1)])
  let appEntry :=
    (Data.B DDFC_APP, Data.Map [(Data.B SPAN_APPROVAL, Data.I (-1))])
  if policyLt repPolicy DDFC_APP then [repEntry, appEntry]
  else [appEntry, repEntry]

-- (Sortedness guard lives just before the T1/T2/T3 guard: it covers
-- spanMintNoRep/spanContNoRepOut, defined in the T2/T3 section below.)

def spanTxInfo (outRepPolicy mintRepPolicy : ByteString) : TxInfo :=
  ⟨ [spanStateIn, spanReqIn, spanClaimIn]
  , [], [spanStateOut outRepPolicy, spanContOut], (0 : Integer)
  , spanMint mintRepPolicy
  , [], [], foldRange, [], [(.Spending claimRef, spanFoldData)], []
  , SPAN_TXID, [], [], Data.Constr 0 [], Data.Constr 0 []
  ⟩

def runSpanState (outRepPolicy mintRepPolicy : ByteString) (steps : Nat) : State :=
  cekExecuteProgramWithSemanticVariant targetSemVar ddfcStateSpend.script
    [toTerm (⟨spanTxInfo outRepPolicy mintRepPolicy, spanModifyRedeemer,
       .SpendingScript stateRef (some (ddfcDatum ROOT_ZERO DDFC_REP))⟩
       : ScriptContext)] steps

def runSpanRep (mintRepPolicy : ByteString) (steps : Nat) : State :=
  cekExecuteProgramWithSemanticVariant targetSemVar ddfcRepApplied.script
    [toTerm (⟨spanTxInfo DDFC_REP mintRepPolicy, spanMintRedeemer,
       .MintingScript DDFC_REP⟩ : ScriptContext)] steps

def runSpanApp (mintRepPolicy : ByteString) (steps : Nat) : State :=
  cekExecuteProgramWithSemanticVariant targetSemVar ddfcAppSpend.script
    [toTerm (⟨spanTxInfo DDFC_REP mintRepPolicy, spanFoldData,
       .SpendingScript claimRef (some spanRecord)⟩ : ScriptContext)] steps

/-- Structural equivalence: the applied rep body is exactly
`Apply(unappliedBody, appPolicyBytes)` — the single `applyBytesParam` shape. -/
def ddfcRepStructEq : Bool :=
  match progParts ddfcRepApplied.script, progParts ddfcRepMint.script with
  | (v1, appliedBody), (v2, repBody) =>
    verEq v1 v2 &&
    (appliedBody == Term.Apply repBody
      (Term.Const (Const.Data (Data.B DDFC_APP))))

/-- info: true -/
#guard_msgs in
#eval ddfcRepStructEq

-- The composed shape executes through all three programs (A-004 repair:
-- ascending policy maps at both levels, computed never hand-swapped).
/-- info: ("HALT", "HALT", "HALT") -/
#guard_msgs in
#eval (outcome (runSpanState DDFC_REP DDFC_REP 200000),
       outcome (runSpanRep DDFC_REP 200000),
       outcome (runSpanApp DDFC_REP 200000))

-- Budget probe: the honest fold halts identically at 500k/1M/2M steps
-- (cost-robustness; the earlier ERROR at these counts was the ordering
-- defect, not exhaustion — same fast refusal signature either way).
/-- info: ("HALT", "HALT", "HALT") -/
#guard_msgs in
#eval (outcome (runSpanApp DDFC_REP 500000),
       outcome (runSpanApp DDFC_REP 1000000),
       outcome (runSpanApp DDFC_REP 2000000))

-- Discrimination: foreign-policy mint refuses at the application
-- (`representative-policy`); altered state preservation refuses at `Modify`
-- (before root/refund checks); malformed datum refuses (out-of-domain).
/-- info: ("ERROR", "ERROR", "ERROR") -/
#guard_msgs in
#eval (outcome (runSpanApp DDFC_FOREIGN 200000),
       outcome (runSpanState DDFC_FOREIGN DDFC_REP 200000),
       outcome (cekExecuteProgramWithSemanticVariant targetSemVar
         ddfcStateSpend.script
         [toTerm (⟨spanTxInfo DDFC_REP DDFC_REP, spanModifyRedeemer,
            .SpendingScript stateRef (some (Data.Constr 0 []))⟩
            : ScriptContext)] 200000))

def WRONGNAME : Data := Data.B ⟨String.mk ((List.replicate 32 0x00).map Char.ofNat)⟩

/-- T1: redeemer names a wrong 32-zero name, mint/cont keep the true name.
Predicted ERROR (rep-name mismatch) — a HALT would convict the check. -/
def spanFoldWrongData : Data :=
  Data.Constr 2 [Data.List [WRONGNAME]]

def runSpanAppT1 (steps : Nat) : State :=
  cekExecuteProgramWithSemanticVariant targetSemVar ddfcAppSpend.script
    [toTerm (⟨spanTxInfo DDFC_REP DDFC_REP, spanFoldWrongData,
       .SpendingScript claimRef (some spanRecord)⟩ : ScriptContext)] steps

/-- T2: true redeemer name, mint WITHOUT the rep entry (burn only).
Predicted ERROR (mint-quantity) — a HALT would convict that check. -/
def spanMintNoRep : List (Data × Data) :=
  [(Data.B DDFC_APP, Data.Map [(Data.B SPAN_APPROVAL, Data.I (-1))])]

def spanTxInfoNoRep : TxInfo :=
  ⟨ [spanStateIn, spanReqIn, spanClaimIn]
  , [], [spanStateOut DDFC_REP, spanContOut], (0 : Integer)
  , spanMintNoRep
  , [], [], foldRange, [], [(.Spending claimRef, spanFoldData)], []
  , SPAN_TXID, [], [], Data.Constr 0 [], Data.Constr 0 []
  ⟩

def runSpanAppT2 (steps : Nat) : State :=
  cekExecuteProgramWithSemanticVariant targetSemVar ddfcAppSpend.script
    [toTerm (⟨spanTxInfoNoRep, spanFoldData,
       .SpendingScript claimRef (some spanRecord)⟩ : ScriptContext)] steps

/-- T3: true redeemer name and mint, continuation WITHOUT the rep token.
Predicted ERROR (cont-quantity) — a HALT would convict that check. -/
def spanContNoRepOut : TxOut :=
  ⟨appAddr, [(Data.B "", Data.Map [(Data.B "", Data.I 5000000)])],
   .OutputDatum spanRecord, none⟩

def spanTxInfoNoCont : TxInfo :=
  ⟨ [spanStateIn, spanReqIn, spanClaimIn]
  , [], [spanStateOut DDFC_REP, spanContNoRepOut], (0 : Integer)
  , spanMint DDFC_REP
  , [], [], foldRange, [], [(.Spending claimRef, spanFoldData)], []
  , SPAN_TXID, [], [], Data.Constr 0 [], Data.Constr 0 []
  ⟩

def runSpanAppT3 (steps : Nat) : State :=
  cekExecuteProgramWithSemanticVariant targetSemVar ddfcAppSpend.script
    [toTerm (⟨spanTxInfoNoCont, spanFoldData,
       .SpendingScript claimRef (some spanRecord)⟩ : ScriptContext)] steps

-- Variant probes: each drops exactly one insert-fold requirement.
-- All three are predicted ERROR; any HALT convicts its dropped check.-- Map-order guard (both levels, every mint/value fixture in this file):
-- the A-004 repair is machine-enforced here, not eyeballed.
/-- info: (true, true, true, true, true, true, true, true, true, true) -/
#guard_msgs in
#eval (valueMapsSorted (spanMint DDFC_REP),
       valueMapsSorted (spanMint DDFC_FOREIGN),
       valueMapsSorted spanMintW,
       valueMapsSorted spanMintNoRep,
       valueMapsSorted stateInValue,
       valueMapsSorted claimValue,
       valueMapsSorted contValue,
       valueMapsSorted spanRecordClaimValue,
       valueMapsSorted spanClaimWValue,
       valueMapsSorted spanContWValue)
/-- info: ("ERROR", "ERROR", "ERROR") -/
#guard_msgs in
#eval (outcome (runSpanAppT1 200000),
       outcome (runSpanAppT2 200000),
       outcome (runSpanAppT3 200000))

-- ddfc `End` refuses for every party (ownerless registry: no owner role,
-- termination refused; the constructor stays for the wire shape). Uses the
-- span's own well-formed state datum — refusal is the arm, not the datum.
-- Malformed spend redeemer refuses (out-of-domain guard).
/-- info: ("ERROR", "ERROR") -/
#guard_msgs in
#eval (outcome (cekExecuteProgramWithSemanticVariant targetSemVar
         ddfcStateSpend.script
         [toTerm (⟨spanTxInfo DDFC_REP DDFC_REP, Data.Constr 0 [],
            .SpendingScript stateRef (some (ddfcDatum ROOT_ZERO DDFC_REP))⟩
            : ScriptContext)] 200000),
       outcome (cekExecuteProgramWithSemanticVariant targetSemVar
         ddfcStateSpend.script
         [toTerm (⟨spanTxInfo DDFC_REP DDFC_REP, Data.Constr 9 [],
            .SpendingScript stateRef (some (ddfcDatum ROOT_ZERO DDFC_REP))⟩
            : ScriptContext)] 200000))

end SingularBlaster.DdfcSpan
