{- |
Module      : Conformance.Run.CsRows
Description : Split out of Conformance.Run (#263); see that module's header
License     : Apache-2.0
-}
module Conformance.Run.CsRows (cs02Key, runCSSession, reportCSPartials, runCSRow, runCS02, findStateDatum, findRequestDatum, isStateDatum, isRequestDatum, datumOfTxOut, readStateDatum, readRequestDatum, measureUnitsProv, emitMeasureProv, writeCSReceipt, runCS08, stateDatumArity, expectedStateFromTx, runCS07, cs03KeyA, cs03KeyB, fastRetractCfgLocal, fastRejectCfgLocal, runCS03, findRequestTxIn, runCS04, tamperModifyToBadIndex, attributeCS04Refusal, runCS05, writeGapMigrating) where

import Conformance.Run.Control
import Conformance.Run.Units
import Conformance.Run.Wallet
import Conformance.Run.Submit
import Conformance.Run.Environment
import Conformance.Run.Observe
import Conformance.Run.Cage (ensureStateRefWith)

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel)
import Control.Exception (
    ErrorCall (..),
    throwIO,
 )
import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.List (intercalate, isInfixOf, nub)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((&), (.~), (^.))
import System.FilePath ((</>))

import Cardano.Ledger.Plutus.Data (Data (..))

import Cardano.Ledger.Api.PParams (
    ppMaxTxExUnitsL,
    ppMaxTxSizeL,
 )
import Cardano.Ledger.Api.Tx (
    bodyTxL,
    mkBasicTx,
    witsTxL,
 )
import Cardano.Ledger.Api.Tx.Body (
    outputsTxBodyL,
    scriptIntegrityHashTxBodyL,
 )
import Cardano.Ledger.Api.Scripts.Data (
    Datum (..),
 )
import Cardano.Ledger.Api.Tx.Out (datumTxOutL)
import Cardano.Ledger.Api.Tx.Wits (
    Redeemers (..),
    rdmrsTxWitsL,
    scriptTxWitsL,
 )
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Blueprint (
    NamingCodes (..),
    applyRequestParams,
 )
import Singular.Registry.TxBuilder.Reject (rejectRequestsImpl)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (
    ConwayEra,
    ExUnits (..),
    Root (..),
    TokenId (..),
    TxOut,
 )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.Trie (TrieManager (..))
import Singular.Registry.Trie qualified as CageTrie
import Singular.Registry.Trie.PureManager (mkPureTrieManager)
import Singular.Registry.TxBuilder.Boot (bootTokenImpl)
import Singular.Registry.TxBuilder.Edges qualified as RegistryEdges
import Singular.Registry.TxBuilder.Internal (
    walkEdge,
    cageAddrFromCfg,
    cagePolicyIdFromCfg,
    computeScriptHash,
    computeScriptIntegrity,
    extractCageDatum,
    findRequestUtxos,
    findStateUtxo,
    onChainTokenId,
    requestAddrFromCfg,
    scriptHashBytes,
    toPlcData,
    txInToRef,
 )
import Singular.Registry.TxBuilder.Retract (retractRequestImpl)
import Singular.Registry.TxBuilder.Request (
    requestEdgeImpl,
 )
import Singular.Registry.TxBuilder.Update (updateTokenWithDuties)
import Singular.Registry.Types (
    CageDatum (..),
    edgeInsertAbsent,
    edgeInsertActive,
    OnChainRequest (..),
    OnChainRoot (..),
    OnChainTokenState (..),
 )
import Singular.Registry.Node (
    adaptProvider,
    awaitConnection,
    checkFunding,
    defaultFundingFloor,
    followedProvider,
    funderAddr,
    sessionMagic,
 )
import Cardano.Node.Client.E2E.Setup (addKeyWitness)
import Cardano.Node.Client.N2C.Connection (
    newLSQChannel,
    newLTxSChannel,
    runNodeClient,
 )
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.N2C.Submitter (mkN2CSubmitter)
import Cardano.Node.Client.Submitter (
    SubmitResult (..),
    Submitter (..),
 )
import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins.Internal (BuiltinByteString (..))

import Conformance.Mirror (
    emit,
    failWith,
    hex,
    readChainState,
    require,
    txIdHex,
 )
import Conformance.Receipt (
    ConstructorEvidence (..),
    ConstructorStanding (..),
    Outcome (..),
    PartialInfo (..),
    Receipt (..),
    RefusalInfo (..),
    Verdict (..),
    loadReceipts,
    writeReceiptFile,
 )
import Conformance.Refusal (
    matchRefusal,
    refusalScriptHashes,
    trimRefusal,
    wrongReasonMarker,
 )

-- ---------------------------------------------------------
-- CS devnet session (serialization boundary)
-- ---------------------------------------------------------

cs02Key :: ByteString
cs02Key = "cs02-key"


runCSSession ::
    [String] ->
    Control ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    NamingCodes ->
    String ->
    String ->
    Bool ->
    FilePath ->
    FilePath ->
    IO ()
runCSSession rows control stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir sock = do
    lsqCh <- newLSQChannel 16
    ltxsCh <- newLTxSChannel 16
    nodeThread <-
        async $
            runNodeClient
                sessionMagic
                sock
                lsqCh
                ltxsCh
    let nodeProv = adaptProvider (mkN2CProvider lsqCh)
    awaitConnection sessionMagic sock nodeThread nodeProv
    let submit = mkN2CSubmitter ltxsCh
    prov <- followedProvider nodeProv submit
    let stateMarker = hex (scriptHashBytes (computeScriptHash stateBytes))
        blueprintIdStr =
            "state:"
                <> stateMarker
                <> " request:"
                <> hex
                    (scriptHashBytes (computeScriptHash requestBytes))
    _ <- Cage.queryProtocolParams prov
    checkFunding prov funderAddr defaultFundingFloor
    -- Every CS row boots by reference: publish the state validator
    -- once, before any row picks its seed.
    ensureStateRefWith prov submit stateBytes
    mapM_ (runCSRow prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr) rows
    cancel nodeThread
    emit
        "complete"
        (show (length rows) <> "/" <> show (length rows) <> " rows ok")
    -- Partial rows must never read as green: the session ends
    -- partial naming every such row (E18 §3/§4, NOTE-052). CI
    -- enumerates the known partial set; anything else is a failure.
    reportCSPartials receiptsDir rows


-- | Session-end partial accounting for the CS rows: receipts with
-- verdict partial among the rows just run end the session with the
-- specifically accounted partial status (exit 1, distinct report).
-- A loader rejection (including a success verdict carrying partial
-- constructors) fails the session as invalid evidence.
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


runCSRow ::
    Cage.Provider IO ->
    Submitter IO ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    NamingCodes ->
    String ->
    String ->
    Bool ->
    FilePath ->
    Control ->
    String ->
    String ->
    IO ()
runCSRow prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr row = case row of
    "CS02" -> runCS02 prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr
    "CS03" -> runCS03 prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr
    "CS04" -> runCS04 prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr
    "CS05" -> runCS05 prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr
    "CS07" -> runCS07 prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr
    "CS08" -> runCS08 prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr
    _ -> failWith ("CS row not yet implemented: " <> row)


-- | CS02: datum bytes constructed in Haskell and submitted are read
-- back identical (byte-compare submitted vs chain-observed).
runCS02 ::
    Cage.Provider IO ->
    Submitter IO ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    NamingCodes ->
    String ->
    String ->
    Bool ->
    FilePath ->
    Control ->
    String ->
    IO ()
runCS02 prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr = do
    (seedTxIn, _) <- largestWalletUtxo prov
    let cfg = cageCfg stateBytes requestBytes namingCodes (txInToRef seedTxIn)
    unsignedBoot <- bootTokenImpl cfg prov genesisAddr
    let submittedStateDatum = findStateDatum unsignedBoot
    (mem, cpu) <- measureUnitsProv prov unsignedBoot
    signedBoot <- submitWithGenesis submit unsignedBoot
    tid <- extractTokenId cfg signedBoot
    unsignedReq <-
        requestEdgeImpl
            cfg
            prov
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
            emit "control" "false-datum armed: demanding state bytes match request bytes"
            require
                ("CS02: submitted state bytes differ from chain-observed (control)")
                (submittedStateDatum == submittedReqDatum)
        _ -> do
            require
                ("CS02: state datum bytes differ: submitted " <> show submittedStateDatum <> " vs chain " <> show observedStateDatum)
                (submittedStateDatum == observedStateDatum)
            require
                ("CS02: request datum bytes differ: submitted " <> show submittedReqDatum <> " vs chain " <> show observedReqDatum)
                (submittedReqDatum == observedReqDatum)
    let sizeBoot = txSizeBytes signedBoot
        sizeReq = txSizeBytes signedReq
        size = max sizeBoot sizeReq
    emitMeasureProv prov "CS02" mem cpu size
    writeCSReceipt receiptsDir "CS02" Accepted AgreesWithModel [txIdHex signedBoot, txIdHex signedReq] Nothing Nothing (Just mem) (Just cpu) (Just size) "node-submit" base dirty nodeVer blueprintIdStr Nothing
    emit "row" "CS02: ACCEPTED datum bytes identical (state+request)"


-- | Find the state inline datum in an unsigned transaction's outputs.
findStateDatum :: ConwayTx -> Datum ConwayEra
findStateDatum tx =
    case [d | out <- toList (tx ^. bodyTxL . outputsTxBodyL), Just d <- [datumOfTxOut out], isStateDatum out] of
        [d] -> d
        _ -> error "CS02: unsigned tx has no single state datum"


-- | Find the request inline datum for a key in an unsigned tx.
findRequestDatum :: ByteString -> ConwayTx -> Datum ConwayEra
findRequestDatum key tx =
    case [d | out <- toList (tx ^. bodyTxL . outputsTxBodyL), Just d <- [datumOfTxOut out], isRequestDatum key out] of
        [d] -> d
        _ -> error "CS02: unsigned tx has no single request datum"


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


readStateDatum :: Cage.Provider IO -> CageConfig -> TokenId -> IO (Datum ConwayEra)
readStateDatum prov cfg tid = do
    utxos <- Cage.queryUTxOs prov (cageAddrFromCfg cfg (network cfg))
    case findStateUtxo (cagePolicyIdFromCfg cfg) tid utxos of
        Nothing -> failWith "CS02: no state UTxO on chain"
        Just (_, out) -> case datumOfTxOut out of
            Just d -> pure d
            Nothing -> failWith "CS02: state UTxO has no inline datum"


readRequestDatum :: Cage.Provider IO -> CageConfig -> TokenId -> ByteString -> IO (Datum ConwayEra)
readRequestDatum prov cfg tid key = do
    utxos <- Cage.queryUTxOs prov (requestAddrFromCfg cfg tid (network cfg))
    let reqs = findRequestUtxos tid utxos
        matching = [out | (_, out) <- reqs, isRequestDatum key out]
    case matching of
        [out] -> case datumOfTxOut out of
            Just d -> pure d
            Nothing -> failWith "CS02: request UTxO has no inline datum"
        _ -> failWith ("CS02: expected one request UTxO for key, found " <> show (length matching))


-- | Measure execution units via the node, while inputs are unspent.
measureUnitsProv :: Cage.Provider IO -> ConwayTx -> IO (Integer, Integer)
measureUnitsProv prov tx = do
    evalMap <- Cage.evaluateTx prov tx
    let evalStr = Map.map (either (Left . show) Right) evalMap
    units <- case sequence evalStr of
        Left e -> failWith ("measure: node evaluation failed: " <> e)
        Right m -> pure (Map.elems m)
    let mem = sum [m | ExUnits m _ <- units]
        cpu = sum [s | ExUnits _ s <- units]
    pure (fromIntegral mem, fromIntegral cpu)


-- | Emit one fold's units and size against the devnet maxima.
emitMeasureProv :: Cage.Provider IO -> String -> Integer -> Integer -> Integer -> IO ()
emitMeasureProv prov label mem cpu size = do
    pp <- Cage.queryProtocolParams prov
    let ExUnits maxMem maxSteps = pp ^. ppMaxTxExUnitsL
        maxSize = fromIntegral (pp ^. ppMaxTxSizeL) :: Integer
        pct :: Integer -> Integer -> Double
        pct used maxV = fromIntegral used / fromIntegral maxV * 100 :: Double
    emit
        "measure"
        (label
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
            <> " (" <> show (pct size maxSize) <> "%)")


writeCSReceipt ::
    FilePath ->
    String ->
    Outcome ->
    Verdict ->
    [String] ->
    Maybe RefusalInfo ->
    Maybe String ->
    Maybe Integer ->
    Maybe Integer ->
    Maybe Integer ->
    T.Text ->
    String ->
    Bool ->
    String ->
    String ->
    Maybe PartialInfo ->
    IO ()
writeCSReceipt dir row outcome verdict txs refusal rejected mem cpu size venue base dirty nodeVer blueprintIdStr partial =
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
            , receiptNode = T.pack nodeVer
            , receiptBlueprint = T.pack blueprintIdStr
            , receiptVenue = venue
            }


{- | CS08 (#157 X1): the eight fields of `OnChainTokenState` survive a
chain round trip, with the ACTIVE policy varied Base versus Alt
(NOTE-046: no stake script exists to vary; #157 C7 renamed the field
this row always varied). The four pinned policies are the ones D-BOOT
derives — the application policy from the naming application script and
the three token policies from `witness(kind, registry)` applied — so
this row is also what says the derivation reaches the chain intact.
-}
runCS08 ::
    Cage.Provider IO ->
    Submitter IO ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    NamingCodes ->
    String ->
    String ->
    Bool ->
    FilePath ->
    Control ->
    String ->
    IO ()
runCS08 prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr = do
    -- Base cage: all four pins derived for its own registry identity.
    (seedBase, _) <- largestWalletUtxo prov
    let cfgBase = cageCfg stateBytes requestBytes namingCodes (txInToRef seedBase)
    unsignedBootBase <- bootTokenImpl cfgBase prov genesisAddr
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
    unsignedBootAlt <- bootTokenImpl cfgAlt prov genesisAddr
    (mem2, cpu2) <- measureUnitsProv prov unsignedBootAlt
    signedBootAlt <- submitWithGenesis submit unsignedBootAlt
    tidAlt <- extractTokenId cfgAlt signedBootAlt
    observedAlt <- readChainState cfgAlt prov tidAlt
    expectedAlt <- expectedStateFromTx unsignedBootAlt
    case control of
        FalseDatum -> do
            emit "control" "false-datum armed: demanding Base==Alt"
            require
                "CS08: Base and Alt states unexpectedly match (control)"
                (observedBase == observedAlt)
        LegacySixField -> do
            emit
                "control"
                "CS08 ARMED (legacy-six-field): demanding the retired \
                \six-field state encoding of the chain's own datum"
            require
                ( "CS08: the chain state encodes "
                    <> show (stateDatumArity observedBase)
                    <> " fields, not the six the retired contract had"
                )
                (stateDatumArity observedBase == 6)
        _ -> do
            require
                ("CS08: Base state fields differ: expected " <> show expectedBase <> " vs chain " <> show observedBase)
                (expectedBase == observedBase)
            require
                ("CS08: Alt state fields differ: expected " <> show expectedAlt <> " vs chain " <> show observedAlt)
                (expectedAlt == observedAlt)
            -- The eight fields, each explicitly, against the boot tx.
            require "CS08: Base root mismatch" (stateRoot observedBase == stateRoot expectedBase)
            require "CS08: Alt root mismatch" (stateRoot observedAlt == stateRoot expectedAlt)
            require "CS08: Base tip mismatch" (stateMaxFee observedBase == stateMaxFee expectedBase)
            require "CS08: Alt tip mismatch" (stateMaxFee observedAlt == stateMaxFee expectedAlt)
            require "CS08: Base processTime mismatch" (stateProcessTime observedBase == stateProcessTime expectedBase)
            require "CS08: Alt processTime mismatch" (stateProcessTime observedAlt == stateProcessTime expectedAlt)
            require "CS08: Base retractTime mismatch" (stateRetractTime observedBase == stateRetractTime expectedBase)
            require "CS08: Alt retractTime mismatch" (stateRetractTime observedAlt == stateRetractTime expectedAlt)
            require "CS08: Base applicationPolicy mismatch" (stateAppPolicy observedBase == stateAppPolicy expectedBase)
            require "CS08: Alt applicationPolicy mismatch" (stateAppPolicy observedAlt == stateAppPolicy expectedAlt)
            require "CS08: Base activePolicy mismatch" (stateActivePolicy observedBase == stateActivePolicy expectedBase)
            require "CS08: Alt activePolicy mismatch" (stateActivePolicy observedAlt == stateActivePolicy expectedAlt)
            require "CS08: Base absentPolicy mismatch" (stateAbsentPolicy observedBase == stateAbsentPolicy expectedBase)
            require "CS08: Alt absentPolicy mismatch" (stateAbsentPolicy observedAlt == stateAbsentPolicy expectedAlt)
            require "CS08: Base terminalPolicy mismatch" (stateTerminalPolicy observedBase == stateTerminalPolicy expectedBase)
            require "CS08: Alt terminalPolicy mismatch" (stateTerminalPolicy observedAlt == stateTerminalPolicy expectedAlt)
            -- The varied field discriminates; the held fields are stable.
            require
                "CS08: Base and Alt activePolicy unexpectedly match"
                (stateActivePolicy observedBase /= stateActivePolicy observedAlt)
            require
                "CS08: applicationPolicy moved between cages"
                (stateAppPolicy observedBase == stateAppPolicy observedAlt)
            -- D-BOOT: the pins are DERIVED. A placeholder would be all
            -- zeroes, and the three token policies are three distinct
            -- applications of one script, so they cannot coincide.
            require
                "CS08: a pinned policy is a placeholder (28 zero bytes)"
                ( all
                    (/= BuiltinByteString (BS.replicate 28 0))
                    [ stateAppPolicy observedBase
                    , stateActivePolicy observedBase
                    , stateAbsentPolicy observedBase
                    , stateTerminalPolicy observedBase
                    ]
                )
            require
                "CS08: the three derived token policies are not distinct"
                ( let ps =
                        [ stateActivePolicy observedBase
                        , stateAbsentPolicy observedBase
                        , stateTerminalPolicy observedBase
                        ]
                   in length (nub ps) == 3
                )
    let mem = max mem1 mem2
        cpu = max cpu1 cpu2
        size = max (txSizeBytes signedBootBase) (txSizeBytes signedBootAlt)
    emitMeasureProv prov "CS08" mem cpu size
    writeCSReceipt receiptsDir "CS08" Accepted AgreesWithModel [txIdHex signedBootBase, txIdHex signedBootAlt] Nothing Nothing (Just mem) (Just cpu) (Just size) "node-submit" base dirty nodeVer blueprintIdStr Nothing
    emit "row" "CS08: ACCEPTED eight fields survive (Base+AltActivePolicy)"


{- | How many fields the state datum actually encodes. The retired
contract had six; #157 C7 made it eight, and the armed control demands
the old arity so the row is shown able to notice a regression.
-}
stateDatumArity :: OnChainTokenState -> Int
stateDatumArity st = case toPlcData st of
    PLC.Constr _ fields -> length fields
    _ -> -1


expectedStateFromTx :: ConwayTx -> IO OnChainTokenState
expectedStateFromTx tx =
    case [s | out <- toList (tx ^. bodyTxL . outputsTxBodyL), Just (StateDatum s) <- [extractCageDatum out]] of
        [s] -> pure s
        _ -> failWith "CS08: unsigned boot has no single StateDatum"


{- | CS07: sequential absence folds exercise Leaf, lone Fork and Branch.
The C fold uses the exact historical C-over-{A,B} regression; D and E
widen the trie until a Branch is witnessed by another accepted fold.
-}
runCS07 ::
    Cage.Provider IO ->
    Submitter IO ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    NamingCodes ->
    String ->
    String ->
    Bool ->
    FilePath ->
    Control ->
    String ->
    IO ()
runCS07 prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr = do
    tm <- mkPureTrieManager
    (seed, _) <- largestWalletUtxo prov
    let cfg = cageCfg stateBytes requestBytes namingCodes (txInToRef seed)
    unsignedBoot <- bootTokenImpl cfg prov genesisAddr
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
    require "CS07: missing accepted ProofStep witness" (all (`elem` witnessed) [0, 1, 2])
    emitMeasureProv prov "CS07" mem cpu size
    writeCSReceipt
        receiptsDir
        "CS07"
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
    emit "row" "CS07: ACCEPTED Branch/Fork/Leaf and Neighbor; C-over-{A,B} absence folded"
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
        ctx <- RegistryEdges.registryContextFor cfg namingCodes prov refs
        unsignedFold <-
            updateTokenWithDuties cfg prov tm tid genesisAddr ctx
        require
            ("CS07: unexpected proof for " <> show key <> ": " <> show (proofStepConstrs unsignedFold))
            (proofStepConstrs unsignedFold == expectedSteps)
        require "CS07: malformed Fork Neighbor" (forkNeighborsWellFormed unsignedFold)
        (mem, cpu) <- measureUnitsProv prov unsignedFold
        signedFold <- submitWithGenesis submit unsignedFold
        root <- withTrie tm tid $ \trie -> do
            _ <- walkEdge trie key edgeInsertAbsent
            CageTrie.getRoot trie
        observed <- readChainState cfg prov tid
        require
            "CS07: chain root differs from committed trie"
            (unOnChainRoot (stateRoot observed) == unRoot root)
        emit "CS07-fold" (show key <> " steps=" <> show expectedSteps <> " txid=" <> txIdHex signedFold)
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


runCS03 ::
    Cage.Provider IO ->
    Submitter IO ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    NamingCodes ->
    String ->
    String ->
    Bool ->
    FilePath ->
    Control ->
    String ->
    IO ()
runCS03 prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr = do
    tm <- mkPureTrieManager
    (seedA, _) <- largestWalletUtxo prov
    let cfgA = cageCfg stateBytes requestBytes namingCodes (txInToRef seedA)
    unsignedBootA <- bootTokenImpl cfgA prov genesisAddr
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
    ctxA <- RegistryEdges.registryContextFor cfgA namingCodes prov refsA
    unsignedFoldA <-
        updateTokenWithDuties cfgA prov tm tidA genesisAddr ctxA
    require
        "CS03: Modify witness missing Constr 2"
        (2 `elem` spendingConstrs unsignedFoldA)
    require
        "CS03: Contribute witness missing Constr 1"
        (1 `elem` spendingConstrs unsignedFoldA)
    (memFold, cpuFold) <- measureUnitsProv prov unsignedFoldA
    signedFoldA <- submitWithGenesis submit unsignedFoldA
    _ <- withTrie tm tidA $ \t ->
        () <$ walkEdge t cs03KeyA edgeInsertActive
    (seedB, _) <- largestWalletUtxo prov
    let cfgB = fastRetractCfgLocal (cageCfg stateBytes requestBytes namingCodes (txInToRef seedB))
    unsignedBootB <- bootTokenImpl cfgB prov genesisAddr
    (memBootB, cpuBootB) <- measureUnitsProv prov unsignedBootB
    signedBootB <- submitWithGenesis submit unsignedBootB
    tidB <- extractTokenId cfgB signedBootB
    createTrie tm tidB
    unsignedReqB <-
        requestEdgeImpl
            cfgB
            prov
            (defaultTip cfgB)
            tidB
            cs03KeyB
            edgeInsertActive
            genesisAddr
    _ <- submitWithGenesis submit unsignedReqB
    reqTxInB <- findRequestTxIn prov cfgB tidB cs03KeyB
    threadDelay 3_000_000
    unsignedRetract <- retractRequestImpl cfgB prov tidB reqTxInB genesisAddr
    require
        "CS03: Retract witness missing Constr 3"
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
            emit "control" "missing-witness armed: demanding Retract absent from its own tx (deliberately false)"
            require
                "CS03: Retract unexpectedly absent from its own tx (control)"
                (3 `notElem` spendingConstrs signedRetract)
        _ ->
            require
                ("CS03: missing accept witnesses: " <> show missing)
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
    emitMeasureProv prov "CS03" mem cpu size
    writeCSReceipt receiptsDir "CS03" Accepted Partial [txIdHex signedFoldA, txIdHex signedRetract] Nothing Nothing (Just mem) (Just cpu) (Just size) "node-submit" base dirty nodeVer blueprintIdStr
        ( Just
            ( PartialInfo
                [ ConstructorEvidence "Modify" 2 StandingAccepted (T.pack (txIdHex signedFoldA))
                , ConstructorEvidence "Contribute" 1 StandingAccepted (T.pack (txIdHex signedFoldA))
                , ConstructorEvidence "Retract" 3 StandingAccepted (T.pack (txIdHex signedRetract))
                , ConstructorEvidence "End" 0 StandingResidual "state.ak End refuses every party (ownerless NOTE-028/A-003; builder removed f3a68b1); no accepting path; E18 completes at rebase"
                , ConstructorEvidence "Sweep" 4 StandingResidual "request.ak Sweep refuses every party (ownerless NOTE-028/A-003; builder removed f3a68b1); no accepting path; E18 completes at rebase"
                ]
            )
        )
    emit "row" "CS03: PARTIAL Contribute/Modify/Retract executed; End/Sweep named residuals (E18)"


findRequestTxIn :: Cage.Provider IO -> CageConfig -> TokenId -> ByteString -> IO TxIn
findRequestTxIn prov cfg tid key = do
    utxos <- Cage.queryUTxOs prov (requestAddrFromCfg cfg tid (network cfg))
    let matching = [i | (i, out) <- findRequestUtxos tid utxos, isRequestDatum key out]
    case matching of
        [found] -> pure found
        _ -> failWith ("findRequestTxIn: expected one request for key, found " <> show (length matching))


-- | CS04: wrong constructor index refused, attributed to the script.
runCS04 ::
    Cage.Provider IO ->
    Submitter IO ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    NamingCodes ->
    String ->
    String ->
    Bool ->
    FilePath ->
    Control ->
    String ->
    IO ()
runCS04 prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr = do
    tm <- mkPureTrieManager
    (seed, _) <- largestWalletUtxo prov
    let cfg = cageCfg stateBytes requestBytes namingCodes (txInToRef seed)
    unsignedBoot <- bootTokenImpl cfg prov genesisAddr
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
    ctx <- RegistryEdges.registryContextFor cfg namingCodes prov refs
    unsignedFold <-
        updateTokenWithDuties cfg prov tm tid genesisAddr ctx
    badTx <- tamperModifyToBadIndex prov unsignedFold
    let signedBad = addKeyWitness genesisSignKey badTx
    result <- submitTx submit signedBad
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
            attributeCS04Refusal receiptsDir base dirty nodeVer blueprintIdStr marker stateMarker requestMarker activeWitnessMarker (T.unpack (TE.decodeUtf8Lenient reason)) (txIdHex signedBad)
        Submitted txid ->
            failWith
                ("CS04 FINDING: wrong-index fold accepted (txid " <> txInHex txid <> ") — reported, not relabelled")
    -- Control: fresh cage accepts a valid fold (refusal discriminates).
    (seedC, _) <- largestWalletUtxo prov
    let cfgC = cageCfg stateBytes requestBytes namingCodes (txInToRef seedC)
    unsignedBootC <- bootTokenImpl cfgC prov genesisAddr
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
    ctxC <- RegistryEdges.registryContextFor cfgC namingCodes prov refsC
    unsignedFoldC <-
        updateTokenWithDuties cfgC prov tm tidC genesisAddr ctxC
    _ <- submitWithGenesis submit unsignedFoldC
    emit "control" "CS04 control: fresh cage accepted a valid fold"


-- | Retarget a valid Modify fold to Constr 5 keeping its fields:
-- same CBOR size (tags 2 and 5 both one byte), so fee and collateral
-- stay sufficient and any refusal attributes to the script, never to
-- phase 1. Constr 5 names no UpdateRedeemer constructor and the
-- validator must refuse it in phase 2.
tamperModifyToBadIndex :: Cage.Provider IO -> ConwayTx -> IO ConwayTx
tamperModifyToBadIndex prov tx = do
    pp <- Cage.queryProtocolParams prov
    let body = tx ^. bodyTxL
        Redeemers m = tx ^. witsTxL . rdmrsTxWitsL
        scripts = tx ^. witsTxL . scriptTxWitsL
        badMap = Map.map tamperOne m
        tamperOne (Data (PLC.Constr 2 fields), units) = (Data (PLC.Constr 5 fields), units)
        tamperOne other = other
        badRedeemers = Redeemers badMap
        integrity = computeScriptIntegrity pp badRedeemers
        newBody = body & scriptIntegrityHashTxBodyL .~ integrity
    pure (mkBasicTx newBody & witsTxL . scriptTxWitsL .~ scripts & witsTxL . rdmrsTxWitsL .~ badRedeemers)


{- | Attribute a CS04 refusal. The tampered fold breaks fold consistency
shared by the state, request and active-witness scripts, so more than one
can refuse in one submission and the ledger's failure-list order is not
stable. The invariant the row asserts is that the state script — whose
redeemer was tampered — refused; the recorded script set is derived from
the observed hashes in ledger order, never tuned to a run.
-}
attributeCS04Refusal :: FilePath -> String -> Bool -> String -> String -> String -> String -> String -> String -> String -> String -> IO ()
attributeCS04Refusal receiptsDir base dirty nodeVer blueprintIdStr marker stateMarker requestMarker activeWitnessMarker text rejectedTxid =
    case matchRefusal marker text of
        Right () -> do
            let hashes = refusalScriptHashes text
            require
                ("CS04: state script did not refuse; scripts named: " <> show hashes)
                (stateMarker `elem` hashes)
            roles <- mapM toRole hashes
            let trimmed = trimRefusal text
            unless (stateMarker `isInfixOf` trimmed) $
                failWith ("trimmer dropped the attribution; full reason: " <> take 20000 text)
            writeCSReceipt receiptsDir "CS04" Refused AgreesWithModel [] (Just (RefusalInfo {refusalScript = T.intercalate "+" (map T.pack roles), refusalReason = T.pack trimmed, refusalPhase = "phase-2", refusalHashes = map T.pack hashes, refusalBranch = Nothing, refusalLimit = Just "no named validator branch in this compiled trace; attribution is script hash plus phase-2 only"})) (Just rejectedTxid) Nothing Nothing Nothing "node-submit" base dirty nodeVer blueprintIdStr Nothing
            emit "row" ("CS04: REFUSED wrong index by " <> intercalate "+" roles <> " (state marker 0x" <> shortMarker stateMarker <> "; ledger order, unstable)")
        Left mismatch ->
            failWith ("CS04: refusal did not attribute (" <> show mismatch <> "): " <> text)
  where
    toRole h
        | h == stateMarker = pure "state"
        | h == requestMarker = pure "request"
        | h == activeWitnessMarker = pure "witness-active"
        | otherwise = failWith ("CS04: refusal names unknown script " <> h)


-- | CS05: RequestAction + MintRedeemer coverage, Migrating as gap.
runCS05 ::
    Cage.Provider IO ->
    Submitter IO ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    NamingCodes ->
    String ->
    String ->
    Bool ->
    FilePath ->
    Control ->
    String ->
    IO ()
runCS05 prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr = do
    tm <- mkPureTrieManager
    (seedC, _) <- largestWalletUtxo prov
    let cfgC = cageCfg stateBytes requestBytes namingCodes (txInToRef seedC)
    unsignedBootC <- bootTokenImpl cfgC prov genesisAddr
    (memBoot, cpuBoot) <- measureUnitsProv prov unsignedBootC
    signedBootC <- submitWithGenesis submit unsignedBootC
    tidC <- extractTokenId cfgC signedBootC
    createTrie tm tidC
    require "CS05: Minting witness missing Constr 0" (0 `elem` mintConstrs signedBootC)
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
    ctxC <- RegistryEdges.registryContextFor cfgC namingCodes prov refsC
    unsignedFoldC <-
        updateTokenWithDuties cfgC prov tm tidC genesisAddr ctxC
    require "CS05: Update witness missing Constr 0" (0 `elem` requestActionConstrs unsignedFoldC)
    (memFold, cpuFold) <- measureUnitsProv prov unsignedFoldC
    signedFoldC <- submitWithGenesis submit unsignedFoldC
    _ <- withTrie tm tidC $ \t ->
        () <$ walkEdge t "cs05-update-key" edgeInsertActive
    (seedD, _) <- largestWalletUtxo prov
    let cfgD = fastRejectCfgLocal (cageCfg stateBytes requestBytes namingCodes (txInToRef seedD))
    unsignedBootD <- bootTokenImpl cfgD prov genesisAddr
    signedBootD <- submitWithGenesis submit unsignedBootD
    tidD <- extractTokenId cfgD signedBootD
    createTrie tm tidD
    unsignedReqD <-
        requestEdgeImpl
            cfgD
            prov
            (defaultTip cfgD)
            tidD
            "cs05-reject-key"
            edgeInsertActive
            genesisAddr
    _ <- submitWithGenesis submit unsignedReqD
    threadDelay 3_000_000
    unsignedReject <- rejectRequestsImpl cfgD prov tidD genesisAddr
    require "CS05: Rejected witness missing Constr 1" (1 `elem` requestActionConstrs unsignedReject)
    (memReject, cpuReject) <- measureUnitsProv prov unsignedReject
    signedReject <- submitWithGenesis submit unsignedReject
    let actionsFold = requestActionConstrs signedFoldC
        actionsReject = requestActionConstrs signedReject
        mintsBoot = mintConstrs signedBootC
        hasUpdate = 0 `elem` actionsFold
        hasRejected = 1 `elem` actionsReject
        hasMinting = 0 `elem` mintsBoot
        missing =
            [l | (False, l) <- zip [hasUpdate, hasRejected, hasMinting] (["Update", "Rejected", "Minting"] :: [String])]
    case control of
        MissingWitness -> do
            emit "control" "missing-witness armed: demanding Rejected absent"
            require "CS05: Rejected unexpectedly present (control)" (1 `notElem` actionsReject)
        _ ->
            require ("CS05: missing witnesses: " <> show missing) (null missing)
    writeGapMigrating receiptsDir base blueprintIdStr
    let mem = maximum [memBoot, memFold, memReject]
        cpu = maximum [cpuBoot, cpuFold, cpuReject]
        size =
            maximum
                [ txSizeBytes signedBootC
                , txSizeBytes signedFoldC
                , txSizeBytes signedReject
                ]
    emitMeasureProv prov "CS05" mem cpu size
    writeCSReceipt receiptsDir "CS05" Accepted Partial [txIdHex signedBootC, txIdHex signedFoldC, txIdHex signedReject] Nothing Nothing (Just mem) (Just cpu) (Just size) "node-submit" base dirty nodeVer blueprintIdStr
        ( Just
            ( PartialInfo
                [ ConstructorEvidence "Update" 0 StandingAccepted (T.pack (txIdHex signedFoldC))
                , ConstructorEvidence "Rejected" 1 StandingAccepted (T.pack (txIdHex signedReject))
                , ConstructorEvidence "Minting" 0 StandingAccepted (T.pack (txIdHex signedBootC))
                , ConstructorEvidence "Burning" 2 StandingResidual "no accepting path (End removed f3a68b1, ownerless NOTE-028/A-003); E18 completes at rebase"
                , ConstructorEvidence "Migrating" 1 StandingGap "unconditional refusal under ownerless ruling (no attributed witness, no discriminator); wire Constr 1 retained; historical gap gap-CS05-Migrating.txt retained as history"
                ]
            )
        )
    emit "row" "CS05: PARTIAL Update/Rejected/Minting executed; Burning named residual (E18); Migrating gap"


writeGapMigrating :: FilePath -> String -> String -> IO ()
writeGapMigrating receiptsDir base blueprintIdStr = do
    let gap =
            "row: CS05\nconstructor: Migrating (MintRedeemer 1)\nstatus: gap\nreason: unconditional refusal under the ownerless ruling (no attributed witness, no discriminator); wire Constr 1 retained. Historical: previousPolicies=[] on the imported partition (state.ak validateMigration FR1) described the pre-ownerless gap; the allowlist and function are gone with the owner role.\nbase: "
                <> base
                <> "\nblueprint: "
                <> blueprintIdStr
                <> "\n"
    BSL.writeFile (receiptsDir </> "gap-CS05-Migrating.txt") (BSL.fromStrict (TE.encodeUtf8 (T.pack gap)))
    emit "gap" "CS05 Migrating unconditional refusal (ownerless); wire retained, history noted"
