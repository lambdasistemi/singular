{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.TxBuilder.Internal
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
module Singular.Registry.TxBuilder.Internal (
    -- * Script construction
    mkCageScript,
    mkRequestScript,
    scriptFromBytes,
    scriptHashBytes,
    computeScriptHash,

    -- * Registry-mode edges (#157 C2)
    leafAbsent,
    leafActive,
    leafTerminal,
    walkEdge,
    policyIdFromPin,
    addrFromBytes,
    deltaOf,
    policyOfKind,
    approvalName,

    -- * Derived identity
    cagePolicyIdFromCfg,
    cageAddrFromCfg,
    requestAddrFromCfg,
    onChainTokenId,

    -- * Datum helpers
    mkRequestDatum,
    mkRequestDatumWith,
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
    evalScriptHash,
    isBudgetFailure,
) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Char (isHexDigit)
import Data.List (isInfixOf, isPrefixOf, tails)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Word (Word32)
import Lens.Micro ((&), (.~), (^.))

import Cardano.Crypto.Hash (Blake2b_256, hashFromBytes, hashToBytes, hashWith)
import Cardano.Ledger.Address (AccountAddress (..), AccountId (..), Addr (..), decodeAddrEither)
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

import Cardano.Slotting.Slot (SlotNo)
import Cardano.Tx.Balance (
    BalanceResult (..),
    balanceTx,
 )
import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.Blueprint (
    applyRequestParams,
 )
import Singular.Registry.Config (
    CageConfig (..),
 )
import Singular.Registry.Ledger (
    AssetName (..),
    Coin (..),
    ConwayEra,
    PParams,
    TokenId (..),
 )
import Singular.Registry.Provider (Provider (..))
import Singular.Registry.Trie (Trie (..))
import Singular.Registry.Types (
    CageDatum (..),
    Edge,
    OnChainRequest (..),
    OnChainTokenId (..),
    OnChainTxOutRef (..),
    ProofStep,
    edgeDeleteAbsent,
    edgeDeleteActive,
    edgeInsertAbsent,
    edgeInsertActive,
    edgeUpdateActive,
    edgeUpdateTerminal,
 )

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

-- | Build a 'CageDatum' for a request at one C2 edge (#183).
mkRequestDatum ::
    TokenId ->
    Addr ->
    ByteString ->
    -- | The C2 row index the request names
    Edge ->
    -- | The deposit the request rides with, over and above the tip
    Integer ->
    Integer ->
    PLC.Data
mkRequestDatum tid addr key edge deposit submittedAt =
    mkRequestDatumWith
        tid
        addr
        key
        edge
        deposit
        submittedAt
        (BS.empty, BS.empty)

{- | A request datum naming where the edge it books delivers (#157
D-DEST). The cage reads the destination for every edge that mints an
active or terminal token, and the approval that certifies the edge binds
these same bytes, so the booking and the fold cannot disagree about where
the token goes.
-}
mkRequestDatumWith ::
    TokenId ->
    Addr ->
    ByteString ->
    -- | The C2 row index the request names
    Edge ->
    -- | The deposit the request rides with, over and above the tip
    Integer ->
    Integer ->
    (ByteString, ByteString) ->
    PLC.Data
mkRequestDatumWith tid addr key edge deposit submittedAt destination =
    let datum =
            OnChainRequest
                { requestToken = onChainTokenId tid
                , requestOwner =
                    BuiltinByteString
                        (addrKeyHashBytes addr)
                , requestKey = key
                , requestEdge = edge
                , requestDeposit = deposit
                , requestSubmittedAt = submittedAt
                , requestDestination = destination
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

{- | Compute a rejected row's refund output (NOTE-014 item A2, delegated
routing): exactly `input lovelace − tip`, floored at min-UTxO with the
top-up funded visibly. No fee share is deducted here and none is
invented (fees ride funding inputs; the validator pins per-owner floors
and exact lock accumulation instead of an aggregate envelope). THE shared
helper for every rejected-refund emission — `Reject` and manual paths
call it; processed rows emit no refunds at all (their bond locks).
-}
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

{- | Parse a builder-EVALUATION failure's named script field
(@pwcScriptHash = ScriptHash "HEX"@, first occurrence) and return
the hash. NOTE-018 bind: fork-occupied assertions match THIS field
against the derived applied identity — never a hex substring of the
full @ErrorCall@ show (transaction data, values and parameterized
script bytes can all contain the state policy). Same 56-hex rule.
-}
evalScriptHash :: String -> Maybe String
evalScriptHash s =
    case findAfter "pwcScriptHash = ScriptHash" s of
        Nothing -> Nothing
        Just rest -> case dropWhile (/= '"') rest of
            ('"' : after) ->
                let hex = takeWhile isHexDigit after
                 in if length hex == 56 then Just hex else Nothing
            _ -> Nothing

findAfter :: String -> String -> Maybe String
findAfter needle hay =
    case [ drop (length needle) t
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

-- ---------------------------------------------------------
-- Registry-mode edges (#157 C2)
-- ---------------------------------------------------------

{- | The three leaf states the registry admits (#157 D-CODEC). Requests
carry an edge, not a value, so these are no longer something a builder
chooses: they are the bytes each edge's trie move reads and writes, and
'walkEdge' below is the one place that pairs them with their edge.
-}
leafAbsent, leafActive, leafTerminal :: ByteString
leafAbsent = BS.singleton 0x00
leafActive = BS.singleton 0x01
leafTerminal = BS.singleton 0x02

{- | Walk one request's edge through a speculative trie and return the
proof steps the fold states for it (#183).

The edge names the move and its leaf bytes, from the table `types.ak`
publishes. The proof is the one the cage verifies at this request's own
position in the batch, so it is read BEFORE a delete or a replacement
and AFTER an insert, exactly as the cage's own walk does.

A tag outside the table names no move: the cage refuses it
`edge-inadmissible` before touching the trie, so the builder walks
nothing either and states the proof the refusal will be judged against.
A read (edge 6) leaves the leaf where it is (#157 C3).

One site, so the connected fold and the update builder cannot drift
apart about what an edge does to the trie.
-}
walkEdge :: (Monad m) => Trie m -> ByteString -> Edge -> m [ProofStep]
walkEdge trie key edge
    | edge == edgeInsertAbsent = inserting leafAbsent
    | edge == edgeInsertActive = inserting leafActive
    | edge == edgeUpdateActive = replacing leafActive
    | edge == edgeUpdateTerminal = replacing leafTerminal
    | edge == edgeDeleteAbsent = deleting
    | edge == edgeDeleteActive = deleting
    | otherwise = steps
  where
    steps = fromMaybe [] <$> getProofSteps trie key
    inserting leaf = do
        _ <- insert trie key leaf
        steps
    deleting = do
        before <- steps
        _ <- delete trie key
        pure before
    replacing leaf = do
        before <- steps
        _ <- delete trie key
        _ <- insert trie key leaf
        pure before

{- | What an edge owes the mint, as @(kind, quantity)@ over the three token
policies: kind 0 absent, 1 active, 2 terminal.
-}
deltaOf :: Integer -> [(Integer, Integer)]
deltaOf edge = case edge of
    0 -> [(0, 1)]
    1 -> [(1, 1)]
    2 -> [(0, -1), (1, 1)]
    3 -> [(1, -1)]
    4 -> [(0, -1)]
    5 -> [(1, -1)]
    6 -> [(2, 1)]
    _ -> []

-- | The policy a kind names in this registry's configuration.
policyOfKind :: CageConfig -> Integer -> SBS.ShortByteString
policyOfKind cfg kind = case kind of
    0 -> cfgAbsentPolicy cfg
    1 -> cfgActivePolicy cfg
    2 -> cfgTerminalPolicy cfg
    _ -> error "policyOfKind: not a token kind"

{- | The approval binding (#157 D-APPROVAL): the asset name the application
policy mints to certify one edge, @blake2b_256(edge ‖ key ‖ owner ‖
destination address ‖ destination datum hash)@. One formula, recomputed by
the cage from the request it rides; a builder that computes it differently
makes an honest booking refuse loudly at the fold.
-}
approvalName ::
    Integer ->
    -- | Registry key
    ByteString ->
    -- | Owner (the payment key hash the approval binds)
    ByteString ->
    -- | Destination: address bytes and datum hash
    (ByteString, ByteString) ->
    ByteString
approvalName edge key owner (destAddr, datumHash) =
    blake2b256
        ( BS.singleton (fromInteger edge)
            <> key
            <> owner
            <> destAddr
            <> datumHash
        )

blake2b256 :: ByteString -> ByteString
blake2b256 = hashToBytes . hashWith @Blake2b_256 id

{- | The policy id a 28-byte pin names. The four pins the state datum
carries are raw script hashes; this is the one place that turns one back
into the ledger's own type.
-}
policyIdFromPin :: SBS.ShortByteString -> PolicyID
policyIdFromPin pin = case hashFromBytes (SBS.fromShort pin) of
    Just h -> PolicyID (ScriptHash h)
    Nothing ->
        error
            ( "policyIdFromPin: a pin is not a 28-byte script hash: "
                <> show pin
            )

{- | The address a request's binary destination names (#157 D-DEST). The
bytes are a full Cardano address, network byte and all, so nothing here
supplies a network of its own.
-}
addrFromBytes :: ByteString -> Maybe Addr
addrFromBytes bs = case decodeAddrEither bs of
    Right a -> Just a
    Left _ -> Nothing
