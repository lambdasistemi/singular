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

    -- * Pinned-hook invocation (NOTE-021)
    pinScriptHash,
    hookAccountAddress,
    keyAccountAddress,
    ConsumerBinding (..),
    deriveConsumerBinding,
    mkConsumerScript,

    -- * Failure attribution (NOTE-023)
    failedWitnessHash,
    isBudgetFailure,
) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Char (isHexDigit)
import Data.List (isInfixOf, isPrefixOf, tails)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Word (Word32)
import Lens.Micro ((&), (.~), (^.))

import Cardano.Crypto.Hash (hashFromBytes, hashToBytes)
import Cardano.Ledger.Address (AccountAddress (..), AccountId (..), Addr (..))
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

-- | Compute a rejected row's refund output (NOTE-014 item A2, delegated
-- routing): exactly `input lovelace − tip`, floored at min-UTxO with the
-- top-up funded visibly. No fee share is deducted here and none is
-- invented (fees ride funding inputs; the validator pins per-owner floors
-- and exact lock accumulation instead of an aggregate envelope). THE shared
-- helper for every rejected-refund emission — `Reject` and manual paths
-- call it; processed rows emit no refunds at all (their bond locks).
computeRefund ::
    PParams ConwayEra ->
    Network ->
    Integer ->
    TxOut ConwayEra ->
    TxOut ConwayEra
computeRefund pp net tipAmount reqOut =
    let Coin reqVal = reqOut ^. coinTxOutL
        rawRefund =
            Coin (reqVal - tipAmount)
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

-- ---------------------------------------------------------
-- Pinned-hook invocation (NOTE-020 item 1)
-- ---------------------------------------------------------

{- | The consumer pin as a ledger 'ScriptHash'. Loud on bad width
(the mint gate enforces 28 bytes on chain; this mirrors it
builder-side so a misconfigured pin fails at build, not on
ledger).
-}
pinScriptHash :: ByteString -> ScriptHash
pinScriptHash bs = case hashFromBytes bs of
    Just h -> ScriptHash h
    Nothing ->
        error
            "pinScriptHash: consumer pin must be 28 bytes"

{- | The withdrawal account for the pinned consumer: the exact script
credential from the pin, on the cage's network.
-}
hookAccountAddress :: Network -> ByteString -> AccountAddress
hookAccountAddress net pinBs =
    AccountAddress net (AccountId (ScriptHashObj (pinScriptHash pinBs)))

{- | A key-hash withdrawal account (exhibit controls only): lets a
row point a withdrawal at an ordinary key, where no script executes
and only the cage's own credential check can refuse. Loud on bad
width, like the pin helper above.
-}
keyAccountAddress :: Network -> ByteString -> AccountAddress
keyAccountAddress net khBs = case hashFromBytes khBs of
    Just h ->
        AccountAddress
            net
            ( AccountId
                ( KeyHashObj
                    (coerce (KeyHash h :: KeyHash Payment))
                )
            )
    Nothing ->
        error
            "keyAccountAddress: key hash must be 28 bytes"

{- | The bound exhibit consumer, unparameterized (NOTE-021): no
operator key, no appointed processor — the consumer authenticates
batches from transaction evidence alone. One derivation, used for
boot pinning, builder witnesses, and identity checks — never separate
computations that could disagree.
-}
data ConsumerBinding = ConsumerBinding
    { cbPin :: SBS.ShortByteString
    , cbScriptBytes :: SBS.ShortByteString
    , cbScript :: Script ConwayEra
    , cbHash :: ScriptHash
    }

deriveConsumerBinding ::
    SBS.ShortByteString -> ConsumerBinding
deriveConsumerBinding unapplied =
    let h = computeScriptHash unapplied
     in ConsumerBinding
            (SBS.toShort (scriptHashBytes h))
            unapplied
            (scriptFromBytes "consumer" unapplied)
            h

{- | Build the bound consumer 'Script' from config bytes (mirror of
'mkCageScript'). Builders attach this as the hook withdrawal witness.
-}
mkConsumerScript :: CageConfig -> Script ConwayEra
mkConsumerScript cfg =
    scriptFromBytes
        "mkConsumerScript"
        (cfgConsumerScript cfg)

-- ---------------------------------------------------------
-- Failure attribution (NOTE-023 item 2)
-- ---------------------------------------------------------

{- | Parse the node's named failed-witness field
(@The script hash is:ScriptHash "HEX"@) and return the hash — the
FIRST occurrence, which names the failing script (later occurrences
repeat the same failure's context). Anchored on the opening quote
(hash letters also occur in @ScriptHash@ itself, so a hex scan from
the marker misfires). Length-checked to 56 hex chars (a 28-byte
script hash) so partial garbage never matches. @Nothing@ when the
reason carries no named field (non-script failures: extraneous
witnesses, unregistered withdrawals, balance errors).
-}
failedWitnessHash :: String -> Maybe String
failedWitnessHash s =
    case findAfter "The script hash is:" s of
        Nothing -> Nothing
        Just rest -> case dropWhile (/= '"') rest of
            ('"' : after) ->
                let hex = takeWhile isHexDigit after
                 in if length hex == 56 then Just hex else Nothing
            _ -> Nothing
  where
    findAfter :: String -> String -> Maybe String
    findAfter needle hay =
        case
            [ drop (length needle) t
            | t <- tails hay
            , needle `isPrefixOf` t
            ] of
            (r : _) -> Just r
            [] -> Nothing

{- | True when the refusal is budget exhaustion rather than a semantic
predicate failure. Kept to the OBSERVED node wording
(@overspending the budget@); unknown budget wordings fail closed
elsewhere (no named semantic match), never silently accepted.
-}
isBudgetFailure :: String -> Bool
isBudgetFailure s = "overspending the budget" `isInfixOf` s

