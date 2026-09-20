{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.TxBuilder.Edges
Description : Booking and folding one registry-mode tree edge
License     : Apache-2.0

Registry mode admits seven edges and nothing else (#157 C2), and every
processed edge but a read rides on an approval the naming application's
mint arm certified (#157 C4, D-APPROVAL). A caller that wants a fold to
land therefore needs three things this module supplies: the four policy
pins derived from the naming partition's own compiled code, a booking
transaction that mints the approval and creates the request carrying it,
and the duties context the fold discharges its obligations from.

The state validator alone is fifteen kilobytes, so a fold that attaches
it, the request validator and a token policy does not fit in a
transaction. 'publishCageRefs' publishes them once as reference outputs
and every purpose resolves through those instead.

Every consumer of the application — the conformance rows, the devnet E2E
and the bounded journey — derives its pins and books its edges the same
way, so all three move together.
-}
module Singular.Registry.TxBuilder.Edges (
    -- * Submission
    SubmitSigned,

    -- * Derived identity
    registryIdOf,
    witnessScriptOf,
    namingPins,

    -- * Reference outputs
    publishRefScript,
    publishStateRef,
    publishCageRefs,
    adaOnlyOut,

    -- * Booking one edge
    bookEdge,
    bookEdgeTo,
    edgeDeposit,
    edgeDestinationOf,
    edgeRecordDatum,
    edgeRecordDatumHash,

    -- * Folding
    registryContextFor,
) where

import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Lens.Micro ((&), (.~), (^.))

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address (Addr (..), serialiseAddr)
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Api.Tx (mkBasicTx, txIdTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body (
    collateralInputsTxBodyL,
    feeTxBodyL,
    inputsTxBodyL,
    mintTxBodyL,
    mkBasicTxBody,
    outputsTxBodyL,
    reqSignerHashesTxBodyL,
    scriptIntegrityHashTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    coinTxOutL,
    datumTxOutL,
    getMinCoinTxOut,
    mkBasicTxOut,
    referenceScriptTxOutL,
    valueTxOutL,
 )
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL, scriptTxWitsL)
import Cardano.Ledger.BaseTypes (StrictMaybe (..), TxIx (..))
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (Script, extractHash, hashScript)
import Cardano.Ledger.Credential (Credential (..), StakeReference (..))
import Cardano.Ledger.Mary.Value (
    AssetName (..),
    MaryValue (..),
    MultiAsset (..),
    PolicyID (..),
 )
import Cardano.Ledger.Plutus.Data (Data (..), hashData)
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import PlutusCore.Data qualified as PLC

import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint (
    NamingCodes (..),
    applyBytesParam,
    applyDataParam,
 )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (Coin (..), ConwayEra, TokenId)
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.TxBuilder.ConnectedFold (
    RawRedeemer (..),
    generousUnits,
 )
import Singular.Registry.TxBuilder.Internal (
    addrKeyHashBytes,
    addrWitnessKeyHash,
    approvalName,
    cageAddrFromCfg,
    computeScriptHash,
    computeScriptIntegrity,
    currentPosixMs,
    mkCageScript,
    mkInlineDatum,
    mkRequestDatumWith,
    mkRequestScript,
    requestAddrFromCfg,
    scriptFromBytes,
    scriptHashBytes,
    toLedgerData,
 )
import Singular.Registry.TxBuilder.Update (
    RegistryContext (..),
    emptyRegistryContext,
 )
import Singular.Registry.Types (
    Edge,
    edgeInsertActive,
    edgeUpdateActive,
    edgeInsertAbsent,
    edgeWitnessTerminal,
 )

{- | Sign a built transaction with the payer's key, submit it, and wait
for it. The caller owns its own signing key and its own confirmation
discipline, so it supplies this rather than the module guessing either.
-}
type SubmitSigned = ConwayTx -> IO ConwayTx

{- | The registry id a witness policy is parameterized by: the state
policy plus the token name this cage's seed determined.
-}
registryIdOf :: CageConfig -> ByteString
registryIdOf cfg =
    scriptHashBytes (cfgScriptHash cfg) <> deriveAssetName (cageSeed cfg)

-- | The witness policy script of one token kind.
witnessScriptOf :: CageConfig -> NamingCodes -> Integer -> Script ConwayEra
witnessScriptOf cfg codes kind =
    scriptFromBytes
        ("witness-" <> show kind)
        ( applyBytesParam
            (registryIdOf cfg)
            (applyDataParam (PLC.I kind) (ncWitness codes))
        )

{- | The four pins a registry identity carries (#157 D-BOOT), derived
from the naming partition's own compiled code: the application validator
for the approval, and @witness(kind, registry)@ at kinds 0, 1 and 2.

The registry id the witness policies are parameterized by depends on the
state script hash and the boot seed, so this takes them directly rather
than a configuration that does not exist yet.
-}
namingPins ::
    NamingCodes ->
    -- | The registry id: state script hash then boot token name
    ByteString ->
    -- | Application, absent, active, terminal
    ( SBS.ShortByteString
    , SBS.ShortByteString
    , SBS.ShortByteString
    , SBS.ShortByteString
    )
namingPins codes registryId =
    ( pinOf (ncApplication codes)
    , witnessPin 0
    , witnessPin 1
    , witnessPin 2
    )
  where
    pinOf = SBS.toShort . scriptHashBytes . computeScriptHash
    witnessPin kind =
        pinOf
            ( applyBytesParam
                registryId
                (applyDataParam (PLC.I kind) (ncWitness codes))
            )

{- | Can this output fund a transaction? It must hold ada and nothing
else, because it doubles as collateral, and it must not be one of the
published reference outputs, because a transaction may not both spend an
output and reference it.
-}
adaOnlyOut :: TxOut ConwayEra -> Bool
adaOnlyOut out =
    (case out ^. valueTxOutL of MaryValue _ (MultiAsset m) -> Map.null m)
        && (case out ^. referenceScriptTxOutL of SNothing -> True; SJust _ -> False)

-- | Publish one script as a reference output at the payer's own address.
publishRefScript ::
    Cage.Provider IO ->
    SubmitSigned ->
    Addr ->
    Script ConwayEra ->
    IO (TxIn, TxOut ConwayEra)
publishRefScript prov submit payerAddr script = do
    pp <- Cage.queryProtocolParams prov
    utxos <- Cage.queryUTxOs prov payerAddr
    fund <-
        case sortOn (Down . (^. coinTxOutL) . snd) (filter (adaOnlyOut . snd) utxos) of
            [] -> error "publishRefScript: the payer wallet has no ada-only output"
            (u : _) -> pure u
    let probe =
            mkBasicTxOut payerAddr (MaryValue (Coin 0) mempty)
                & referenceScriptTxOutL .~ SJust script
        Coin minCoin = getMinCoinTxOut pp probe
        refCoin = minCoin + 1_000_000
        refOut =
            mkBasicTxOut payerAddr (MaryValue (Coin refCoin) mempty)
                & referenceScriptTxOutL .~ SJust script
        fee = 1_000_000
        Coin inCoin = snd fund ^. coinTxOutL
        changeCoin = inCoin - fee - refCoin
    unless (changeCoin > 1_000_000) $
        error
            ( "publishRefScript: the funding output holds "
                <> show inCoin
                <> ", which does not cover a reference output of "
                <> show refCoin
                <> " plus fees"
            )
    let body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton (fst fund)
                & outputsTxBodyL
                    .~ StrictSeq.fromList
                        [ refOut
                        , mkBasicTxOut payerAddr (MaryValue (Coin changeCoin) mempty)
                        ]
                & feeTxBodyL .~ Coin fee
    signed <- submit (mkBasicTx body)
    pure (TxIn (txIdTx signed) (TxIx 0), refOut)


{- | Publish the state validator as a reference output, once, before any
boot (#177).

The boot transaction carries the state validator inline unless the
payer's wallet already holds a publication of it, and that validator is
fifteen kilobytes against a sixteen-kilobyte transaction cap. A session
calls this before its first boot and every boot after it references the
script instead of carrying it, which is what leaves room for the
retirement's guard.

Idempotent by discovery: a wallet that already holds the publication
gets it back rather than a second one, so a harness that boots several
cages publishes once.
-}
publishStateRef ::
    CageConfig ->
    Cage.Provider IO ->
    SubmitSigned ->
    Addr ->
    IO (TxIn, TxOut ConwayEra)
publishStateRef cfg prov submit payerAddr = do
    let script = mkCageScript cfg
        wanted = hashScript script
    utxos <- Cage.queryUTxOs prov payerAddr
    case [ u
         | u@(_, out) <- utxos
         , SJust s <- [out ^. referenceScriptTxOutL]
         , hashScript s == wanted
         ] of
        (u : _) -> pure u
        [] -> publishRefScript prov submit payerAddr script

{- | Publish this cage's scripts as reference outputs: the cage, the
request validator and the three token policies.
-}
publishCageRefs ::
    CageConfig ->
    NamingCodes ->
    Cage.Provider IO ->
    SubmitSigned ->
    Addr ->
    TokenId ->
    IO [(TxIn, TxOut ConwayEra)]
publishCageRefs cfg codes prov submit payerAddr tokenId =
    mapM
        (publishRefScript prov submit payerAddr)
        ( [ mkCageScript cfg
          , mkRequestScript cfg tokenId
          ]
            <> map (witnessScriptOf cfg codes) [0, 1, 2]
        )

{- | The record datum a booking's destination binds. The cage checks only
that the receiving output carries a datum hashing to what the approval
bound — naming's own validators do not run at fold time — so one datum
produced on both sides is enough.
-}
edgeRecordDatum :: PLC.Data
edgeRecordDatum = PLC.B "singular-record"

-- | The hash of 'edgeRecordDatum'.
edgeRecordDatumHash :: ByteString
edgeRecordDatumHash =
    hashToBytes (extractHash (hashData (Data edgeRecordDatum :: Data ConwayEra)))

{- | Where an edge delivers (#157 D-DEST). An absence names the address
its deposit comes back to and no datum; an activation names the naming
application's own address and the record datum it will carry.
-}
edgeDestinationOf ::
    CageConfig ->
    NamingCodes ->
    Addr ->
    Edge ->
    (ByteString, ByteString)
edgeDestinationOf cfg codes payerAddr edge =
    let appHash = computeScriptHash (ncApplication codes)
        appAddr = Addr (network cfg) (ScriptHashObj appHash) StakeRefNull
     in if edge == edgeInsertActive || edge == edgeUpdateActive
            then (serialiseAddr appAddr, edgeRecordDatumHash)
            else (serialiseAddr payerAddr, BS.empty)

{- | The deposit a booking rides with, over and above the tip. The fold
returns it to the destination the request named, or locks it in the
custody an absence creates — it is never the folder's.
-}
edgeDeposit :: Integer
edgeDeposit = 3_000_000

{- | Book one tree edge: the naming application's mint arm certifies
which edge this is, for whom and where it delivers, and the request
carries that approval to the fold.
-}
{- | Book an edge, routing its minted token to the destination
`edgeDestinationOf` chooses for it.
-}
bookEdge ::
    CageConfig ->
    NamingCodes ->
    Cage.Provider IO ->
    SubmitSigned ->
    Addr ->
    TokenId ->
    ByteString ->
    Edge ->
    IO TxIn
bookEdge cfg codes prov submit payerAddr tokenId key edge =
    bookEdgeTo
        cfg
        codes
        prov
        submit
        payerAddr
        tokenId
        key
        edge
        (edgeDestinationOf cfg codes payerAddr edge)

{- | Book an edge, naming the destination explicitly (#173 I4, I5).

`edgeDestinationOf` sends an `insertActive` to the APPLICATION's own
script address, because the naming application is what creates the
record the active token witnesses. The OPEN registry has no such
application: `open.ak` is a minting policy with no spending arm at all,
so a token routed there would be locked forever.

The open story therefore names a WALLET, and the request carries that
choice. Nothing on chain changes: the cage already checks the
destination the request declares, and this is the off-chain builder
learning to say something it could not say before.
-}
bookEdgeTo ::
    CageConfig ->
    NamingCodes ->
    Cage.Provider IO ->
    SubmitSigned ->
    Addr ->
    TokenId ->
    ByteString ->
    Edge ->
    (ByteString, ByteString) ->
    IO TxIn
bookEdgeTo cfg codes prov submit payerAddr tokenId key edge dest0 = do
    -- #183: the tag IS the edge. A booking states its own C2 row, and a
    -- row outside the table is one only an adversarial caller wants, so
    -- it is refused here rather than carried to a fold that would refuse
    -- it `edge-inadmissible` anyway.
    if edge < edgeInsertAbsent || edge > edgeWitnessTerminal
        then
            error
                ( "bookEdge: edge "
                    <> show edge
                    <> " on key "
                    <> show key
                    <> " is not one of the seven admissible edges"
                )
        else pure ()
    pp <- Cage.queryProtocolParams prov
    utxos <- Cage.queryUTxOs prov payerAddr
    (feeIn, feeOut) <-
        case sortOn (Down . (^. coinTxOutL) . snd) (filter (adaOnlyOut . snd) utxos) of
            [] -> error "bookEdge: the payer wallet has no ada-only output"
            (u : _) -> pure u
    now <- currentPosixMs
    let MaryValue (Coin feeBal) carried = feeOut ^. valueTxOutL
        Coin tipVal = defaultTip cfg
        bond = tipVal + edgeDeposit
        fee = 2_000_000
        change = feeBal - bond - fee
        owner = addrKeyHashBytes payerAddr
        dest@(destAddr, destHash) = dest0
        name = approvalName edge key owner dest
        appScript = scriptFromBytes "naming-application" (ncApplication codes)
        appPolicy = PolicyID (hashScript appScript)
        approval =
            MultiAsset
                ( Map.singleton
                    appPolicy
                    (Map.singleton (AssetName (SBS.toShort name)) 1)
                )
        approveRedeemer =
            PLC.Constr
                0
                [ PLC.I edge
                , PLC.B key
                , PLC.B owner
                , PLC.List [PLC.B destAddr, PLC.B destHash]
                ]
        requestAddr = requestAddrFromCfg cfg tokenId (network cfg)
        -- #183: the datum binds the DEPOSIT, not the tip. The output
        -- holds `bond` = tip + deposit, and the fold checks
        -- `deposit == held - tip`, so the two are the same number
        -- written once each. The min-ADA check below is what keeps
        -- them equal: a bond raised to meet min-ADA would break the
        -- equality silently, so the booking refuses instead.
        datum = mkRequestDatumWith tokenId payerAddr key edge edgeDeposit now dest
        reqOut =
            mkBasicTxOut requestAddr (MaryValue (Coin bond) approval)
                & datumTxOutL .~ mkInlineDatum datum
        Coin minAda = getMinCoinTxOut pp reqOut
    unless (change > 0) $
        error ("bookEdge: the payer wallet is too small (" <> show feeBal <> ")")
    unless (bond >= minAda) $
        error ("bookEdge: the bond is under min-ADA: " <> show bond)
    let redeemers =
            Redeemers
                ( Map.singleton
                    (ConwayMinting (AsIx 0))
                    (toLedgerData (RawRedeemer approveRedeemer), generousUnits)
                )
        integrity = computeScriptIntegrity pp redeemers
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton feeIn
                & outputsTxBodyL
                    .~ StrictSeq.fromList
                        [ reqOut
                        , mkBasicTxOut payerAddr (MaryValue (Coin change) carried)
                        ]
                & feeTxBodyL .~ Coin fee
                & mintTxBodyL .~ approval
                & collateralInputsTxBodyL .~ Set.singleton feeIn
                & reqSignerHashesTxBodyL
                    .~ Set.singleton (addrWitnessKeyHash owner)
                & scriptIntegrityHashTxBodyL .~ integrity
        unsigned =
            mkBasicTx body
                & witsTxL . scriptTxWitsL
                    .~ Map.singleton (hashScript appScript) appScript
                & witsTxL . rdmrsTxWitsL .~ redeemers
    signed <- submit unsigned
    pure (TxIn (txIdTx signed) (TxIx 0))

{- | What a fold of tree edges needs in hand: the three token policies
this registry pins, the cage script custody spends run, the cage's own
UTxOs, the one destination datum a booking binds, and the reference
outputs the fold's scripts resolve through.
-}
registryContextFor ::
    CageConfig ->
    NamingCodes ->
    Cage.Provider IO ->
    [(TxIn, TxOut ConwayEra)] ->
    IO RegistryContext
registryContextFor cfg codes prov refs = do
    utxos <- Cage.queryUTxOs prov (cageAddrFromCfg cfg (network cfg))
    pure
        emptyRegistryContext
            { rcWitnessScripts =
                Map.fromList [(k, witnessScriptOf cfg codes k) | k <- [0, 1, 2]]
            , rcCageScript = Just (mkCageScript cfg)
            , rcCageUtxos = utxos
            , rcDatums = [(edgeRecordDatumHash, edgeRecordDatum)]
            , rcRefUtxos = refs
            }
