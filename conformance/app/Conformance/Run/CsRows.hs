{- |
Module      : Conformance.Run.CsRows
Description : Split out of Conformance.Run (#263); see that module's header
License     : Apache-2.0
-}
module Conformance.Run.CsRows
    ( cs02Key
    , runCSSession
    , reportCSPartials
    , runCSRow
    , runSubmittedDatumByteRoundTrip
    , findStateDatum
    , findRequestDatum
    , isStateDatum
    , isRequestDatum
    , datumOfTxOut
    , readStateDatum
    , readRequestDatum
    , measureUnitsProv
    , emitMeasureProv
    , writeCSReceipt
    , runStateFieldsChainRoundTrip
    , stateDatumArity
    , expectedStateFromTx
    , runProofStepConstructorWitnesses
    , cs03KeyA
    , cs03KeyB
    , fastRetractCfgLocal
    , fastRejectCfgLocal
    , runUpdateRedeemerConstructorWitnesses
    , findRequestTxIn
    , runWrongRedeemerConstructorIndex
    , tamperModifyToBadIndex
    , attributeWrongRedeemerConstructorIndexRefusal
    , runRequestAndMintConstructorWitnesses
    , writeGapMigrating
    ) where

import Conformance.Replay (admittedFor)
import Conformance.Run.Cage (ensureStateRefWith)
import Conformance.Run.Control
import Conformance.Run.Environment
import Conformance.Run.Observe
import Conformance.Run.Receipts (debtReport)
import Conformance.Run.Replay
    ( ReplayIndex (..)
    , purposesOf
    , replayEvidenceOf
    , sessionCorrespondence
    )
import Conformance.Run.Submit
import Conformance.Run.Units
import Conformance.Run.Wallet

import Control.Concurrent (threadDelay)
import Control.Exception
    ( ErrorCall (..)
    , throwIO
    )
import Control.Monad (unless, void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.IORef (writeIORef)
import Data.List (intercalate, isInfixOf, nub)
import Data.List.NonEmpty (nonEmpty)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((&), (.~), (^.))
import System.FilePath ((</>))

import Cardano.Ledger.Plutus.Data (Data (..))

import Cardano.Ledger.Api.PParams
    ( ppMaxTxExUnitsL
    , ppMaxTxSizeL
    )
import Cardano.Ledger.Api.Scripts.Data
    ( Datum (..)
    )
import Cardano.Ledger.Api.Tx
    ( bodyTxL
    , mkBasicTx
    , witsTxL
    )
import Cardano.Ledger.Api.Tx.Body
    ( outputsTxBodyL
    , scriptIntegrityHashTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (datumTxOutL)
import Cardano.Ledger.Api.Tx.Wits
    ( Redeemers (..)
    , rdmrsTxWitsL
    , scriptTxWitsL
    )
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)

import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins.Internal (BuiltinByteString (..))
import Singular.Registry.Blueprint
    ( NamingCodes (..)
    , applyRequestParams
    )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger
    ( ConwayEra
    , ExUnits (..)
    , Root (..)
    , TokenId (..)
    , TxOut
    )
import Singular.Registry.Node
    ( Capabilities (..)
    , SubmitResult (..)
    , checkFunding
    , defaultFundingFloor
    , funderAddr
    , signTx
    , signedTx
    , submitSigned
    )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.Services qualified as Services
import Singular.Registry.Trie (TrieManager (..))
import Singular.Registry.Trie qualified as CageTrie
import Singular.Registry.Trie.PureManager (mkPureTrieManager)
import Singular.Registry.TxBuilder.Boot (bootTokenImpl)
import Singular.Registry.TxBuilder.Edges qualified as RegistryEdges
import Singular.Registry.TxBuilder.Internal
    ( cageAddrFromCfg
    , cagePolicyIdFromCfg
    , computeScriptHash
    , computeScriptIntegrity
    , extractCageDatum
    , findRequestUtxos
    , findStateUtxo
    , onChainTokenId
    , requestAddrFromCfg
    , scriptHashBytes
    , toPlcData
    , txInToRef
    , walkEdge
    )
import Singular.Registry.TxBuilder.Reject (rejectRequestsImpl)
import Singular.Registry.TxBuilder.Request
    ( requestEdgeImpl
    )
import Singular.Registry.TxBuilder.Retract (retractRequestImpl)
import Singular.Registry.TxBuilder.Update (updateTokenWithDuties)
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRequest (..)
    , OnChainRoot (..)
    , OnChainTokenState (..)
    , edgeInsertAbsent
    , edgeInsertActive
    )

import Conformance.Mirror
    ( emit
    , failWith
    , hex
    , readChainState
    , require
    , txIdHex
    )
import Conformance.Receipt
    ( ConstructorEvidence (..)
    , ConstructorStanding (..)
    , Outcome (..)
    , PartialInfo (..)
    , Receipt (..)
    , RefusalInfo (..)
    , ReplayCorrespondence
    , Verdict (..)
    , loadReceipts
    , writeReceiptFile
    )
import Conformance.Refusal
    ( matchRefusal
    , refusalScriptHashes
    , trimRefusal
    , wrongReasonMarker
    )

-- ---------------------------------------------------------
-- serialization devnet session (serialization boundary)
-- ---------------------------------------------------------

cs02Key :: ByteString
cs02Key = "cs02-key"

runCSSession
    :: [String]
    -> Control
    -> SBS.ShortByteString
    -> SBS.ShortByteString
    -> NamingCodes
    -> String
    -> String
    -> Bool
    -> FilePath
    -> Capabilities
    -> ReplayIndex
    -> IO ()
runCSSession rows control stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir caps replayIndex = do
    let prov = capReads caps
        submit = caps
    let stateMarker = hex (scriptHashBytes (computeScriptHash stateBytes))
        blueprintIdStr =
            "state:"
                <> stateMarker
                <> " request:"
                <> hex
                    (scriptHashBytes (computeScriptHash requestBytes))
    _ <- Cage.withView prov (pure . Cage.viewProtocolParams)
    checkFunding prov funderAddr defaultFundingFloor
    -- Every serialization row boots by reference: publish the state validator
    -- once, before any row picks its seed.
    ensureStateRefWith prov submit stateBytes
    mapM_
        ( \row -> do
            writeIORef (riRow replayIndex) (T.pack row)
            runCSRow
                replayIndex
                prov
                submit
                stateBytes
                requestBytes
                namingCodes
                nodeVer
                base
                dirty
                receiptsDir
                control
                blueprintIdStr
                row
        )
        rows
    emit
        "complete"
        (show (length rows) <> "/" <> show (length rows) <> " rows ok")
    -- Partial rows must never read as green: the session ends
    -- partial naming every such row (E18 §3/§4, NOTE-052). CI
    -- enumerates the known partial set; anything else is a failure.
    reportCSPartials receiptsDir rows
    -- An unmet row must never read as green either: the session ends with
    -- the same debt report a registry-operations session gives, naming it.
    reportCSUnmet receiptsDir rows

{- | Session-end accounting of the serialization rows kept unmet by ruling: receipts with
verdict @unmet-by-ruling@ among the rows just run end the session non-zero
with the debt report naming them.
-}
reportCSUnmet :: FilePath -> [String] -> IO ()
reportCSUnmet receiptsDir rows = do
    receipts <-
        loadReceipts receiptsDir
            >>= either (failWith . ("unmet accounting: " <>)) pure
    case [ T.unpack (receiptRow r)
         | r <- receipts
         , receiptVerdict r == UnmetByRuling
         , T.unpack (receiptRow r) `elem` rows
         ] of
        [] -> pure ()
        unmet -> throwIO (ErrorCall (debtReport [] unmet []))

{- | Session-end partial accounting for the serialization rows: receipts with
verdict partial among the rows just run end the session with the
specifically accounted partial status (exit 1, distinct report).
A loader rejection (including a success verdict carrying partial
constructors) fails the session as invalid evidence.
-}
reportCSPartials :: FilePath -> [String] -> IO ()
reportCSPartials receiptsDir rows = do
    loaded <- loadReceipts receiptsDir
    receipts <- case loaded of
        Left err -> failWith ("partial accounting: " <> err)
        Right rs -> pure rs
    let partials =
            [ T.unpack (receiptRow r)
            | r <- receipts
            , receiptVerdict r == Partial
            , T.unpack (receiptRow r) `elem` rows
            ]
    case partials of
        [] -> pure ()
        _ ->
            throwIO
                ( ErrorCall
                    ( "ROWS PARTIAL: named constructors stay unexercised; "
                        <> "receipts carry the exact residuals"
                        <> "\n- Partial: "
                        <> unwords partials
                        <> "\nThese rows are the milestone owner's known partial debt (E18 completes at rebase)."
                    )
                )

runCSRow
    :: ReplayIndex
    -> Cage.Provider IO
    -> Capabilities
    -> SBS.ShortByteString
    -> SBS.ShortByteString
    -> NamingCodes
    -> String
    -> String
    -> Bool
    -> FilePath
    -> Control
    -> String
    -> String
    -> IO ()
runCSRow index prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr row = case row of
    "submitted-datum-byte-round-trip" ->
        runSubmittedDatumByteRoundTrip
            prov
            submit
            stateBytes
            requestBytes
            namingCodes
            nodeVer
            base
            dirty
            receiptsDir
            control
            blueprintIdStr
    "update-redeemer-constructor-witnesses" ->
        runUpdateRedeemerConstructorWitnesses
            prov
            submit
            stateBytes
            requestBytes
            namingCodes
            nodeVer
            base
            dirty
            receiptsDir
            control
            blueprintIdStr
    "wrong-redeemer-constructor-index" ->
        runWrongRedeemerConstructorIndex
            index
            prov
            submit
            stateBytes
            requestBytes
            namingCodes
            nodeVer
            base
            dirty
            receiptsDir
            control
            blueprintIdStr
    "request-and-mint-constructor-witnesses" ->
        runRequestAndMintConstructorWitnesses
            prov
            submit
            stateBytes
            requestBytes
            namingCodes
            nodeVer
            base
            dirty
            receiptsDir
            control
            blueprintIdStr
    "proof-step-constructor-witnesses" ->
        runProofStepConstructorWitnesses
            prov
            submit
            stateBytes
            requestBytes
            namingCodes
            nodeVer
            base
            dirty
            receiptsDir
            control
            blueprintIdStr
    "state-fields-chain-round-trip" ->
        runStateFieldsChainRoundTrip
            prov
            submit
            stateBytes
            requestBytes
            namingCodes
            nodeVer
            base
            dirty
            receiptsDir
            control
            blueprintIdStr
    _ -> failWith ("serialization row not yet implemented: " <> row)

{- | submitted-datum-byte-round-trip: datum bytes constructed in Haskell and submitted are read
back identical (byte-compare submitted vs chain-observed).
-}
runSubmittedDatumByteRoundTrip
    :: Cage.Provider IO
    -> Capabilities
    -> SBS.ShortByteString
    -> SBS.ShortByteString
    -> NamingCodes
    -> String
    -> String
    -> Bool
    -> FilePath
    -> Control
    -> String
    -> IO ()
runSubmittedDatumByteRoundTrip prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr = do
    (seedTxIn, _) <- largestWalletUtxo prov
    let cfg = cageCfg stateBytes requestBytes namingCodes (txInToRef seedTxIn)
    unsignedBoot <-
        Cage.withView prov (\v -> bootTokenImpl cfg v genesisAddr)
    let submittedStateDatum = findStateDatum unsignedBoot
    (mem, cpu) <- measureUnitsProv prov unsignedBoot
    signedBoot <- submitWithGenesis submit unsignedBoot
    tid <- extractTokenId cfg signedBoot
    unsignedReq <-
        Cage.withView prov $ \v ->
            requestEdgeImpl
                cfg
                v
                (defaultTip cfg)
                tid
                cs02Key
                edgeInsertActive
                genesisAddr
    let submittedReqDatum = findRequestDatum cs02Key unsignedReq
    signedReq <- submitWithGenesis submit unsignedReq
    observedStateDatum <- readStateDatum prov cfg tid
    observedReqDatum <- readRequestDatum prov cfg tid cs02Key
    case control of
        FalseDatum -> do
            emit
                "control"
                "false-datum armed: demanding state bytes match request bytes"
            require
                "submitted-datum-byte-round-trip: submitted state bytes differ from chain-observed (control)"
                (submittedStateDatum == submittedReqDatum)
        _ -> do
            require
                ( "submitted-datum-byte-round-trip: state datum bytes differ: submitted "
                    <> show submittedStateDatum
                    <> " vs chain "
                    <> show observedStateDatum
                )
                (submittedStateDatum == observedStateDatum)
            require
                ( "submitted-datum-byte-round-trip: request datum bytes differ: submitted "
                    <> show submittedReqDatum
                    <> " vs chain "
                    <> show observedReqDatum
                )
                (submittedReqDatum == observedReqDatum)
    let sizeBoot = txSizeBytes signedBoot
        sizeReq = txSizeBytes signedReq
        size = max sizeBoot sizeReq
    emitMeasureProv prov "submitted-datum-byte-round-trip" mem cpu size
    writeCSReceipt
        receiptsDir
        "submitted-datum-byte-round-trip"
        Accepted
        AgreesWithModel
        [txIdHex signedBoot, txIdHex signedReq]
        Nothing
        Nothing
        (Just mem)
        (Just cpu)
        (Just size)
        "node-submit"
        base
        dirty
        nodeVer
        blueprintIdStr
        Nothing
    emit
        "row"
        "submitted-datum-byte-round-trip: ACCEPTED datum bytes identical (state+request)"

-- | Find the state inline datum in an unsigned transaction's outputs.
findStateDatum :: ConwayTx -> Datum ConwayEra
findStateDatum tx =
    case [ d
         | out <- toList (tx ^. bodyTxL . outputsTxBodyL)
         , isStateDatum out
         , Just d <- [datumOfTxOut out]
         ] of
        [d] -> d
        _ ->
            error
                "submitted-datum-byte-round-trip: unsigned tx has no single state datum"

-- | Find the request inline datum for a key in an unsigned tx.
findRequestDatum :: ByteString -> ConwayTx -> Datum ConwayEra
findRequestDatum key tx =
    case [ d
         | out <- toList (tx ^. bodyTxL . outputsTxBodyL)
         , isRequestDatum key out
         , Just d <- [datumOfTxOut out]
         ] of
        [d] -> d
        _ ->
            error
                "submitted-datum-byte-round-trip: unsigned tx has no single request datum"

isStateDatum :: TxOut ConwayEra -> Bool
isStateDatum out = case extractCageDatum out of
    Just (StateDatum _) -> True
    _ -> False

isRequestDatum :: ByteString -> TxOut ConwayEra -> Bool
isRequestDatum key out = case extractCageDatum out of
    Just (RequestDatum rq) -> requestKey rq == key
    _ -> False

datumOfTxOut :: TxOut ConwayEra -> Maybe (Datum ConwayEra)
datumOfTxOut out = case out ^. datumTxOutL of
    d@(Datum _) -> Just d
    _ -> Nothing

readStateDatum
    :: Cage.Provider IO -> CageConfig -> TokenId -> IO (Datum ConwayEra)
readStateDatum prov cfg tid = do
    utxos <-
        Cage.withView
            prov
            (`Cage.viewUTxOsAt` cageAddrFromCfg cfg (network cfg))
    case findStateUtxo (cagePolicyIdFromCfg cfg) tid utxos of
        Nothing -> failWith "submitted-datum-byte-round-trip: no state UTxO on chain"
        Just (_, out) -> case datumOfTxOut out of
            Just d -> pure d
            Nothing ->
                failWith
                    "submitted-datum-byte-round-trip: state UTxO has no inline datum"

readRequestDatum
    :: Cage.Provider IO
    -> CageConfig
    -> TokenId
    -> ByteString
    -> IO (Datum ConwayEra)
readRequestDatum prov cfg tid key = do
    utxos <-
        Cage.withView
            prov
            (`Cage.viewUTxOsAt` requestAddrFromCfg cfg tid (network cfg))
    let reqs = findRequestUtxos tid utxos
        matching = [out | (_, out) <- reqs, isRequestDatum key out]
    case matching of
        [out] -> case datumOfTxOut out of
            Just d -> pure d
            Nothing ->
                failWith
                    "submitted-datum-byte-round-trip: request UTxO has no inline datum"
        _ ->
            failWith
                ( "submitted-datum-byte-round-trip: expected one request UTxO for key, found "
                    <> show (length matching)
                )

-- | Measure execution units via the node, while inputs are unspent.
measureUnitsProv
    :: Cage.Provider IO -> ConwayTx -> IO (Integer, Integer)
measureUnitsProv prov tx = do
    evalMap <- Cage.withView prov (`Services.evaluateTx` tx)
    let evalStr = Map.map (either (Left . show) Right) evalMap
    units <- case sequence evalStr of
        Left e -> failWith ("measure: node evaluation failed: " <> e)
        Right m -> pure (Map.elems m)
    let mem = sum [m | ExUnits m _ <- units]
        cpu = sum [s | ExUnits _ s <- units]
    pure (fromIntegral mem, fromIntegral cpu)

-- | Emit one fold's units and size against the devnet maxima.
emitMeasureProv
    :: Cage.Provider IO -> String -> Integer -> Integer -> Integer -> IO ()
emitMeasureProv prov label mem cpu size = do
    pp <- Cage.withView prov (pure . Cage.viewProtocolParams)
    let ExUnits maxMem maxSteps = pp ^. ppMaxTxExUnitsL
        maxSize = fromIntegral (pp ^. ppMaxTxSizeL) :: Integer
        pct :: Integer -> Integer -> Double
        pct used maxV = fromIntegral used / fromIntegral maxV * 100 :: Double
    emit
        "measure"
        ( label
            <> " mem="
            <> show mem
            <> "/"
            <> show maxMem
            <> " cpu="
            <> show cpu
            <> "/"
            <> show maxSteps
            <> " size="
            <> show size
            <> "/"
            <> show maxSize
            <> " ("
            <> show (pct size maxSize)
            <> "%)"
        )

writeCSReceipt
    :: FilePath
    -> String
    -> Outcome
    -> Verdict
    -> [String]
    -> Maybe RefusalInfo
    -> Maybe String
    -> Maybe Integer
    -> Maybe Integer
    -> Maybe Integer
    -> T.Text
    -> String
    -> Bool
    -> String
    -> String
    -> Maybe PartialInfo
    -> IO ()
writeCSReceipt = writeCSReceiptWith Nothing

-- | A serialization receipt stating the traced build its refusal's replay relies on.
writeCSReceiptWith
    :: Maybe ReplayCorrespondence
    -> FilePath
    -> String
    -> Outcome
    -> Verdict
    -> [String]
    -> Maybe RefusalInfo
    -> Maybe String
    -> Maybe Integer
    -> Maybe Integer
    -> Maybe Integer
    -> T.Text
    -> String
    -> Bool
    -> String
    -> String
    -> Maybe PartialInfo
    -> IO ()
writeCSReceiptWith correspondence dir row outcome verdict txs refusal rejected mem cpu size venue base dirty nodeVer blueprintIdStr partial =
    writeReceiptFile dir $
        Receipt
            { receiptRow = T.pack row
            , receiptOutcome = outcome
            , receiptVerdict = verdict
            , receiptTransactions = map T.pack txs
            , receiptRefusal = refusal
            , receiptRejected = fmap T.pack rejected
            , receiptMem = mem
            , receiptCpu = cpu
            , receiptTxSize = size
            , receiptBase = T.pack base
            , receiptDirty = dirty
            , receiptPartial = partial
            , receiptDerivation = Nothing
            , receiptSteps = Nothing
            , receiptReplayCorrespondence = correspondence
            , receiptNode = T.pack nodeVer
            , receiptBlueprint = T.pack blueprintIdStr
            , receiptVenue = venue
            }

{- | state-fields-chain-round-trip (#157 X1): the eight fields of `OnChainTokenState` survive a
chain round trip, with the ACTIVE policy varied Base versus Alt
(NOTE-046: no stake script exists to vary; #157 state-datum-fields renamed the field
this row always varied). The four pinned policies are the ones genesis-policy-pins
derives — the application policy from the naming application script and
the three token policies from `witness(kind, registry)` applied — so
this row is also what says the derivation reaches the chain intact.
-}
runStateFieldsChainRoundTrip
    :: Cage.Provider IO
    -> Capabilities
    -> SBS.ShortByteString
    -> SBS.ShortByteString
    -> NamingCodes
    -> String
    -> String
    -> Bool
    -> FilePath
    -> Control
    -> String
    -> IO ()
runStateFieldsChainRoundTrip prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr = do
    -- Base cage: all four pins derived for its own registry identity.
    (seedBase, _) <- largestWalletUtxo prov
    let cfgBase = cageCfg stateBytes requestBytes namingCodes (txInToRef seedBase)
    unsignedBootBase <-
        Cage.withView prov (\v -> bootTokenImpl cfgBase v genesisAddr)
    (mem1, cpu1) <- measureUnitsProv prov unsignedBootBase
    signedBootBase <- submitWithGenesis submit unsignedBootBase
    tidBase <- extractTokenId cfgBase signedBootBase
    observedBase <- readChainState cfgBase prov tidBase
    expectedBase <- expectedStateFromTx unsignedBootBase
    -- Alt cage: one variable moves, the active policy, so the pair
    -- discriminates on exactly that field.
    (seedAlt, _) <- largestWalletUtxo prov
    let cfgAlt0 = cageCfg stateBytes requestBytes namingCodes (txInToRef seedAlt)
        cfgAlt = cfgAlt0{cfgActivePolicy = SBS.pack (replicate 28 7)}
    unsignedBootAlt <-
        Cage.withView prov (\v -> bootTokenImpl cfgAlt v genesisAddr)
    (mem2, cpu2) <- measureUnitsProv prov unsignedBootAlt
    signedBootAlt <- submitWithGenesis submit unsignedBootAlt
    tidAlt <- extractTokenId cfgAlt signedBootAlt
    observedAlt <- readChainState cfgAlt prov tidAlt
    expectedAlt <- expectedStateFromTx unsignedBootAlt
    case control of
        FalseDatum -> do
            emit "control" "false-datum armed: demanding Base==Alt"
            require
                "state-fields-chain-round-trip: Base and Alt states unexpectedly match (control)"
                (observedBase == observedAlt)
        LegacySixField -> do
            emit
                "control"
                "state-fields-chain-round-trip ARMED (legacy-six-field): demanding the retired \
                \six-field state encoding of the chain's own datum"
            require
                ( "state-fields-chain-round-trip: the chain state encodes "
                    <> show (stateDatumArity observedBase)
                    <> " fields, not the six the retired contract had"
                )
                (stateDatumArity observedBase == 6)
        _ -> do
            require
                ( "state-fields-chain-round-trip: Base state fields differ: expected "
                    <> show expectedBase
                    <> " vs chain "
                    <> show observedBase
                )
                (expectedBase == observedBase)
            require
                ( "state-fields-chain-round-trip: Alt state fields differ: expected "
                    <> show expectedAlt
                    <> " vs chain "
                    <> show observedAlt
                )
                (expectedAlt == observedAlt)
            -- The eight fields, each explicitly, against the boot tx.
            require
                "state-fields-chain-round-trip: Base root mismatch"
                (stateRoot observedBase == stateRoot expectedBase)
            require
                "state-fields-chain-round-trip: Alt root mismatch"
                (stateRoot observedAlt == stateRoot expectedAlt)
            require
                "state-fields-chain-round-trip: Base tip mismatch"
                (stateMaxFee observedBase == stateMaxFee expectedBase)
            require
                "state-fields-chain-round-trip: Alt tip mismatch"
                (stateMaxFee observedAlt == stateMaxFee expectedAlt)
            require
                "state-fields-chain-round-trip: Base processTime mismatch"
                (stateProcessTime observedBase == stateProcessTime expectedBase)
            require
                "state-fields-chain-round-trip: Alt processTime mismatch"
                (stateProcessTime observedAlt == stateProcessTime expectedAlt)
            require
                "state-fields-chain-round-trip: Base retractTime mismatch"
                (stateRetractTime observedBase == stateRetractTime expectedBase)
            require
                "state-fields-chain-round-trip: Alt retractTime mismatch"
                (stateRetractTime observedAlt == stateRetractTime expectedAlt)
            require
                "state-fields-chain-round-trip: Base applicationPolicy mismatch"
                (stateAppPolicy observedBase == stateAppPolicy expectedBase)
            require
                "state-fields-chain-round-trip: Alt applicationPolicy mismatch"
                (stateAppPolicy observedAlt == stateAppPolicy expectedAlt)
            require
                "state-fields-chain-round-trip: Base activePolicy mismatch"
                (stateActivePolicy observedBase == stateActivePolicy expectedBase)
            require
                "state-fields-chain-round-trip: Alt activePolicy mismatch"
                (stateActivePolicy observedAlt == stateActivePolicy expectedAlt)
            require
                "state-fields-chain-round-trip: Base absentPolicy mismatch"
                (stateAbsentPolicy observedBase == stateAbsentPolicy expectedBase)
            require
                "state-fields-chain-round-trip: Alt absentPolicy mismatch"
                (stateAbsentPolicy observedAlt == stateAbsentPolicy expectedAlt)
            require
                "state-fields-chain-round-trip: Base terminalPolicy mismatch"
                (stateTerminalPolicy observedBase == stateTerminalPolicy expectedBase)
            require
                "state-fields-chain-round-trip: Alt terminalPolicy mismatch"
                (stateTerminalPolicy observedAlt == stateTerminalPolicy expectedAlt)
            -- The varied field discriminates; the held fields are stable.
            require
                "state-fields-chain-round-trip: Base and Alt activePolicy unexpectedly match"
                (stateActivePolicy observedBase /= stateActivePolicy observedAlt)
            require
                "state-fields-chain-round-trip: applicationPolicy moved between cages"
                (stateAppPolicy observedBase == stateAppPolicy observedAlt)
            -- genesis-policy-pins: the pins are DERIVED. A placeholder would be all
            -- zeroes, and the three token policies are three distinct
            -- applications of one script, so they cannot coincide.
            require
                "state-fields-chain-round-trip: a pinned policy is a placeholder (28 zero bytes)"
                ( BuiltinByteString (BS.replicate 28 0)
                    `notElem` [ stateAppPolicy observedBase
                              , stateActivePolicy observedBase
                              , stateAbsentPolicy observedBase
                              , stateTerminalPolicy observedBase
                              ]
                )
            require
                "state-fields-chain-round-trip: the three derived token policies are not distinct"
                ( let ps =
                        [ stateActivePolicy observedBase
                        , stateAbsentPolicy observedBase
                        , stateTerminalPolicy observedBase
                        ]
                  in  length (nub ps) == 3
                )
    let mem = max mem1 mem2
        cpu = max cpu1 cpu2
        size = max (txSizeBytes signedBootBase) (txSizeBytes signedBootAlt)
    emitMeasureProv prov "state-fields-chain-round-trip" mem cpu size
    writeCSReceipt
        receiptsDir
        "state-fields-chain-round-trip"
        Accepted
        AgreesWithModel
        [txIdHex signedBootBase, txIdHex signedBootAlt]
        Nothing
        Nothing
        (Just mem)
        (Just cpu)
        (Just size)
        "node-submit"
        base
        dirty
        nodeVer
        blueprintIdStr
        Nothing
    emit
        "row"
        "state-fields-chain-round-trip: ACCEPTED eight fields survive (Base+AltActivePolicy)"

{- | How many fields the state datum actually encodes. The retired
contract had six; #157 state-datum-fields made it eight, and the armed control demands
the old arity so the row is shown able to notice a regression.
-}
stateDatumArity :: OnChainTokenState -> Int
stateDatumArity st = case toPlcData st of
    PLC.Constr _ fields -> length fields
    _ -> -1

expectedStateFromTx :: ConwayTx -> IO OnChainTokenState
expectedStateFromTx tx =
    case [ s
         | out <- toList (tx ^. bodyTxL . outputsTxBodyL)
         , Just (StateDatum s) <- [extractCageDatum out]
         ] of
        [s] -> pure s
        _ ->
            failWith
                "state-fields-chain-round-trip: unsigned boot has no single StateDatum"

{- | proof-step-constructor-witnesses: sequential absence folds exercise Leaf, lone Fork and Branch.
The C fold uses the exact historical C-over-{A,B} regression; D and E
widen the trie until a Branch is witnessed by another accepted fold.
-}
runProofStepConstructorWitnesses
    :: Cage.Provider IO
    -> Capabilities
    -> SBS.ShortByteString
    -> SBS.ShortByteString
    -> NamingCodes
    -> String
    -> String
    -> Bool
    -> FilePath
    -> Control
    -> String
    -> IO ()
runProofStepConstructorWitnesses prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr = do
    tm <- mkPureTrieManager
    (seed, _) <- largestWalletUtxo prov
    let cfg = cageCfg stateBytes requestBytes namingCodes (txInToRef seed)
    unsignedBoot <-
        Cage.withView prov (\v -> bootTokenImpl cfg v genesisAddr)
    signedBoot <- submitWithGenesis submit unsignedBoot
    tid <- extractTokenId cfg signedBoot
    createTrie tm tid
    refs <-
        RegistryEdges.publishCageRefs
            cfg
            namingCodes
            prov
            (submitWithGenesis submit)
            genesisAddr
            tid
    folds <-
        mapM
            (insertWitness cfg tm tid refs)
            [ ("cs07-fork-A", [])
            , ("cs07-fork-B1294", [2])
            , ("cs07-fork-C11", [1])
            , ("cs07-fork-D127", [2, 1])
            , ("cs07-fork-E400", [2, 0])
            ]
    let observed = concat [proofStepConstrs tx | (tx, _, _) <- folds]
        witnessed = case control of
            MissingWitness -> filter (/= 1) observed
            _ -> observed
        mem = maximum [m | (_, m, _) <- folds]
        cpu = maximum [c | (_, _, c) <- folds]
        size = maximum [txSizeBytes tx | (tx, _, _) <- folds]
    require
        "proof-step-constructor-witnesses: missing accepted ProofStep witness"
        (all (`elem` witnessed) [0, 1, 2])
    emitMeasureProv prov "proof-step-constructor-witnesses" mem cpu size
    writeCSReceipt
        receiptsDir
        "proof-step-constructor-witnesses"
        Accepted
        AgreesWithModel
        (txIdHex signedBoot : [txIdHex tx | (tx, _, _) <- folds])
        Nothing
        Nothing
        (Just mem)
        (Just cpu)
        (Just size)
        "node-submit"
        base
        dirty
        nodeVer
        blueprintIdStr
        Nothing
    emit
        "row"
        "proof-step-constructor-witnesses: ACCEPTED Branch/Fork/Leaf and Neighbor; C-over-{A,B} absence folded"
  where
    insertWitness cfg tm tid refs (key, expectedSteps) = do
        _ <-
            RegistryEdges.bookEdge
                cfg
                namingCodes
                prov
                (submitWithGenesis submit)
                genesisAddr
                tid
                key
                edgeInsertAbsent
        unsignedFold <- Cage.withView prov $ \v -> do
            ctx <- RegistryEdges.registryContextFor cfg namingCodes v refs
            updateTokenWithDuties cfg v tm tid genesisAddr ctx
        require
            ( "proof-step-constructor-witnesses: unexpected proof for "
                <> show key
                <> ": "
                <> show (proofStepConstrs unsignedFold)
            )
            (proofStepConstrs unsignedFold == expectedSteps)
        require
            "proof-step-constructor-witnesses: malformed Fork Neighbor"
            (forkNeighborsWellFormed unsignedFold)
        (mem, cpu) <- measureUnitsProv prov unsignedFold
        signedFold <- submitWithGenesis submit unsignedFold
        root <- withTrie tm tid $ \trie -> do
            _ <- walkEdge trie key edgeInsertAbsent
            CageTrie.getRoot trie
        observed <- readChainState cfg prov tid
        require
            "proof-step-constructor-witnesses: chain root differs from committed trie"
            (unOnChainRoot (stateRoot observed) == unRoot root)
        emit
            "proof-step-constructor-witnesses-fold"
            ( show key
                <> " steps="
                <> show expectedSteps
                <> " txid="
                <> txIdHex signedFold
            )
        pure (signedFold, mem, cpu)

cs03KeyA, cs03KeyB :: ByteString
cs03KeyA = "cs03-modify-key"
cs03KeyB = "cs03-retract-key"

fastRetractCfgLocal :: CageConfig -> CageConfig
fastRetractCfgLocal cfg =
    cfg
        { defaultProcessTime = 1_000
        , defaultRetractTime = 30_000
        }

fastRejectCfgLocal :: CageConfig -> CageConfig
fastRejectCfgLocal cfg =
    cfg
        { defaultProcessTime = 1_000
        , defaultRetractTime = 1_000
        }

runUpdateRedeemerConstructorWitnesses
    :: Cage.Provider IO
    -> Capabilities
    -> SBS.ShortByteString
    -> SBS.ShortByteString
    -> NamingCodes
    -> String
    -> String
    -> Bool
    -> FilePath
    -> Control
    -> String
    -> IO ()
runUpdateRedeemerConstructorWitnesses prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr = do
    tm <- mkPureTrieManager
    (seedA, _) <- largestWalletUtxo prov
    let cfgA = cageCfg stateBytes requestBytes namingCodes (txInToRef seedA)
    unsignedBootA <-
        Cage.withView prov (\v -> bootTokenImpl cfgA v genesisAddr)
    (memBootA, cpuBootA) <- measureUnitsProv prov unsignedBootA
    signedBootA <- submitWithGenesis submit unsignedBootA
    tidA <- extractTokenId cfgA signedBootA
    createTrie tm tidA
    refsA <-
        RegistryEdges.publishCageRefs
            cfgA
            namingCodes
            prov
            (submitWithGenesis submit)
            genesisAddr
            tidA
    _ <-
        RegistryEdges.bookEdge
            cfgA
            namingCodes
            prov
            (submitWithGenesis submit)
            genesisAddr
            tidA
            cs03KeyA
            edgeInsertActive
    unsignedFoldA <- Cage.withView prov $ \v -> do
        ctxA <- RegistryEdges.registryContextFor cfgA namingCodes v refsA
        updateTokenWithDuties cfgA v tm tidA genesisAddr ctxA
    require
        "update-redeemer-constructor-witnesses: Modify witness missing Constr 2"
        (2 `elem` spendingConstrs unsignedFoldA)
    require
        "update-redeemer-constructor-witnesses: Contribute witness missing Constr 1"
        (1 `elem` spendingConstrs unsignedFoldA)
    (memFold, cpuFold) <- measureUnitsProv prov unsignedFoldA
    signedFoldA <- submitWithGenesis submit unsignedFoldA
    _ <- withTrie tm tidA $ \t ->
        void (walkEdge t cs03KeyA edgeInsertActive)
    (seedB, _) <- largestWalletUtxo prov
    let cfgB =
            fastRetractCfgLocal
                (cageCfg stateBytes requestBytes namingCodes (txInToRef seedB))
    unsignedBootB <-
        Cage.withView prov (\v -> bootTokenImpl cfgB v genesisAddr)
    (memBootB, cpuBootB) <- measureUnitsProv prov unsignedBootB
    signedBootB <- submitWithGenesis submit unsignedBootB
    tidB <- extractTokenId cfgB signedBootB
    createTrie tm tidB
    unsignedReqB <-
        Cage.withView prov $ \v ->
            requestEdgeImpl
                cfgB
                v
                (defaultTip cfgB)
                tidB
                cs03KeyB
                edgeInsertActive
                genesisAddr
    _ <- submitWithGenesis submit unsignedReqB
    reqTxInB <- findRequestTxIn prov cfgB tidB cs03KeyB
    threadDelay 3_000_000
    unsignedRetract <-
        Cage.withView
            prov
            (\v -> retractRequestImpl cfgB v tidB reqTxInB genesisAddr)
    require
        "update-redeemer-constructor-witnesses: Retract witness missing Constr 3"
        (3 `elem` spendingConstrs unsignedRetract)
    (memRetract, cpuRetract) <- measureUnitsProv prov unsignedRetract
    signedRetract <- submitWithGenesis submit unsignedRetract
    let got =
            [ 2 `elem` spendingConstrs signedFoldA
            , 1 `elem` spendingConstrs signedFoldA
            , 3 `elem` spendingConstrs signedRetract
            ]
        labels = ["Modify", "Contribute", "Retract"] :: [String]
        missing = [l | (False, l) <- zip got labels]
    case control of
        MissingWitness -> do
            -- Deliberately FALSE demand on an accepted tx (NOTE-058):
            -- the Retract tx carries Retract 3, so demanding it
            -- absent must fail with exactly this message. A control
            -- that passes on the valid path proves nothing; the
            -- failure below is the evidence it can fail.
            emit
                "control"
                "missing-witness armed: demanding Retract absent from its own tx (deliberately false)"
            require
                "update-redeemer-constructor-witnesses: Retract unexpectedly absent from its own tx (control)"
                (3 `notElem` spendingConstrs signedRetract)
        _ ->
            require
                ( "update-redeemer-constructor-witnesses: missing accept witnesses: "
                    <> show missing
                )
                (null missing)
    let mem = maximum [memBootA, memFold, memBootB, memRetract]
        cpu = maximum [cpuBootA, cpuFold, cpuBootB, cpuRetract]
        size =
            maximum
                [ txSizeBytes signedBootA
                , txSizeBytes signedFoldA
                , txSizeBytes signedBootB
                , txSizeBytes signedRetract
                ]
    emitMeasureProv
        prov
        "update-redeemer-constructor-witnesses"
        mem
        cpu
        size
    writeCSReceipt
        receiptsDir
        "update-redeemer-constructor-witnesses"
        Accepted
        Partial
        [txIdHex signedFoldA, txIdHex signedRetract]
        Nothing
        Nothing
        (Just mem)
        (Just cpu)
        (Just size)
        "node-submit"
        base
        dirty
        nodeVer
        blueprintIdStr
        ( Just
            ( PartialInfo
                [ ConstructorEvidence
                    "Modify"
                    2
                    StandingAccepted
                    (T.pack (txIdHex signedFoldA))
                , ConstructorEvidence
                    "Contribute"
                    1
                    StandingAccepted
                    (T.pack (txIdHex signedFoldA))
                , ConstructorEvidence
                    "Retract"
                    3
                    StandingAccepted
                    (T.pack (txIdHex signedRetract))
                , ConstructorEvidence
                    "End"
                    0
                    StandingResidual
                    "state.ak End refuses every party (ownerless NOTE-028/A-003; builder removed f3a68b1); no accepting path; E18 completes at rebase"
                , ConstructorEvidence
                    "Sweep"
                    4
                    StandingResidual
                    "request.ak Sweep refuses every party (ownerless NOTE-028/A-003; builder removed f3a68b1); no accepting path; E18 completes at rebase"
                ]
            )
        )
    emit
        "row"
        "update-redeemer-constructor-witnesses: PARTIAL Contribute/Modify/Retract executed; End/Sweep named residuals (E18)"

findRequestTxIn
    :: Cage.Provider IO -> CageConfig -> TokenId -> ByteString -> IO TxIn
findRequestTxIn prov cfg tid key = do
    utxos <-
        Cage.withView
            prov
            (`Cage.viewUTxOsAt` requestAddrFromCfg cfg tid (network cfg))
    let matching =
            [i | (i, out) <- findRequestUtxos tid utxos, isRequestDatum key out]
    case matching of
        [found] -> pure found
        _ ->
            failWith
                ( "findRequestTxIn: expected one request for key, found "
                    <> show (length matching)
                )

{- | wrong-redeemer-constructor-index: wrong constructor index refused, attributed to the script. The
model has no vocabulary for decoding a redeemer, so there is no model reason
to compare: the model comparison is unmet (#347).
-}
runWrongRedeemerConstructorIndex
    :: ReplayIndex
    -> Cage.Provider IO
    -> Capabilities
    -> SBS.ShortByteString
    -> SBS.ShortByteString
    -> NamingCodes
    -> String
    -> String
    -> Bool
    -> FilePath
    -> Control
    -> String
    -> IO ()
runWrongRedeemerConstructorIndex index prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr = do
    tm <- mkPureTrieManager
    (seed, _) <- largestWalletUtxo prov
    let cfg = cageCfg stateBytes requestBytes namingCodes (txInToRef seed)
    unsignedBoot <-
        Cage.withView prov (\v -> bootTokenImpl cfg v genesisAddr)
    signedBoot <- submitWithGenesis submit unsignedBoot
    tid <- extractTokenId cfg signedBoot
    createTrie tm tid
    refs <-
        RegistryEdges.publishCageRefs
            cfg
            namingCodes
            prov
            (submitWithGenesis submit)
            genesisAddr
            tid
    _ <-
        RegistryEdges.bookEdge
            cfg
            namingCodes
            prov
            (submitWithGenesis submit)
            genesisAddr
            tid
            "cs04-key"
            edgeInsertActive
    unsignedFold <- Cage.withView prov $ \v -> do
        ctx <- RegistryEdges.registryContextFor cfg namingCodes v refs
        updateTokenWithDuties cfg v tm tid genesisAddr ctx
    badTx <- tamperModifyToBadIndex prov unsignedFold
    let badSigned = signTx genesisSignKey badTx
        signedBad = signedTx badSigned
    result <- submitSigned (capSubmit submit) badSigned
    let deployedState = computeScriptHash stateBytes
        stateMarker = hex (scriptHashBytes deployedState)
        requestMarker =
            hex
                ( scriptHashBytes
                    ( computeScriptHash
                        ( applyRequestParams
                            (scriptHashBytes deployedState)
                            (onChainTokenId tid)
                            requestBytes
                        )
                    )
                )
        activeWitnessMarker =
            hex
                ( scriptHashBytes
                    (hashScript (RegistryEdges.witnessScriptOf cfg namingCodes 1))
                )
        marker = case control of
            WrongReason -> wrongReasonMarker
            _ -> stateMarker
    case result of
        Rejected reason ->
            attributeWrongRedeemerConstructorIndexRefusal
                index
                receiptsDir
                base
                dirty
                nodeVer
                blueprintIdStr
                marker
                stateMarker
                requestMarker
                activeWitnessMarker
                (T.unpack (TE.decodeUtf8Lenient reason))
                (txIdHex signedBad)
        Submitted txid ->
            failWith
                ( "wrong-redeemer-constructor-index FINDING: wrong-index fold accepted (txid "
                    <> txInHex txid
                    <> ") — reported, not relabelled"
                )
    -- Control: fresh cage accepts a valid fold (refusal discriminates).
    (seedC, _) <- largestWalletUtxo prov
    let cfgC = cageCfg stateBytes requestBytes namingCodes (txInToRef seedC)
    unsignedBootC <-
        Cage.withView prov (\v -> bootTokenImpl cfgC v genesisAddr)
    signedBootC <- submitWithGenesis submit unsignedBootC
    tidC <- extractTokenId cfgC signedBootC
    createTrie tm tidC
    refsC <-
        RegistryEdges.publishCageRefs
            cfgC
            namingCodes
            prov
            (submitWithGenesis submit)
            genesisAddr
            tidC
    _ <-
        RegistryEdges.bookEdge
            cfgC
            namingCodes
            prov
            (submitWithGenesis submit)
            genesisAddr
            tidC
            "cs04-control-key"
            edgeInsertActive
    unsignedFoldC <- Cage.withView prov $ \v -> do
        ctxC <- RegistryEdges.registryContextFor cfgC namingCodes v refsC
        updateTokenWithDuties cfgC v tm tidC genesisAddr ctxC
    _ <- submitWithGenesis submit unsignedFoldC
    emit
        "control"
        "wrong-redeemer-constructor-index control: fresh cage accepted a valid fold"

{- | Retarget a valid Modify fold to Constr 5 keeping its fields:
same CBOR size (tags 2 and 5 both one byte), so fee and collateral
stay sufficient and any refusal attributes to the script, never to
phase 1. Constr 5 names no UpdateRedeemer constructor and the
validator must refuse it in phase 2.
-}
tamperModifyToBadIndex :: Cage.Provider IO -> ConwayTx -> IO ConwayTx
tamperModifyToBadIndex prov tx = do
    pp <- Cage.withView prov (pure . Cage.viewProtocolParams)
    let body = tx ^. bodyTxL
        Redeemers m = tx ^. witsTxL . rdmrsTxWitsL
        scripts = tx ^. witsTxL . scriptTxWitsL
        badMap = Map.map tamperOne m
        tamperOne (Data (PLC.Constr 2 fields), units) = (Data (PLC.Constr 5 fields), units)
        tamperOne other = other
        badRedeemers = Redeemers badMap
        integrity = computeScriptIntegrity pp badRedeemers
        newBody = body & scriptIntegrityHashTxBodyL .~ integrity
    pure
        ( mkBasicTx newBody
            & witsTxL . scriptTxWitsL .~ scripts
            & witsTxL . rdmrsTxWitsL .~ badRedeemers
        )

{- | Attribute a wrong-redeemer-constructor-index refusal. The tampered fold breaks fold consistency
shared by the state, request and active-witness scripts, so more than one
can refuse in one submission and the ledger's failure-list order is not
stable. The invariant the row asserts is that the state script — whose
redeemer was tampered — refused; the recorded script set is derived from
the observed hashes in ledger order, never tuned to a run.
-}
attributeWrongRedeemerConstructorIndexRefusal
    :: ReplayIndex
    -> FilePath
    -> String
    -> Bool
    -> String
    -> String
    -> String
    -> String
    -> String
    -> String
    -> String
    -> String
    -> IO ()
attributeWrongRedeemerConstructorIndexRefusal index receiptsDir base dirty nodeVer blueprintIdStr marker stateMarker requestMarker activeWitnessMarker text rejectedTxid =
    case matchRefusal marker text of
        Right () -> do
            admitted <-
                admittedFor (T.pack marker) <$> purposesOf index (T.pack rejectedTxid)
            replay <- replayEvidenceOf index (T.pack rejectedTxid)
            correspondence <- sessionCorrespondence index
            let hashes = refusalScriptHashes text
            require
                ( "wrong-redeemer-constructor-index: state script did not refuse; scripts named: "
                    <> show hashes
                )
                (stateMarker `elem` hashes)
            roles <- mapM toRole hashes
            let trimmed = trimRefusal text
            unless (stateMarker `isInfixOf` trimmed) $
                failWith
                    ("trimmer dropped the attribution; full reason: " <> take 20000 text)
            writeCSReceiptWith
                (correspondence <* nonEmpty replay)
                receiptsDir
                "wrong-redeemer-constructor-index"
                Refused
                UnmetByRuling
                []
                ( Just
                    ( RefusalInfo
                        { refusalScript = T.intercalate "+" (map T.pack roles)
                        , refusalReason = T.pack trimmed
                        , refusalPhase = "phase-2"
                        , refusalHashes = map T.pack hashes
                        , refusalBranch = admitted
                        , refusalReplay = toList <$> nonEmpty replay
                        , refusalLimit = case admitted of
                            Just _ -> Nothing
                            Nothing ->
                                Just
                                    "no named validator branch in this compiled trace; attribution is script hash plus phase-2 only"
                        }
                    )
                )
                (Just rejectedTxid)
                Nothing
                Nothing
                Nothing
                "node-submit"
                base
                dirty
                nodeVer
                blueprintIdStr
                Nothing
            emit
                "unmet"
                ( "wrong-redeemer-constructor-index UNMET BY RULING: kept unmet by operator ruling "
                    <> "2026-10-02 (narrowed #287; model follow-up "
                    <> "lambdasistemi/singular#347); Singular's Lean has no "
                    <> "vocabulary for decoding a redeemer, so it gives no reason to "
                    <> "compare with the chain's"
                )
            emit
                "row"
                ( "wrong-redeemer-constructor-index: REFUSED wrong index by "
                    <> intercalate "+" roles
                    <> " (state marker 0x"
                    <> shortMarker stateMarker
                    <> "; ledger order, unstable)"
                )
        Left mismatch ->
            failWith
                ( "wrong-redeemer-constructor-index: refusal did not attribute ("
                    <> show mismatch
                    <> "): "
                    <> text
                )
  where
    toRole h
        | h == stateMarker = pure "state"
        | h == requestMarker = pure "request"
        | h == activeWitnessMarker = pure "witness-active"
        | otherwise =
            failWith
                ("wrong-redeemer-constructor-index: refusal names unknown script " <> h)

-- | request-and-mint-constructor-witnesses: RequestAction + MintRedeemer coverage, Migrating as gap.
runRequestAndMintConstructorWitnesses
    :: Cage.Provider IO
    -> Capabilities
    -> SBS.ShortByteString
    -> SBS.ShortByteString
    -> NamingCodes
    -> String
    -> String
    -> Bool
    -> FilePath
    -> Control
    -> String
    -> IO ()
runRequestAndMintConstructorWitnesses prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr = do
    tm <- mkPureTrieManager
    (seedC, _) <- largestWalletUtxo prov
    let cfgC = cageCfg stateBytes requestBytes namingCodes (txInToRef seedC)
    unsignedBootC <-
        Cage.withView prov (\v -> bootTokenImpl cfgC v genesisAddr)
    (memBoot, cpuBoot) <- measureUnitsProv prov unsignedBootC
    signedBootC <- submitWithGenesis submit unsignedBootC
    tidC <- extractTokenId cfgC signedBootC
    createTrie tm tidC
    require
        "request-and-mint-constructor-witnesses: Minting witness missing Constr 0"
        (0 `elem` mintConstrs signedBootC)
    refsC <-
        RegistryEdges.publishCageRefs
            cfgC
            namingCodes
            prov
            (submitWithGenesis submit)
            genesisAddr
            tidC
    _ <-
        RegistryEdges.bookEdge
            cfgC
            namingCodes
            prov
            (submitWithGenesis submit)
            genesisAddr
            tidC
            "cs05-update-key"
            edgeInsertActive
    unsignedFoldC <- Cage.withView prov $ \v -> do
        ctxC <- RegistryEdges.registryContextFor cfgC namingCodes v refsC
        updateTokenWithDuties cfgC v tm tidC genesisAddr ctxC
    require
        "request-and-mint-constructor-witnesses: Update witness missing Constr 0"
        (0 `elem` requestActionConstrs unsignedFoldC)
    (memFold, cpuFold) <- measureUnitsProv prov unsignedFoldC
    signedFoldC <- submitWithGenesis submit unsignedFoldC
    _ <- withTrie tm tidC $ \t ->
        void (walkEdge t "cs05-update-key" edgeInsertActive)
    (seedD, _) <- largestWalletUtxo prov
    let cfgD =
            fastRejectCfgLocal
                (cageCfg stateBytes requestBytes namingCodes (txInToRef seedD))
    unsignedBootD <-
        Cage.withView prov (\v -> bootTokenImpl cfgD v genesisAddr)
    signedBootD <- submitWithGenesis submit unsignedBootD
    tidD <- extractTokenId cfgD signedBootD
    createTrie tm tidD
    unsignedReqD <-
        Cage.withView prov $ \v ->
            requestEdgeImpl
                cfgD
                v
                (defaultTip cfgD)
                tidD
                "cs05-reject-key"
                edgeInsertActive
                genesisAddr
    _ <- submitWithGenesis submit unsignedReqD
    threadDelay 3_000_000
    unsignedReject <-
        Cage.withView prov (\v -> rejectRequestsImpl cfgD v tidD genesisAddr)
    require
        "request-and-mint-constructor-witnesses: Rejected witness missing Constr 1"
        (1 `elem` requestActionConstrs unsignedReject)
    (memReject, cpuReject) <- measureUnitsProv prov unsignedReject
    signedReject <- submitWithGenesis submit unsignedReject
    let actionsFold = requestActionConstrs signedFoldC
        actionsReject = requestActionConstrs signedReject
        mintsBoot = mintConstrs signedBootC
        hasUpdate = 0 `elem` actionsFold
        hasRejected = 1 `elem` actionsReject
        hasMinting = 0 `elem` mintsBoot
        missing =
            [ l
            | (False, l) <-
                zip
                    [hasUpdate, hasRejected, hasMinting]
                    (["Update", "Rejected", "Minting"] :: [String])
            ]
    case control of
        MissingWitness -> do
            emit "control" "missing-witness armed: demanding Rejected absent"
            require
                "request-and-mint-constructor-witnesses: Rejected unexpectedly present (control)"
                (1 `notElem` actionsReject)
        _ ->
            require
                ( "request-and-mint-constructor-witnesses: missing witnesses: "
                    <> show missing
                )
                (null missing)
    writeGapMigrating receiptsDir base blueprintIdStr
    let mem = maximum [memBoot, memFold, memReject]
        cpu = maximum [cpuBoot, cpuFold, cpuReject]
        size =
            maximum
                [ txSizeBytes signedBootC
                , txSizeBytes signedFoldC
                , txSizeBytes signedReject
                ]
    emitMeasureProv
        prov
        "request-and-mint-constructor-witnesses"
        mem
        cpu
        size
    writeCSReceipt
        receiptsDir
        "request-and-mint-constructor-witnesses"
        Accepted
        Partial
        [txIdHex signedBootC, txIdHex signedFoldC, txIdHex signedReject]
        Nothing
        Nothing
        (Just mem)
        (Just cpu)
        (Just size)
        "node-submit"
        base
        dirty
        nodeVer
        blueprintIdStr
        ( Just
            ( PartialInfo
                [ ConstructorEvidence
                    "Update"
                    0
                    StandingAccepted
                    (T.pack (txIdHex signedFoldC))
                , ConstructorEvidence
                    "Rejected"
                    1
                    StandingAccepted
                    (T.pack (txIdHex signedReject))
                , ConstructorEvidence
                    "Minting"
                    0
                    StandingAccepted
                    (T.pack (txIdHex signedBootC))
                , ConstructorEvidence
                    "Burning"
                    2
                    StandingResidual
                    "no accepting path (End removed f3a68b1, ownerless NOTE-028/A-003); E18 completes at rebase"
                , ConstructorEvidence
                    "Migrating"
                    1
                    StandingGap
                    "unconditional refusal under ownerless ruling (no attributed witness, no discriminator); wire Constr 1 retained; historical gap gap-request-and-mint-constructor-witnesses-Migrating.txt retained as history"
                ]
            )
        )
    emit
        "row"
        "request-and-mint-constructor-witnesses: PARTIAL Update/Rejected/Minting executed; Burning named residual (E18); Migrating gap"

writeGapMigrating :: FilePath -> String -> String -> IO ()
writeGapMigrating receiptsDir base blueprintIdStr = do
    let gap =
            "row: request-and-mint-constructor-witnesses\nconstructor: Migrating (MintRedeemer 1)\nstatus: gap\nreason: unconditional refusal under the ownerless ruling (no attributed witness, no discriminator); wire Constr 1 retained. Historical: previousPolicies=[] on the imported partition (state.ak validateMigration FR1) described the pre-ownerless gap; the allowlist and function are gone with the owner role.\nbase: "
                <> base
                <> "\nblueprint: "
                <> blueprintIdStr
                <> "\n"
    BSL.writeFile
        ( receiptsDir
            </> "gap-request-and-mint-constructor-witnesses-Migrating.txt"
        )
        (BSL.fromStrict (TE.encodeUtf8 (T.pack gap)))
    emit
        "gap"
        "request-and-mint-constructor-witnesses Migrating unconditional refusal (ownerless); wire retained, history noted"
