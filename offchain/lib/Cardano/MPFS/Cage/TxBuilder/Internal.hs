{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.MPFS.Cage.TxBuilder.Internal
Description : Shared helpers for cage transaction builders
License     : Apache-2.0

Utility functions shared across the per-operation
transaction builders (@Boot@, @Request@, @Update@,
@Retract@, @End@). Covers script construction,
datum\/redeemer encoding, address manipulation,
UTxO lookup, spending-index computation,
execution-unit defaults, and POSIX-to-slot
conversion.
-}
module Cardano.MPFS.Cage.TxBuilder.Internal (
    -- * Script construction
    mkCageScript,
    mkRequestScript,
    scriptFromBytes,
    scriptHashBytes,
    computeScriptHash,

    -- * Derived identity
    cagePolicyIdFromCfg,
    cageAddrFromCfg,
    requestAddrFromCfg,
    onChainTokenId,

    -- * Datum helpers
    mkRequestDatum,
    toPlcData,
    toLedgerData,
    mkInlineDatum,
    extractCageDatum,

    -- * Reference conversion
    txInToRef,
    addrKeyHashBytes,
    addrFromKeyHashBytes,
    addrWitnessKeyHash,

    -- * UTxO lookup
    findUtxoByTxIn,
    findStateUtxo,
    findRequestUtxos,

    -- * Indexing
    spendingIndex,

    -- * Script integrity
    computeScriptIntegrity,

    -- * Evaluate and balance
    evaluateAndBalance,
    placeholderExUnits,

    -- * Constants
    emptyRoot,

    -- * Time and slot helpers
    currentPosixMs,
    trySlots,

    -- * Request helpers
    extractOwnerBytes,

    -- * Refund computation
    computeRefund,
) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Word (Word32)
import Lens.Micro ((&), (.~), (^.))

import Cardano.Crypto.Hash (hashFromBytes, hashToBytes)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Alonzo.PParams (
    LangDepView,
    getLanguageView,
 )
import Cardano.Ledger.Alonzo.Scripts (
    fromPlutusScript,
    mkPlutusScript,
 )
import Cardano.Ledger.Alonzo.Tx (
    ScriptIntegrity (..),
    ScriptIntegrityHash,
    hashScriptIntegrity,
 )
import Cardano.Ledger.Alonzo.TxBody (
    scriptIntegrityHashTxBodyL,
 )
import Cardano.Ledger.Alonzo.TxWits (
    Redeemers (..),
    TxDats (..),
 )
import Cardano.Ledger.Api.Scripts.Data (
    Data (..),
    Datum (..),
    binaryDataToData,
    dataToBinaryData,
 )
import Cardano.Ledger.Api.Tx (
    bodyTxL,
    witsTxL,
 )
import Cardano.Ledger.Api.Tx.Body (
    inputsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    coinTxOutL,
    datumTxOutL,
    getMinCoinTxOut,
    mkBasicTxOut,
    valueTxOutL,
 )
import Cardano.Ledger.Api.Tx.Wits (
    rdmrsTxWitsL,
 )
import Cardano.Ledger.BaseTypes (
    Inject (..),
    Network,
    StrictMaybe (..),
    TxIx (..),
 )
import Cardano.Ledger.Core (
    Script,
    extractHash,
    hashScript,
 )
import Cardano.Ledger.Credential (
    Credential (..),
    StakeReference (..),
 )
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Keys (
    KeyHash (..),
    KeyRole (..),
 )
import Cardano.Ledger.Mary.Value (
    MaryValue (..),
    MultiAsset (..),
    PolicyID (..),
 )
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.Plutus.Language (
    Language (PlutusV3),
    Plutus (..),
    PlutusBinary (..),
 )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Control.Exception (SomeException, try)
import Data.Coerce (coerce)
import Data.Time.Clock.POSIX (getPOSIXTime)
import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins.Internal (
    BuiltinByteString (..),
    BuiltinData (..),
 )
import PlutusTx.IsData.Class (
    FromData (..),
    ToData (..),
 )

import Cardano.MPFS.Cage.Blueprint (
    applyRequestParams,
 )
import Cardano.MPFS.Cage.Config (
    CageConfig (..),
 )
import Cardano.MPFS.Cage.Ledger (
    AssetName (..),
    Coin (..),
    ConwayEra,
    PParams,
    TokenId (..),
 )
import Cardano.MPFS.Cage.Provider (Provider (..))
import Cardano.MPFS.Cage.Types (
    CageDatum (..),
    OnChainOperation (..),
    OnChainRequest (..),
    OnChainTokenId (..),
    OnChainTxOutRef (..),
 )
import Cardano.Slotting.Slot (SlotNo)
import Cardano.Tx.Balance (
    BalanceResult (..),
    balanceTx,
 )
import Cardano.Tx.Ledger (ConwayTx)

-- | Empty MPF root (32 zero bytes).
emptyRoot :: ByteString
emptyRoot = BS.replicate 32 0

{- | Placeholder execution units used in the initial
unbalanced transaction.
-}
placeholderExUnits :: ExUnits
placeholderExUnits = ExUnits 0 0

{- | Evaluate script execution units and balance
a transaction.
-}
evaluateAndBalance ::
    Provider IO ->
    PParams ConwayEra ->
    -- | All input UTxOs (fee + script)
    [(TxIn, TxOut ConwayEra)] ->
    -- | Change address
    Addr ->
    -- | Unbalanced tx with placeholder ExUnits
    ConwayTx ->
    IO ConwayTx
evaluateAndBalance prov pp inputUtxos changeAddr tx =
    do
        let existingIns =
                tx ^. bodyTxL . inputsTxBodyL
            allIns =
                foldl
                    ( \s (tin, _) ->
                        Set.insert tin s
                    )
                    existingIns
                    inputUtxos
            txForEval =
                tx
                    & bodyTxL . inputsTxBodyL
                        .~ allIns
        evalResult <- evaluateTx prov txForEval
        let failures =
                [ (p, e)
                | (p, Left e) <-
                    Map.toList evalResult
                ]
        if null failures
            then pure ()
            else
                error $
                    "evaluateAndBalance: \
                    \script eval failed: "
                        <> show failures
        let
            Redeemers rdmrMap =
                tx ^. witsTxL . rdmrsTxWitsL
            patched =
                Map.mapWithKey
                    ( \purpose (dat, eu) ->
                        case Map.lookup
                            purpose
                            evalResult of
                            Just (Right eu') ->
                                (dat, eu')
                            _ -> (dat, eu)
                    )
                    rdmrMap
            newRedeemers = Redeemers patched
            integrity =
                computeScriptIntegrity
                    pp
                    newRedeemers
            patched' =
                tx
                    & witsTxL . rdmrsTxWitsL
                        .~ newRedeemers
                    & bodyTxL
                        . scriptIntegrityHashTxBodyL
                        .~ integrity
        case balanceTx
            pp
            inputUtxos
            []
            changeAddr
            patched' of
            Left err ->
                error $
                    "evaluateAndBalance: "
                        <> show err
            Right br -> pure (balancedTx br)

-- | Build the cage 'Script' from config bytes.
mkCageScript ::
    CageConfig ->
    Script ConwayEra
mkCageScript cfg =
    scriptFromBytes
        "mkCageScript"
        (cageScriptBytes cfg)

-- | Build the per-cage request 'Script' from config bytes.
mkRequestScript ::
    CageConfig ->
    TokenId ->
    Script ConwayEra
mkRequestScript cfg tid =
    scriptFromBytes
        "mkRequestScript"
        (requestScriptBytesFromCfg cfg tid)

scriptFromBytes ::
    String ->
    SBS.ShortByteString ->
    Script ConwayEra
scriptFromBytes label sbs =
    let plutus =
            Plutus @PlutusV3 $
                PlutusBinary sbs
     in case mkPlutusScript plutus of
            Just ps -> fromPlutusScript ps
            Nothing ->
                error
                    ( label
                        <> ": invalid PlutusV3 \
                           \script"
                    )

-- | Compute the 'ScriptHash' from raw script bytes.
computeScriptHash ::
    SBS.ShortByteString ->
    ScriptHash
computeScriptHash sbs =
    let plutus =
            Plutus @PlutusV3 $
                PlutusBinary sbs
     in case mkPlutusScript @ConwayEra plutus of
            Just ps ->
                hashScript @ConwayEra $
                    fromPlutusScript ps
            Nothing ->
                error
                    "computeScriptHash: invalid \
                    \PlutusV3 script"

-- | Compute the cage minting policy ID from config.
cagePolicyIdFromCfg :: CageConfig -> PolicyID
cagePolicyIdFromCfg =
    PolicyID . cfgScriptHash

-- | Compute the cage script address from config.
cageAddrFromCfg ::
    CageConfig ->
    Network ->
    Addr
cageAddrFromCfg cfg net =
    Addr
        net
        (ScriptHashObj $ cfgScriptHash cfg)
        StakeRefNull

-- | Compute the request script address for a token.
requestAddrFromCfg ::
    CageConfig ->
    TokenId ->
    Network ->
    Addr
requestAddrFromCfg cfg tid net =
    Addr
        net
        ( ScriptHashObj $
            computeScriptHash
                (requestScriptBytesFromCfg cfg tid)
        )
        StakeRefNull

-- | Convert a ledger token id to its on-chain token id.
onChainTokenId :: TokenId -> OnChainTokenId
onChainTokenId tid =
    OnChainTokenId $
        BuiltinByteString $
            SBS.fromShort $
                let AssetName sbs = unTokenId tid
                 in sbs

requestScriptBytesFromCfg ::
    CageConfig ->
    TokenId ->
    SBS.ShortByteString
requestScriptBytesFromCfg cfg tid =
    applyRequestParams
        (scriptHashBytes $ cfgScriptHash cfg)
        (onChainTokenId tid)
        (requestScriptBytes cfg)

scriptHashBytes :: ScriptHash -> ByteString
scriptHashBytes (ScriptHash h) =
    hashToBytes h

-- | Build a 'CageDatum' for a request.
mkRequestDatum ::
    TokenId ->
    Addr ->
    ByteString ->
    OnChainOperation ->
    Integer ->
    Integer ->
    PLC.Data
mkRequestDatum tid addr key op fee submittedAt =
    let datum =
            OnChainRequest
                { requestToken = onChainTokenId tid
                , requestOwner =
                    BuiltinByteString
                        (addrKeyHashBytes addr)
                , requestKey = key
                , requestValue = op
                , requestFee = fee
                , requestSubmittedAt = submittedAt
                }
     in toPlcData (RequestDatum datum)

{- | Convert a 'ToData' value to
'PlutusCore.Data.Data'.
-}
toPlcData :: (ToData a) => a -> PLC.Data
toPlcData x =
    let BuiltinData d = toBuiltinData x in d

-- | Convert a 'ToData' value to a ledger 'Data'.
toLedgerData ::
    (ToData a) => a -> Data ConwayEra
toLedgerData = Data . toPlcData

{- | Wrap 'PlutusCore.Data.Data' as an inline
'Datum'.
-}
mkInlineDatum :: PLC.Data -> Datum ConwayEra
mkInlineDatum d =
    Datum $
        dataToBinaryData
            (Data d :: Data ConwayEra)

{- | Convert a ledger 'TxIn' to an on-chain
'OnChainTxOutRef'.
-}
txInToRef :: TxIn -> OnChainTxOutRef
txInToRef (TxIn (TxId h) (TxIx ix)) =
    OnChainTxOutRef
        { txOutRefId =
            BuiltinByteString
                (hashToBytes (extractHash h))
        , txOutRefIdx = fromIntegral ix
        }

{- | Extract the payment key hash raw bytes from
an 'Addr'.
-}
addrKeyHashBytes :: Addr -> ByteString
addrKeyHashBytes
    (Addr _ (KeyHashObj (KeyHash h)) _) =
        hashToBytes h
addrKeyHashBytes _ = BS.empty

{- | Reconstruct an 'Addr' from raw payment key
hash bytes.
-}
addrFromKeyHashBytes ::
    Network ->
    ByteString ->
    Addr
addrFromKeyHashBytes net bs =
    case hashFromBytes bs of
        Just h ->
            Addr
                net
                (KeyHashObj (KeyHash h))
                StakeRefNull
        Nothing ->
            error
                "addrFromKeyHashBytes: \
                \invalid hash"

{- | Extract a 'KeyHash' ''Witness' from raw
payment key hash bytes.
-}
addrWitnessKeyHash ::
    ByteString -> KeyHash Guard
addrWitnessKeyHash bs =
    case hashFromBytes bs of
        Just h ->
            coerce
                (KeyHash h :: KeyHash Payment)
        Nothing ->
            error
                "addrWitnessKeyHash: \
                \invalid hash"

-- | Find a UTxO by its 'TxIn'.
findUtxoByTxIn ::
    TxIn ->
    [(TxIn, TxOut ConwayEra)] ->
    Maybe (TxIn, TxOut ConwayEra)
findUtxoByTxIn needle =
    find' (\(tin, _) -> tin == needle)
  where
    find' _ [] = Nothing
    find' p (x : xs)
        | p x = Just x
        | otherwise = find' p xs

-- | Find the state UTxO for a token.
findStateUtxo ::
    PolicyID ->
    TokenId ->
    [(TxIn, TxOut ConwayEra)] ->
    Maybe (TxIn, TxOut ConwayEra)
findStateUtxo policyId tid = find' isState
  where
    assetName = unTokenId tid
    isState (_, txOut) =
        case txOut ^. valueTxOutL of
            MaryValue _ (MultiAsset ma) ->
                case Map.lookup policyId ma of
                    Just assets ->
                        Map.member assetName assets
                    Nothing -> False
    find' _ [] = Nothing
    find' p (x : xs)
        | p x = Just x
        | otherwise = find' p xs

-- | Find all request UTxOs for a token.
findRequestUtxos ::
    TokenId ->
    [(TxIn, TxOut ConwayEra)] ->
    [(TxIn, TxOut ConwayEra)]
findRequestUtxos tid = filter isRequest
  where
    targetName = unTokenId tid
    isRequest (_, txOut) =
        case extractCageDatum txOut of
            Just (RequestDatum req) ->
                let OnChainRequest
                        { requestToken =
                            OnChainTokenId
                                (BuiltinByteString bs)
                        } = req
                 in AssetName (SBS.toShort bs)
                        == targetName
            _ -> False

{- | Extract a 'CageDatum' from an inline datum
in a 'TxOut'.
-}
extractCageDatum ::
    TxOut ConwayEra -> Maybe CageDatum
extractCageDatum txOut =
    case txOut ^. datumTxOutL of
        Datum bd ->
            let Data plcData =
                    binaryDataToData bd
             in fromBuiltinData (BuiltinData plcData)
        _ -> Nothing

-- | Compute the spending index of a 'TxIn'.
spendingIndex :: TxIn -> Set.Set TxIn -> Word32
spendingIndex needle inputs =
    let sorted = Set.toAscList inputs
     in go 0 sorted
  where
    go _ [] =
        error "spendingIndex: TxIn not in set"
    go n (x : xs)
        | x == needle = n
        | otherwise = go (n + 1) xs

-- | Compute the 'ScriptIntegrityHash'.
computeScriptIntegrity ::
    PParams ConwayEra ->
    Redeemers ConwayEra ->
    StrictMaybe ScriptIntegrityHash
computeScriptIntegrity pp rdmrs =
    let langViews :: Set.Set LangDepView
        langViews =
            Set.singleton
                (getLanguageView pp PlutusV3)
        emptyDats :: TxDats ConwayEra
        emptyDats = TxDats mempty
     in SJust
            ( hashScriptIntegrity
                (ScriptIntegrity rdmrs emptyDats langViews)
            )

-- | Get current POSIX time in milliseconds.
currentPosixMs :: IO Integer
currentPosixMs = do
    t <- getPOSIXTime
    pure $ floor (t * 1000)

{- | Try converting successive POSIX ms values to
slots, returning the first that succeeds.
-}
trySlots ::
    Provider IO -> [Integer] -> IO SlotNo
trySlots _ [] =
    error
        "posixMsToSlot: all fallbacks \
        \past horizon"
trySlots p (ms : rest) = do
    r <-
        try @SomeException
            (posixMsCeilSlot p ms)
    case r of
        Right s -> pure s
        Left _ -> trySlots p rest

{- | Extract the owner key hash bytes from a
request 'TxOut'.
-}
extractOwnerBytes ::
    TxOut ConwayEra -> ByteString
extractOwnerBytes out =
    case extractCageDatum out of
        Just (RequestDatum req) ->
            let OnChainRequest
                    { requestOwner =
                        BuiltinByteString bs
                    } = req
             in bs
        _ ->
            error
                "extractOwnerBytes: \
                \not a request"

-- | Compute a refund output for a request.
computeRefund ::
    PParams ConwayEra ->
    Network ->
    Integer ->
    Integer ->
    TxOut ConwayEra ->
    TxOut ConwayEra
computeRefund pp net tipAmount perReqFee reqOut =
    let Coin reqVal = reqOut ^. coinTxOutL
        rawRefund =
            Coin (reqVal - tipAmount - perReqFee)
        refundAddr =
            addrFromKeyHashBytes
                net
                (extractOwnerBytes reqOut)
        draft =
            mkBasicTxOut
                refundAddr
                (inject rawRefund)
        minCoin = getMinCoinTxOut pp draft
     in mkBasicTxOut
            refundAddr
            (inject (max rawRefund minCoin))
