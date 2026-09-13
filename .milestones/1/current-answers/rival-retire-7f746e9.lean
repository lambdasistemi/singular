import SingularBlaster.DdfcSpan
import SingularBlaster.EndWitness
import SingularBlaster.ModifyWitness
import SingularBlaster.DdfcScripts
import SingularBlaster.DdfcParams

namespace SingularBlaster.DdfcRival

/-! Official-app rival-cage witness at CEK level (NOTE-007, ddfc `ddfc4e9`).

The application validator is the OFFICIAL one (`52dbf57b…`); the rival is
cage-only (own state policy/token/datum). Target: `expected_rep_policy`
(application.ak:17-28) — FIRST input at the MPFS state address (`2bf61b…`)
holding exactly one state-policy token, then `mpfs_state_policy` from its
datum. It resolves by ADDRESS first, never by datum claim.

Three cases, distinct outcomes and reasons, never collapsed:

1. Ordinary different-policy rival (B honest: own policy/token/datum).
   R1a: honest-A fold with B-state present HALTs (B inert — skipped by the
   address filter). R1b: same tx naming B's rep (minted under B's policy)
   ERRORs at representative-identity.
2. Forged-token (B's token count forged: two tokens under B's policy).
   R2a: honest-A fold with forged-B present HALTs (forgery disturbs
   nothing — resolution is exact-match on A's input). R2b: fold with NO
   A-state at all ERRORs (no spent state resolves — matches the code's
   documented refusal).
3. Copied-policy B — MANDATORY (B's authentic token, A's honest
   `representative_policy` copied into B's datum; possible because
   `validateMint` never validates that field). NOTE-008: `find` is
   first-match, so B must be SLOT-MATCHED (A's address + token) for order
   to matter — a B at its own address is never consulted whatever the
   order. Both orders run, plus a LYING datum (FOREIGN policy): B-first +
   lying makes honest folds refuse (input order decides trust — the gap,
   no copy required); A-first + lying still halts (A shields). Each leg
   keeps its distinct reason.

CEK-level is NOT ledger-level: these show what the compiled programs do
on constructed contexts, not that a transaction is ledger-valid. The
ledger leg stays named debt. NOT counterfeit-NFT, NOT
`Conformance.Authenticate`, NOT stale references, NOT same-token forgery
(separately source-established). Redeemer maps are singletons and request
inputs synthetic, as in the span — full correspondence not claimed.
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
open SingularBlaster.EndWitness (KEY_OTHER outcome ROOT_ZERO)
open SingularBlaster.ModifyWitness (foldRange)
open SingularBlaster.DdfcSpan (policyLt valueMapsSorted ddfcDatum
  spanStateIn spanReqIn spanClaimIn spanStateOut spanContOut spanMint
  spanFoldData spanRecord claimRef stateRef appAddr
  spanRecordClaimIn spanCustodyOut spanRetireData)
open SingularBlaster.DdfcParams (DDFC_STATE DDFC_APP DDFC_REP
  SPAN_APPROVAL SPAN_REP
  B_POLICY B_TOKEN B_TOKEN2 B_H3 B_H4 B_CONTROL B_COMMIT B_APPROVAL B_REP
  B_ROOT SPAN_CAGE DDFC_FOREIGN B_FORGED SPAN_H1)

def B_TXID : ByteString := ⟨String.mk ((List.replicate 32 0xB0).map Char.ofNat)⟩
def B_SLOT_TXID : ByteString := ⟨String.mk ((List.replicate 32 0xB3).map Char.ofNat)⟩
def BC_TXID : ByteString := ⟨String.mk ((List.replicate 32 0xB1).map Char.ofNat)⟩
def RIVAL_TXID : ByteString := ⟨String.mk ((List.replicate 32 0xB2).map Char.ofNat)⟩

def bAddr : Address := ⟨.ScriptCredential B_POLICY, none⟩

/-- B-at-A-slot: B's rival UTxO squatting A's script address with A's cage
token — the ONLY shape at which input order can matter (NOTE-008: `find`
is first-match, so a B at its own address is never consulted whatever the
order). `repol` is B's datum policy: copied-A (attack) or FOREIGN (lying
gap shape). Datum root is B-distinct; only field 4 varies the attack. -/
def bStateRef : TxOutRef := ⟨B_TXID, (0 : Integer)⟩
def bSlotRef : TxOutRef := ⟨B_SLOT_TXID, (0 : Integer)⟩

def bSlotValue : List (Data × Data) :=
  [ (Data.B "", Data.Map [(Data.B "", Data.I 2000000)])
  , (Data.B DDFC_STATE, Data.Map [(Data.B SPAN_CAGE, Data.I 1)])
  ]

def bSlotIn (repol : ByteString) : TxInInfo :=
  ⟨bSlotRef, ⟨⟨.ScriptCredential DDFC_STATE, none⟩, bSlotValue,
    .OutputDatum (ddfcDatum B_ROOT repol), none⟩⟩
def bClaimRef : TxOutRef := ⟨BC_TXID, (1 : Integer)⟩

def bStateValue (extra : List (Data × Data)) : List (Data × Data) :=
  [ (Data.B "", Data.Map [(Data.B "", Data.I 2000000)])
  , (Data.B B_POLICY, Data.Map ([(Data.B B_TOKEN, Data.I 1)] ++ extra))
  ]

/-- B-state input: `repol` is B's datum policy (honest B-policy, or A's
copied policy for the mandatory case); `extra` forges the token count. -/
def bStateIn (repol : ByteString) (extra : List (Data × Data)) : TxInInfo :=
  ⟨bStateRef, ⟨bAddr, bStateValue extra,
    .OutputDatum (ddfcDatum ROOT_ZERO repol), none⟩⟩

/-- B's naming record (own control/quorum/commitment, same four-field shape). -/
def bRecord : Data :=
  Data.Constr 0 [Data.Constr 0
    [ Data.B B_CONTROL
    , Data.Constr 0 []
    , Data.B B_COMMIT
    , Data.Constr 0 [Data.I 1, Data.List [Data.B B_H4]]
    ]]

def bClaimValue : List (Data × Data) :=
  [ (Data.B "", Data.Map [(Data.B "", Data.I 5000000)])
  , (Data.B DDFC_APP, Data.Map [(Data.B B_APPROVAL, Data.I 1)])
  ]

def bClaimIn : TxInInfo :=
  ⟨bClaimRef, ⟨appAddr, bClaimValue, .OutputDatum bRecord, none⟩⟩

def bContOut : TxOut :=
  ⟨appAddr, [(Data.B "", Data.Map [(Data.B "", Data.I 5000000)])],
   .OutputDatum bRecord, none⟩

/-- `Fold([B-rep])` for B-claims. -/
def bFoldData : Data :=
  Data.Constr 2 [Data.List [Data.B B_REP]]

/-- Ascending mint for an arbitrary (policy, name, approval) triple —
same computed-order discipline as the span (never hand-swapped). -/
def bMintFor (pol nm ap : ByteString) : List (Data × Data) :=
  let repEntry := (Data.B pol, Data.Map [(Data.B nm, Data.I 1)])
  let appEntry := (Data.B DDFC_APP, Data.Map [(Data.B ap, Data.I (-1))])
  if policyLt pol DDFC_APP then [repEntry, appEntry]
  else [appEntry, repEntry]

-- Unit guards: B policy sorts after the app policy (0xB7 > 0x52), and the
-- exact triple the mandatory legs depend on.
/-- info: (false, true) -/
#guard_msgs in
#eval (policyLt B_POLICY DDFC_APP, policyLt DDFC_APP B_POLICY)

def rivalTxInfo (ins : List TxInInfo) (outs : List TxOut)
    (mint : List (Data × Data)) (redeemer : Data) (selfRef : TxOutRef)
    (datumOpt : Option Data) (signers : List PubKeyHash) : TxInfo :=
  ⟨ ins
  , [], outs, (0 : Integer)
  , mint
  , [], [], foldRange, signers, [(.Spending selfRef, redeemer)], []
  , RIVAL_TXID, [], [], Data.Constr 0 [], Data.Constr 0 []
  ⟩

def runRivalApp (ins : List TxInInfo) (outs : List TxOut)
    (mint : List (Data × Data)) (redeemer : Data) (selfRef : TxOutRef)
    (datumOpt : Option Data) (steps : Nat) : State :=
  cekExecuteProgramWithSemanticVariant targetSemVar ddfcAppSpend.script
    [toTerm (⟨rivalTxInfo ins outs mint redeemer selfRef datumOpt [],
       redeemer, .SpendingScript selfRef datumOpt⟩ : ScriptContext)] steps

/-- Fold naming B's rep under B's policy (A-claim shape). -/
def spanFoldBRepData : Data :=
  Data.Constr 2 [Data.List [Data.B B_REP]]

-- Case 1a (ordinary rival, honest-A fold, B present): B inert → HALT.
-- Case 1b (confusion: B name + B mint on an A claim): ERROR at identity.
-- Case 2a (forged-B token count present, honest-A fold): HALT (exact match).
-- Case 2b (no A-state at all): ERROR (nothing resolves).
-- Case 3 (B-at-A-slot, both orders × copied/lying datum, honest controls):
--   R3a  A-first + copied, B-fold → ERROR (mint-qty, expected=A).
--   R3aH A-first + copied, honest-A → HALT (control).
--   R3b  B-first + copied, B-fold → ERROR (mint-qty, expected=A-via-B).
--   R3bH B-first + copied, honest-A → HALT (true copy is invisible).
--   R3c  B-first + LYING datum, honest-A → ERROR (expected=FOREIGN:
--        input order decides trust — the gap witness).
--   R3d  A-first + LYING datum, honest-A → HALT (A shields).
--   R3aii A-first + copied, A-name under B-policy → ERROR (redirect refused).
/-- info: ("HALT", "ERROR", "HALT", "ERROR", "ERROR", "HALT", "ERROR", "HALT", "ERROR", "HALT", "ERROR") -/
#guard_msgs in
#eval (outcome (runRivalApp
           [spanStateIn, spanReqIn, spanClaimIn, bStateIn B_POLICY []]
           [spanStateOut DDFC_REP, spanContOut]
           (spanMint DDFC_REP) spanFoldData claimRef (some spanRecord) 200000),
       outcome (runRivalApp
           [spanStateIn, spanReqIn, spanClaimIn, bStateIn B_POLICY []]
           [spanStateOut DDFC_REP, spanContOut]
           (bMintFor B_POLICY B_REP SPAN_APPROVAL) spanFoldBRepData claimRef
           (some spanRecord) 200000),
       outcome (runRivalApp
           [spanStateIn, spanReqIn, spanClaimIn,
            bStateIn B_POLICY [(Data.B B_TOKEN2, Data.I 1)]]
           [spanStateOut DDFC_REP, spanContOut]
           (spanMint DDFC_REP) spanFoldData claimRef (some spanRecord) 200000),
       outcome (runRivalApp
           [spanReqIn, spanClaimIn]
           [spanContOut]
           (spanMint DDFC_REP) spanFoldData claimRef (some spanRecord) 200000),
       outcome (runRivalApp
           [spanStateIn, spanReqIn, bSlotIn DDFC_REP, bClaimIn]
           [spanStateOut DDFC_REP, bContOut]
           (bMintFor B_POLICY B_REP B_APPROVAL) bFoldData bClaimRef
           (some bRecord) 200000),
       outcome (runRivalApp
           [spanStateIn, spanReqIn, spanClaimIn, bSlotIn DDFC_REP]
           [spanStateOut DDFC_REP, spanContOut]
           (spanMint DDFC_REP) spanFoldData claimRef (some spanRecord) 200000),
       outcome (runRivalApp
           [bSlotIn DDFC_REP, spanStateIn, spanReqIn, bClaimIn]
           [spanStateOut DDFC_REP, bContOut]
           (bMintFor B_POLICY B_REP B_APPROVAL) bFoldData bClaimRef
           (some bRecord) 200000),
       outcome (runRivalApp
           [bSlotIn DDFC_REP, spanStateIn, spanReqIn, spanClaimIn]
           [spanStateOut DDFC_REP, spanContOut]
           (spanMint DDFC_REP) spanFoldData claimRef (some spanRecord) 200000),
       outcome (runRivalApp
           [bSlotIn DDFC_FOREIGN, spanStateIn, spanReqIn, spanClaimIn]
           [spanStateOut DDFC_REP, spanContOut]
           (spanMint DDFC_REP) spanFoldData claimRef (some spanRecord) 200000),
       outcome (runRivalApp
           [spanStateIn, spanReqIn, spanClaimIn, bSlotIn DDFC_FOREIGN]
           [spanStateOut DDFC_REP, spanContOut]
           (spanMint DDFC_REP) spanFoldData claimRef (some spanRecord) 200000),
       outcome (runRivalApp
           [spanStateIn, spanReqIn, spanClaimIn, bSlotIn DDFC_REP]
           [spanStateOut DDFC_REP, spanContOut]
           (bMintFor B_POLICY SPAN_REP SPAN_APPROVAL) spanFoldData claimRef
           (some spanRecord) 200000))

-- Map-order guards for every new mint/value map, both levels.
/-- info: (true, true, true, true, true, true, true) -/
#guard_msgs in
#eval (valueMapsSorted (bStateValue []),
       valueMapsSorted (bStateValue [(Data.B B_TOKEN2, Data.I 1)]),
       valueMapsSorted bClaimValue,
       valueMapsSorted (bMintFor B_POLICY B_REP B_APPROVAL),
       valueMapsSorted (bMintFor B_POLICY SPAN_REP SPAN_APPROVAL),
       valueMapsSorted [(Data.B "", Data.Map [(Data.B "", Data.I 5000000)])],
       valueMapsSorted bSlotValue)

/-! ## Retire-A-with-only-B-state (NOTE-009, valid rival domain).

B here is a VALID RIVAL CAGE: same ddfc MPFS script+address, B's distinct
cage token (seed-derived `assetName(B_SEED_TXID, 0)`, recorded-hashlib
standing like `TOKEN_NAME` — synthetic but derived, never eyeballed),
B's datum. The helper checks script + exactly-one-name, never WHICH name
— different `representative_policy` is not different state policy.

- RR0 baseline: honest-A retirement (A-state only) → HALT.
- RR1 ordinary rival (B-token, B's own ordinary policy): expected=B ≠
  A's rep → ERROR at claim-quantity.
- RR2a forged-count (two names under the policy): no input resolves →
  ERROR. RR2b forged-name (unwitnessed `B_FORGED`, count 1): resolves
  (helper passes unauthentic names — authenticity is a BOOTSTRAP property
  via `validateMint`+seed, not spend-time) then ERRORs at quantity;
  the provenance gap is stated, not hidden.
- RR3 MANDATORY copied-policy (B's authentic token, A's `DDFC_REP`
  copied into B's datum; `validateMint` leaves the field unconstrained):
  HALTS — expected resolves to A via B's datum (address+count match, name
  never compared), and every downstream check passes on A's real claim,
  custody and controller. B's datum copy fully authenticates A's
  retirement with no A-state present. Association gap WITNESSED (see
  EVIDENCE finding F-003); verdict (defect vs accepted composition)
  explicitly NOT rendered in-lane.

SCOPE (required): app-only CEK HALTs assume without executing — B's
bootstrap `Minting(seed)` acceptance (seed-find, empty-root, token
conservation); state-spend validity of every constructed input (datum
decode is proven by execution, legitimacy is not); ALL ledger validity
(balance, fees, UTxO existence, signature crypto, collateral). A HALT
from one program is not a valid transaction; all-purpose and ledger
validity are established independently. -/

def RR_TXID : ByteString := ⟨String.mk ((List.replicate 32 0xB4).map Char.ofNat)⟩

def rrStateRef : TxOutRef := ⟨RR_TXID, (0 : Integer)⟩

def rrStateValue (tok : ByteString) (extra : List (Data × Data)) :
    List (Data × Data) :=
  [ (Data.B "", Data.Map [(Data.B "", Data.I 2000000)])
  , (Data.B DDFC_STATE, Data.Map ([(Data.B tok, Data.I 1)] ++ extra))
  ]

def rrStateB (tok repol : ByteString) (extra : List (Data × Data)) : TxInInfo :=
  ⟨rrStateRef, ⟨⟨.ScriptCredential DDFC_STATE, none⟩,
    rrStateValue tok extra,
    .OutputDatum (ddfcDatum B_ROOT repol), none⟩⟩

def runRivalRetire (ins : List TxInInfo) (outs : List TxOut)
    (steps : Nat) : State :=
  cekExecuteProgramWithSemanticVariant targetSemVar ddfcAppSpend.script
    [toTerm (⟨⟨ins, [], outs, (0 : Integer), [], [], [], foldRange,
       [SPAN_H1], [], [], RIVAL_TXID, [], [], Data.Constr 0 [],
       Data.Constr 0 []⟩,
       spanRetireData, .SpendingScript claimRef (some spanRecord)⟩
       : ScriptContext)] steps

-- RR0 baseline HALT; RR1 ordinary-rival ERROR; RR2a forged-count ERROR;
-- RR2b forged-name ERROR (resolves, then quantity); RR3 copied-policy HALT
-- (association gap witnessed — see header + EVIDENCE finding).
/-- info: ("HALT", "ERROR", "ERROR", "ERROR", "HALT") -/
#guard_msgs in
#eval (outcome (runRivalRetire
           [spanStateIn, spanRecordClaimIn]
           [spanStateOut DDFC_REP, spanCustodyOut] 200000),
       outcome (runRivalRetire
           [rrStateB B_TOKEN B_POLICY [], spanRecordClaimIn]
           [spanStateOut DDFC_REP, spanCustodyOut] 200000),
       outcome (runRivalRetire
           [rrStateB B_TOKEN B_POLICY [(Data.B B_TOKEN2, Data.I 1)],
            spanRecordClaimIn]
           [spanStateOut DDFC_REP, spanCustodyOut] 200000),
       outcome (runRivalRetire
           [rrStateB B_FORGED B_POLICY [], spanRecordClaimIn]
           [spanStateOut DDFC_REP, spanCustodyOut] 200000),
       outcome (runRivalRetire
           [rrStateB B_TOKEN DDFC_REP [], spanRecordClaimIn]
           [spanStateOut DDFC_REP, spanCustodyOut] 200000))

-- Map-order guards for the retire legs' new value maps, both levels.
/-- info: (true, true, true) -/
#guard_msgs in
#eval (valueMapsSorted (rrStateValue B_TOKEN []),
       valueMapsSorted (rrStateValue B_TOKEN [(Data.B B_TOKEN2, Data.I 1)]),
       valueMapsSorted (rrStateValue B_FORGED []))

end SingularBlaster.DdfcRival
