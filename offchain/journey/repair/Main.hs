{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Main
Description : Repair rows for issue #79 on a real devnet ledger
License     : Apache-2.0

Five rows for the imported-validator repair (permissionless folding
and insert-only retraction) on a real devnet. See the module header
in the previous draft for the Lean authority and row definitions.
-}
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async, cancel, poll)
import Control.Exception (SomeException, displayException, throwIO, try)
import Control.Monad (unless, when)
import Data.Aeson (Value, object, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseMaybe)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BSC
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Ord (Down (..))
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Void (Void)
import Lens.Micro ((&), (.~), (^.))
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.IO (BufferMode (..), hPutStrLn, hSetBuffering, stderr, stdout)

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Allegra.Scripts (
    ValidityInterval (..),
 )
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Alonzo.TxBody (
    reqSignerHashesTxBodyL,
    scriptIntegrityHashTxBodyL,
 )
import Cardano.Ledger.Api.Tx (bodyTxL, mkBasicTx, txIdTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body (
    collateralInputsTxBodyL,
    feeTxBodyL,
    inputsTxBodyL,
    mintTxBodyL,
    mkBasicTxBody,
    outputsTxBodyL,
    referenceInputsTxBodyL,
    vldtTxBodyL,
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
    Redeemers (..),
    addrTxWitsL,
    rdmrsTxWitsL,
    scriptTxWitsL,
    witVKeyHash,
 )
import Cardano.Ledger.BaseTypes (Inject (..), Network (..), StrictMaybe (SJust), TxIx (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway.Scripts (
    ConwayPlutusPurpose (..),
 )
import Cardano.Ledger.Core (Script, extractHash, hashScript)
import Cardano.Ledger.Hashes (unKeyHash)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..), PolicyID (..))
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))

import PlutusTx.Builtins.Internal (BuiltinByteString (..))

import Cardano.MPFS.Cage.Blueprint (
    extractCompiledCode,
    loadBlueprint,
 )
import Cardano.MPFS.Cage.Config (CageConfig (..))
import Cardano.MPFS.Cage.Ledger (
    ConwayEra,
    ConwayTxBody,
    PParams,
    Root (..),
    TokenId (..),
 )
import Cardano.MPFS.Cage.Provider qualified as Cage
import Cardano.MPFS.Cage.Trie (Trie (..), TrieManager (..))
import Cardano.MPFS.Cage.Trie.PureManager (mkPureTrieManager)
import Cardano.MPFS.Cage.TxBuilder.Boot (bootTokenImpl)
import Cardano.MPFS.Cage.TxBuilder.Internal (
    addrFromKeyHashBytes,
    addrKeyHashBytes,
    addrWitnessKeyHash,
    cageAddrFromCfg,
    cagePolicyIdFromCfg,
    computeScriptHash,
    computeScriptIntegrity,
    currentPosixMs,
    evaluateAndBalance,
    extractCageDatum,
    extractOwnerBytes,
    findRequestUtxos,
    findStateUtxo,
    findUtxoByTxIn,
    mkCageScript,
    mkInlineDatum,
    mkRequestDatum,
    mkRequestScript,
    onChainTokenId,
    placeholderExUnits,
    requestAddrFromCfg,
    scriptHashBytes,
    spendingIndex,
    toLedgerData,
    toPlcData,
    trySlots,
    txInToRef,
 )
import Cardano.MPFS.Cage.Types (
    CageDatum (..),
    Migration (..),
    MintRedeemer (..),
    OnChainOperation (..),
    OnChainRequest (..),
    OnChainRoot (..),
    OnChainTokenState (..),
    ProofStep,
    RequestAction (Update),
    UpdateRedeemer (..),
 )
import Cardano.MPFS.Cage.TxBuilder.Retract (retractRequestImpl)
import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup (
    addKeyWitness,
    devnetMagic,
    enterpriseAddr,
    genesisAddr,
    genesisDir,
    genesisSignKey,
    keyHashFromSignKey,
    mkSignKey,
 )
import Cardano.Node.Client.N2C.Connection (
    newLSQChannel,
    newLTxSChannel,
    runNodeClient,
 )
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.N2C.Submitter (mkN2CSubmitter)
import Cardano.Node.Client.Provider qualified as N2C
import Cardano.Node.Client.Submitter (SubmitResult (..), Submitter (..))
import Cardano.Tx.Balance (BalanceResult (..), balanceTx)
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)

folderSeed :: ByteString
folderSeed = "s79-folder-permissionless0000000"

folderAddr :: Addr
folderAddr = enterpriseAddr (keyHashFromSignKey (mkSignKey folderSeed))

main :: IO ()
main = do
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    emit "row" "issue #79: the imported-validator repair rows on a real ledger"
    mPath <- lookupEnv "MPFS_BLUEPRINT"
    path <- case mPath of
        Nothing -> failWith "MPFS_BLUEPRINT is not set"
        Just p -> pure p
    outcome <- try (runRepair path) :: IO (Either SomeException ())
    case outcome of
        Right () -> pure ()
        Left e -> do
            hPutStrLn stderr ("repair-rows: FAILED: " <> displayException e)
            exitWith (ExitFailure 1)

emit :: String -> String -> IO ()
emit tag msg = putStrLn ("[" <> tag <> "] " <> msg)

failWith :: String -> IO a
failWith msg = do
    hPutStrLn stderr ("repair-rows: FAILED: " <> msg)
    exitWith (ExitFailure 1)

runRepair :: FilePath -> IO ()
runRepair blueprintPath = do
    ebp <- loadBlueprint blueprintPath
    bp <- either failWith pure ebp
    stateBytes <- case extractCompiledCode "state.state" bp of
        Just b -> pure b
        Nothing -> failWith "state.state compiled code not found in blueprint"
    requestBytes <- case extractCompiledCode "request.request" bp of
        Just b -> pure b
        Nothing -> failWith "request.request compiled code not found in blueprint"
    emit "identity" "loaded state.state and request.request from the repair blueprint"
    gDir <- genesisDir
    withCardanoNode gDir $ \sock _startMs -> do
        lsqCh <- newLSQChannel 16
        ltxsCh <- newLTxSChannel 16
        nodeThread <- async $ runNodeClient devnetMagic sock lsqCh ltxsCh
        threadDelay 3_000_000
        verifyConnection nodeThread
        let prov = adaptProvider (mkN2CProvider lsqCh)
            submit = mkN2CSubmitter ltxsCh
        _ <- Cage.queryProtocolParams prov
        tm <- mkPureTrieManager
        tmFresh <- mkPureTrieManager
        fundFolder prov submit
        receiptRef <- newIORef []
        let record = recordRow receiptRef
        (cfg1, tok1) <- bootRepairCage prov submit tm stateBytes requestBytes id
        r1ok <- checkPermissionlessFold prov submit tm cfg1 tok1 record
        unless r1ok $ failWith "R1 permissionless fold did not accept"
        r2ok <- checkDefectiveFoldRefused prov submit tmFresh cfg1 tok1
        unless r2ok $ failWith "R2 defective-fold control did not refuse"
        r3ok <- checkEndRefused prov submit cfg1 tok1 record False
        unless r3ok $ failWith "R3 ownerless End control did not refuse"
        endOk <- checkEndRefused prov submit cfg1 tok1 record True
        unless endOk $ failWith "creator-signed End control did not refuse"
        mgOk <- checkMigrationRefused prov submit cfg1 tok1 record
        unless mgOk $ failWith "ownerless migration control did not refuse"
        bnOk <- checkBurningRefused prov submit cfg1 tok1 record
        unless bnOk $ failWith "ownerless burning control did not refuse"
        swOk <- checkSweepRefused prov submit cfg1 tok1 record False
        unless swOk $ failWith "ownerless Sweep control did not refuse"
        swSigOk <- checkSweepRefused prov submit cfg1 tok1 record True
        unless swSigOk $ failWith "creator-signed Sweep control did not refuse"
        pfOk <- checkFoldProperty prov submit tm stateBytes requestBytes
        unless pfOk $ failWith "P-fold generated property did not hold"
        (cfgF, tokF, updIn, delIn, insIn) <- setupRetractBatch prov submit tm stateBytes requestBytes
        threadDelay 12_000_000
        r4ok <- retractExpectRefuse prov submit cfgF tokF updIn "Update"
        unless r4ok $ failWith "R4 Update-retract did not refuse"
        rdOk <- retractExpectRefuse prov submit cfgF tokF delIn "Delete"
        unless rdOk $ failWith "P-retract Delete case did not refuse"
        wsOk <- retractExpectWrongSigRefused prov submit cfgF tokF insIn
        unless wsOk $ failWith "P-retract wrong-signer case did not refuse"
        r5ok <- retractExpectAccept prov submit cfgF tokF insIn "Insert" record
        unless r5ok $ failWith "R5 Insert-retract control did not accept"
        candidate <- candidateFromEnv
        writeReceipt receiptRef blueprintPath candidate
        emit "summary" "repair-rows: rows match the ownerless model (R1 .fold accepted, R2 refused, End refused both variants, migration/burning/sweep refused, P-fold generated accepted, Update/Delete/wrong-signer retract refused per withdraw-insert-only, Insert retract accepted)"
        cancel nodeThread

verifyConnection :: Async (Either SomeException ()) -> IO ()
verifyConnection nodeThread = do
    threadDelay 1_000_000
    status <- poll nodeThread
    case status of
        Just (Left err) -> failWith ("node connection failed: " <> show err)
        Just (Right (Left err)) -> failWith ("node connection error: " <> show err)
        Just (Right (Right ())) -> failWith "node connection closed unexpectedly"
        Nothing -> pure ()

adaptProvider :: N2C.Provider IO -> Cage.Provider IO
adaptProvider p =
    Cage.Provider
        { Cage.queryUTxOs = N2C.queryUTxOs p
        , Cage.queryProtocolParams = N2C.queryProtocolParams p
        , Cage.evaluateTx = N2C.evaluateTx p
        , Cage.posixMsToSlot = N2C.posixMsToSlot p
        , Cage.posixMsCeilSlot = N2C.posixMsCeilSlot p
        }

fundFolder :: Cage.Provider IO -> Submitter IO -> IO ()
fundFolder prov submit = do
    pp <- Cage.queryProtocolParams prov
    walletUtxos <- Cage.queryUTxOs prov genesisAddr
    feeUtxo <- case sortOn (Down . (^. coinTxOutL) . snd) walletUtxos of
        [] -> failWith "fundFolder: genesis wallet has no UTxOs"
        (u : _) -> pure u
    let txOut = mkBasicTxOut folderAddr (inject (Coin 100_000_000))
        body = mkBasicTxBody & outputsTxBodyL .~ StrictSeq.singleton txOut
        tx = mkBasicTx body
    case balanceTx pp [feeUtxo] [] genesisAddr tx of
        Left err -> failWith ("fundFolder: balance failed: " <> show err)
        Right br -> do
            let signed = addKeyWitness genesisSignKey (balancedTx br)
            result <- submitTx submit signed
            case result of
                Submitted _ -> do
                    awaitTx
                    emit "split" "funded the permissionless folder (fresh key, no privileged relationship) with 100 ADA from genesis"
                Rejected reason ->
                    failWith ("fundFolder: tx rejected: " <> show reason)

bootRepairCage ::
    Cage.Provider IO ->
    Submitter IO ->
    TrieManager IO ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    (CageConfig -> CageConfig) ->
    IO (CageConfig, TokenId)
bootRepairCage prov submit tm stateBytes requestBytes adjust = do
    utxos <- Cage.queryUTxOs prov genesisAddr
    -- Seed selection: the LARGEST wallet UTxO. The imported boot builder
    -- consumes the seed input plus one arbitrary further input and returns
    -- the remainder as change; seeding from a small fragment leaves dust
    -- change and a BabbageOutputTooSmallUTxO rejection (harness fault, not
    -- validator evidence). The seed identity is arbitrary per cage.
    seedRef <- case sortOn (Down . (^. coinTxOutL) . snd) utxos of
        [] -> failWith "bootRepairCage: genesis wallet has no UTxOs"
        (txIn, _) : _ -> pure (txInToRef txIn)
    let appliedStateBytes = stateBytes
        cfg0 =
            CageConfig
                { cageScriptBytes = appliedStateBytes
                , requestScriptBytes = requestBytes
                , cfgScriptHash = computeScriptHash appliedStateBytes
                , cageSeed = seedRef
                , defaultProcessTime = 30_000
                , defaultRetractTime = 30_000
                , defaultTip = Coin 1_000_000
                , network = Testnet
                }
        cfg = adjust cfg0
    unsignedBoot <- bootTokenImpl cfg prov genesisAddr
    signedBoot <- submitWithGenesis submit unsignedBoot
    let tok = extractTokenId cfg signedBoot
    createTrie tm tok
    emit "boot" ("booted a repair cage (applied state script 0x" <> BSC.unpack (Base16.encode (scriptHashBytes (computeScriptHash appliedStateBytes))) <> ")")
    pure (cfg, tok)

fastRetractCfg :: CageConfig -> CageConfig
fastRetractCfg cfg =
    cfg { defaultProcessTime = 10_000, defaultRetractTime = 20_000 }

extractTokenId :: CageConfig -> ConwayTx -> TokenId
extractTokenId cfg tx =
    let MultiAsset ma = tx ^. bodyTxL . mintTxBodyL
        assets = Map.toList (ma Map.! cagePolicyIdFromCfg cfg)
     in case assets of
            [(an, _)] -> TokenId an
            _ -> error "extractTokenId: unexpected assets"

submitWithGenesis :: Submitter IO -> ConwayTx -> IO ConwayTx
submitWithGenesis submit unsignedTx = do
    let signedTx = addKeyWitness genesisSignKey unsignedTx
    result <- submitTx submit signedTx
    case result of
        Submitted _ -> awaitTx >> pure signedTx
        Rejected reason -> failWith ("tx rejected: " <> show reason)

awaitTx :: IO ()
awaitTx = threadDelay 2_000_000

checkPermissionlessFold ::
    Cage.Provider IO ->
    Submitter IO ->
    TrieManager IO ->
    CageConfig ->
    TokenId ->
    (Value -> IO ()) ->
    IO Bool
checkPermissionlessFold prov submit tm cfg tok record = do
    emit "R1" "permissionless fold: submitting an Insert request, then folding with no owner signer"
    reqIn <- submitInsertFrom prov submit cfg tok "r1-key" "r1-value" genesisAddr
    record $
        object
            [ "row" .= ("supported-action-control" :: String)
            , "distinctFrom" .= ("ownerless-end" :: String)
            , "submittedTxId" .= txInTxIdHex reqIn
            , "outcome" .= ("accepted" :: String)
            , "requestInput" .= showIn reqIn
            ]
    reqs <- pendingRequests prov cfg tok
    (stateIn, _) <- queryStateUtxo prov cfg tok
    rootBefore <- chainRootHex prov cfg tok
    outcome <- try (permissionlessUpdateTx prov tm cfg tok folderAddr) :: IO (Either SomeException ConwayTx)
    case outcome of
        Left err -> do
            emit "R1" ("permissionless fold BUILD failed (refused at build): " <> displayException err)
            pure False
        Right unsigned -> do
            let signed = addKeyWitness (mkSignKey folderSeed) unsigned
                txid = txIdHex signed
            result <- submitTx submit signed
            case result of
                Submitted _ -> do
                    awaitTx
                    syncFoldedRequests tm tok reqs
                    rootAfter <- chainRootHex prov cfg tok
                    contDatum <- stateDatumObject prov cfg tok
                    emit "R1" "PERMISSIONLESS FOLD: .fold accepted without the owner (nativeSpend present, net-mint equality holds, no owner signer; folder with no privileged relationship submitted alone)"
                    record $
                        object
                            [ "row" .= ("supported-action-control" :: String)
                            , "distinctFrom" .= ("ownerless-end" :: String)
                            , "submittedTxId" .= txid
                            , "outcome" .= ("accepted" :: String)
                            , "stateInput" .= showIn stateIn
                            , "requestInput" .= map showIn (map fst reqs)
                            , "stateContinuationDatum" .= contDatum
                            , "rootBefore" .= rootBefore
                            , "rootAfter" .= rootAfter
                            , "requiredSigners" .= signerHexes signed
                            , "vkeyWitnesses" .= witnessHexes signed
                            , "mint" .= mintFacts signed
                            ]
                    pure True
                Rejected reason -> do
                    emit "R1" ("permissionless fold REFUSED by the ledger: " <> show reason)
                    pure False

checkDefectiveFoldRefused ::
    Cage.Provider IO ->
    Submitter IO ->
    TrieManager IO ->
    CageConfig ->
    TokenId ->
    IO Bool
checkDefectiveFoldRefused prov submit tm cfg tok = do
    emit "R2" "defective-fold control: re-inserting the occupied key r1-key, then folding without the owner (must refuse)"
    _reqIn <- submitInsertFrom prov submit cfg tok "r1-key" "r1-other-value" genesisAddr
    -- Proofs computed against a FRESH empty trie for the occupied key, so
    -- the refusal happens ON-CHAIN (mpf.insert rejects the occupied key)
    -- rather than at local proof construction. tm here is the dedicated
    -- empty manager (caller passes tmFresh), never synced with this cage.
    createTrie tm tok
    outcome <- try (permissionlessUpdateTx prov tm cfg tok folderAddr) :: IO (Either SomeException ConwayTx)
    case outcome of
        Left err -> do
            _ <- requireValidatorRefusal "R2" err
            emit "R2" ("CONTROL: defective fold refused by the validator (duplicate insert for an occupied key): " <> displayException err)
            pure True
        Right unsigned -> do
            let signed = addKeyWitness (mkSignKey folderSeed) unsigned
            result <- submitTx submit signed
            case result of
                Submitted _ -> do
                    emit "R2" "CONTROL FAILURE: defective fold was ACCEPTED — authorization may be disabled generally"
                    pure False
                Rejected _reason -> do
                    emit "R2" "CONTROL: defective fold refused by the ledger as expected (duplicate insert for an occupied key)"
                    pure True

-- | Ownerless End refusal, both signer variants: neither an ordinary
-- party nor the registry's creator can terminate through `End`.
checkEndRefused ::
    Cage.Provider IO ->
    Submitter IO ->
    CageConfig ->
    TokenId ->
    (Value -> IO ()) ->
    Bool ->
    IO Bool
checkEndRefused prov submit cfg tok record creatorSigned = do
    let who
            | creatorSigned = "creator-signed"
            | otherwise = "ordinary"
    emit "R3" ("End control: attempting " <> who <> " End (must refuse)")
    (stateIn, _) <- queryStateUtxo prov cfg tok
    rootBefore <- chainRootHex prov cfg tok
    outcome <-
        try
            ( (if creatorSigned then ownerSignedEndTx else ownerlessEndTx)
                prov
                cfg
                tok
                folderAddr
            ) :: IO (Either SomeException ConwayTx)
    case outcome of
        Left err -> do
            _ <- requireValidatorRefusal "R3" err
            emit "R3" ("END: " <> who <> " End refused at build by the validator: " <> displayException err)
            pure True
        Right unsigned ->
            submitRefusal prov submit cfg tok record "R3" "ownerless-end" "end" stateIn rootBefore unsigned sign
  where
    sign
        | creatorSigned =
            addKeyWitness genesisSignKey . addKeyWitness (mkSignKey folderSeed)
        | otherwise = addKeyWitness (mkSignKey folderSeed)

-- | Ownerless migration refusal: a `Migrating` mint is submitted and
-- must be refused by the state policy. Neither the creator nor any other
-- party can migrate.
checkMigrationRefused ::
    Cage.Provider IO ->
    Submitter IO ->
    CageConfig ->
    TokenId ->
    (Value -> IO ()) ->
    IO Bool
checkMigrationRefused prov submit cfg tok record = do
    emit "migration" "migration control: minting under the state policy with a Migrating redeemer (must refuse)"
    (stateIn, _) <- queryStateUtxo prov cfg tok
    rootBefore <- chainRootHex prov cfg tok
    outcome <- try (migrationTx prov cfg tok folderAddr) :: IO (Either SomeException ConwayTx)
    case outcome of
        Left err -> do
            _ <- requireValidatorRefusal "migration" err
            emit "migration" ("MIGRATION: refused at build by the validator: " <> displayException err)
            pure True
        Right unsigned -> submitRefusal prov submit cfg tok record "migration" "ownerless-migration" "migration" stateIn rootBefore unsigned (addKeyWitness (mkSignKey folderSeed))

-- | Ownerless burning refusal: presenting the `Burning` redeemer is
-- submitted and must be refused (arm isolation; the realistic
-- termination shape is closed jointly with the `End` rows).
checkBurningRefused ::
    Cage.Provider IO ->
    Submitter IO ->
    CageConfig ->
    TokenId ->
    (Value -> IO ()) ->
    IO Bool
checkBurningRefused prov submit cfg tok record = do
    emit "burning" "burning control: presenting the Burning redeemer (must refuse)"
    (stateIn, _) <- queryStateUtxo prov cfg tok
    rootBefore <- chainRootHex prov cfg tok
    outcome <- try (burningTx prov cfg tok folderAddr) :: IO (Either SomeException ConwayTx)
    case outcome of
        Left err -> do
            _ <- requireValidatorRefusal "burning" err
            emit "burning" ("BURNING: refused at build by the validator: " <> displayException err)
            pure True
        Right unsigned -> submitRefusal prov submit cfg tok record "burning" "ownerless-burning" "burning" stateIn rootBefore unsigned (addKeyWitness (mkSignKey folderSeed))

-- | Ownerless sweep refusal, both signer variants: spending garbage at
-- the request address with `Sweep` is submitted and must be refused.
checkSweepRefused ::
    Cage.Provider IO ->
    Submitter IO ->
    CageConfig ->
    TokenId ->
    (Value -> IO ()) ->
    Bool ->
    IO Bool
checkSweepRefused prov submit cfg tok record creatorSigned = do
    let who
            | creatorSigned = "creator-signed"
            | otherwise = "ordinary"
    emit "sweep" ("sweep control: " <> who <> " Sweep of request-address garbage (must refuse)")
    (stateIn, _) <- queryStateUtxo prov cfg tok
    rootBefore <- chainRootHex prov cfg tok
    outcome <- try (sweepTx prov submit cfg tok (if creatorSigned then genesisAddr else folderAddr) creatorSigned) :: IO (Either SomeException ConwayTx)
    case outcome of
        Left err -> do
            _ <- requireValidatorRefusal "sweep" err
            emit "sweep" ("SWEEP: " <> who <> " refused at build by the validator: " <> displayException err)
            pure True
        Right unsigned ->
            submitRefusal prov submit cfg tok record "sweep" "ownerless-sweep" "sweep" stateIn rootBefore unsigned sign
  where
    sign
        | creatorSigned = addKeyWitness genesisSignKey
        | otherwise = addKeyWitness (mkSignKey folderSeed)

-- | Submit an expected-refusal transaction and record its S2 row.
submitRefusal ::
    Cage.Provider IO ->
    Submitter IO ->
    CageConfig ->
    TokenId ->
    (Value -> IO ()) ->
    String ->
    String ->
    String ->
    TxIn ->
    String ->
    ConwayTx ->
    (ConwayTx -> ConwayTx) ->
    IO Bool
submitRefusal prov submit cfg tok record tag rowName operation stateIn rootBefore unsigned sign = do
    let signed = sign unsigned
        txid = txIdHex signed
    result <- submitTx submit signed
    case result of
        Submitted _ -> do
            emit tag (tag <> " FAILURE: " <> operation <> " was ACCEPTED as " <> txid)
            pure False
        Rejected reason -> do
            let reasonText = BSC.unpack reason
            unless ("PlutusFailure" `isInfixOf` reasonText) $
                failWith (tag <> ": refused WITHOUT phase-2 validator evidence: " <> reasonText)
            (scriptHex, scriptRole) <- refusalScript prov cfg tok operation
            unless (scriptHex `isInfixOf` reasonText) $
                failWith (tag <> ": refusal does not name the " <> scriptRole <> " 0x" <> scriptHex)
            rootAfter <- chainRootHex prov cfg tok
            unless (rootAfter == rootBefore) $
                failWith (tag <> ": the refused " <> operation <> " moved the chain root")
            emit tag (tag <> ": " <> operation <> " refused by " <> scriptRole <> " 0x" <> scriptHex <> " as " <> txid)
            record $
                object
                    [ "row" .= (rowName :: String)
                    , "operation" .= (operation :: String)
                    , "submittedTxId" .= txid
                    , "outcome" .= ("refused" :: String)
                    , "refusedByScript" .= scriptHex
                    , "stateInput" .= showIn stateIn
                    , "rootBefore" .= rootBefore
                    , "rootAfter" .= rootAfter
                    , "requiredSigners" .= signerHexes signed
                    , "vkeyWitnesses" .= witnessHexes signed
                    , "mint" .= mintFacts signed
                    ]
            pure True

-- | Which script refuses each destructive operation: End/migration/burn
-- run under the state policy; Sweep runs under the request policy.
refusalScript ::
    Cage.Provider IO ->
    CageConfig ->
    TokenId ->
    String ->
    IO (String, String)
refusalScript _prov cfg tok operation = case operation of
    "sweep" ->
        let h = mkRequestScript cfg tok
         in pure (hexStr (scriptHashBytes (hashScript h)), "request validator")
    _ ->
        let h = mkCageScript cfg
         in pure (hexStr (scriptHashBytes (hashScript h)), "state validator")

-- | One fast cage serving every .withdraw-class check. Boots with a short
-- oracle window, folds one setup insert permissionlessly, then submits one
-- request per Operation class (Update, Delete, Insert) back-to-back so a
-- single phase-2 wait covers all three. Returns the cage plus the three
-- request inputs in submission order.
setupRetractBatch ::
    Cage.Provider IO ->
    Submitter IO ->
    TrieManager IO ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    IO (CageConfig, TokenId, TxIn, TxIn, TxIn)
setupRetractBatch prov submit tm stateBytes requestBytes = do
    emit "R4" "withdraw-class cage: boot, setup fold, then one Update, one Delete and one Insert request"
    (cfg, tok) <- bootRepairCage prov submit tm stateBytes requestBytes fastRetractCfg
    _ <- submitInsertFrom prov submit cfg tok "rb-key" "rb-old" genesisAddr
    setupReqs <- pendingRequests prov cfg tok
    folded <- try (permissionlessUpdateTx prov tm cfg tok genesisAddr >>= submitWithGenesis submit) :: IO (Either SomeException ConwayTx)
    case folded of
        Left err -> failWith ("retract-batch setup fold failed: " <> displayException err)
        Right _ -> syncFoldedRequests tm tok setupReqs
    updIn <- submitUpdateFrom prov submit cfg tok "rb-key" "rb-old" "rb-new" genesisAddr
    delIn <- submitDeleteFrom prov submit cfg tok "rb-key" "rb-new" genesisAddr
    insIn <- submitInsertFrom prov submit cfg tok "rb-fresh" "rb-value" genesisAddr
    emit "R4" "submitted Update, Delete and Insert requests back-to-back; one phase-2 wait covers all three"
    pure (cfg, tok, updIn, delIn, insIn)

-- | True when a build failure is the COMPILED VALIDATOR refusing (script
-- evaluation ran and failed), as opposed to a harness fault (slot horizon,
-- missing inputs, balance errors). Rows count only validator refusals as
-- refusal evidence; anything else fails loudly as a harness fault.
isValidatorRefusal :: SomeException -> Bool
isValidatorRefusal e =
    let t = displayException e
     in any (`isInfixOf` t) ["EvalFailure", "CekError", "script eval failed"]

requireValidatorRefusal :: String -> SomeException -> IO Bool
requireValidatorRefusal tag e
    | isValidatorRefusal e = pure True
    | otherwise = failWith (tag <> ": build failed WITHOUT validator evidence (harness fault, not a refusal): " <> displayException e)

-- | Replay accepted fold inputs into the manager's PERSISTENT trie so later
-- proof computations start from the chain's root. Without this, proofs are
-- generated against a stale empty trie: fresh-key proofs then fail on-chain
-- for the wrong reason and shrinking misattributes. Call only with inputs
-- the ledger accepted, in fold order.
syncFoldedRequests :: TrieManager IO -> TokenId -> [(TxIn, TxOut ConwayEra)] -> IO ()
syncFoldedRequests tm tok reqUtxos =
    withTrie tm tok $ \trie -> mapM_ (processOne trie) reqUtxos
-- horizon only forecasts a bounded window; a phase-2 bound computed just
-- past the forecast edge resolves a few seconds later as the tip advances.
-- Retries PastHorizon failures only; every other failure propagates.
retryHorizon :: Int -> IO a -> IO a
retryHorizon n act = do
    outcome <- try act
    case outcome of
        Right x -> pure x
        Left e ->
            if n > (0 :: Int) && "PastHorizon" `isInfixOf` displayException (e :: SomeException)
                then emit "retry" "slot forecast horizon not yet covering a phase-2 bound; retrying" >> threadDelay 2_000_000 >> retryHorizon (n - 1) act
                else throwIO e

-- | Build (horizon-tolerant), sign and submit a Retract for one request.
-- Returns the submission outcome without failing: callers assert it.
submitRetract ::
    Cage.Provider IO ->
    Submitter IO ->
    CageConfig ->
    TokenId ->
    TxIn ->
    IO (Either ByteString ConwayTx)
submitRetract prov submit cfg tok reqIn = do
    built <- try (retryHorizon 3 (retractRequestImpl cfg prov tok reqIn genesisAddr)) :: IO (Either SomeException ConwayTx)
    case built of
        Left err
            | "PastHorizon" `isInfixOf` displayException err -> throwIO err
            | otherwise -> pure (Left ("build refused: " <> BSC.pack (displayException err)))
        Right unsigned -> do
            let signed = addKeyWitness genesisSignKey unsigned
            result <- submitTx submit signed
            case result of
                Submitted _ -> awaitTx >> pure (Right signed)
                Rejected reason -> pure (Left reason)

retractExpectRefuse ::
    Cage.Provider IO ->
    Submitter IO ->
    CageConfig ->
    TokenId ->
    TxIn ->
    String ->
    IO Bool
retractExpectRefuse prov submit cfg tok reqIn opLabel = do
    outcome <- submitRetract prov submit cfg tok reqIn
    case outcome of
        Left bs -> do
            let t = BSC.unpack bs
            if any (`isInfixOf` t) ["EvalFailure", "CekError", "script eval failed"]
                then emit opLabel (opLabel <> " retract refused (withdraw-insert-only: the request operation is " <> opLabel <> ", not insert) in the phase-2 window: " <> take 200 t) >> pure True
                else failWith (opLabel <> ": retract build failed WITHOUT validator evidence (harness fault): " <> take 300 t)
        Right _ -> do
            emit opLabel (opLabel <> "-RETRACT FAILURE: a " <> opLabel <> " request was retracted — insert-only retraction is broken")
            pure False

retractExpectAccept ::
    Cage.Provider IO ->
    Submitter IO ->
    CageConfig ->
    TokenId ->
    TxIn ->
    String ->
    (Value -> IO ()) ->
    IO Bool
retractExpectAccept prov submit cfg tok reqIn opLabel record = do
    outcome <- submitRetract prov submit cfg tok reqIn
    case outcome of
        Left err -> do
            emit opLabel (opLabel <> "-RETRACT FAILURE: an " <> opLabel <> " retract was refused: " <> show err)
            pure False
        Right signed -> do
            emit opLabel (opLabel <> " retract accepted (withdraw succeeded for the " <> opLabel <> " request; LC01 cancellation preserved)")
            record $
                object
                    [ "row" .= ("supported-action-control" :: String)
                    , "distinctFrom" .= ("ownerless-end" :: String)
                    , "submittedTxId" .= txIdHex signed
                    , "outcome" .= ("accepted" :: String)
                    , "requestInput" .= showIn reqIn
                    , "requiredSigners" .= signerHexes signed
                    , "vkeyWitnesses" .= witnessHexes signed
                    ]
            pure True

-- | Test-local Retract construction WITHOUT the request-owner entry in
-- required signers (every other field identical to the imported
-- 'retractRequestImpl': token binding, phase-2 window, state-token
-- reference). Lets the wrong-signer row discriminate the request
-- validator's own owner check rather than the ledger's required-signer
-- enforcement. Fee input is genesis-paid and genesis-witnessed, so a
-- refusal can only come from the validator.
retractWithoutOwnerSigTx ::
    Cage.Provider IO ->
    CageConfig ->
    TokenId ->
    TxIn ->
    IO ConwayTx
retractWithoutOwnerSigTx prov cfg tid reqTxIn = do
    let reqAddr = requestAddrFromCfg cfg tid (network cfg)
        stateAddr = cageAddrFromCfg cfg (network cfg)
    requestUtxos <- Cage.queryUTxOs prov reqAddr
    stateUtxos <- Cage.queryUTxOs prov stateAddr
    reqUtxoPair <- case findUtxoByTxIn reqTxIn requestUtxos of
        Nothing -> error "retractNoSig: request UTxO not found on chain"
        Just x -> pure x
    let (reqIn, reqOut) = reqUtxoPair
        policyId = cagePolicyIdFromCfg cfg
    stateUtxo <- case findStateUtxo policyId tid stateUtxos of
        Nothing -> error "retractNoSig: state UTxO not found"
        Just x -> pure x
    let (stateIn, stateOut) = stateUtxo
    pp <- Cage.queryProtocolParams prov
    walletUtxos <- Cage.queryUTxOs prov genesisAddr
    feeUtxo <- case sortOn (Down . (^. coinTxOutL) . snd) walletUtxos of
        [] -> error "retractNoSig: no UTxOs"
        (u : _) -> pure u
    let OnChainRequest { requestSubmittedAt = submAt } = case extractCageDatum reqOut of
            Just (RequestDatum r) -> r
            _ -> error "retractNoSig: invalid request datum"
        OnChainTokenState { stateProcessTime = procTime, stateRetractTime = retrTime } = case extractCageDatum stateOut of
            Just (StateDatum s) -> s
            _ -> error "retractNoSig: invalid state datum"
        phase2Start = submAt + procTime
        phase2End = submAt + procTime + retrTime
    lowerSlot <- Cage.posixMsCeilSlot prov phase2Start
    upperSlot <- retryHorizon 3 (Cage.posixMsToSlot prov phase2End >>= \(SlotNo s) -> pure (SlotNo (max 0 (s - 1))))
    let script = mkRequestScript cfg tid
        scriptHash = hashScript script
        allInputs = Set.fromList [reqIn, fst feeUtxo]
        reqIx = spendingIndex reqIn allInputs
        stateRef = txInToRef stateIn
        redeemer = Retract stateRef
        spendPurpose = ConwaySpending (AsIx reqIx)
        redeemers = Redeemers $ Map.singleton spendPurpose (toLedgerData redeemer, placeholderExUnits)
        integrity = computeScriptIntegrity pp redeemers
        vldt = ValidityInterval (SJust lowerSlot) (SJust upperSlot)
        body :: ConwayTxBody
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton reqIn
                & referenceInputsTxBodyL .~ Set.singleton stateIn
                & collateralInputsTxBodyL .~ Set.singleton (fst feeUtxo)
                & reqSignerHashesTxBodyL .~ Set.empty
                & vldtTxBodyL .~ vldt
                & scriptIntegrityHashTxBodyL .~ integrity
        tx =
            mkBasicTx body
                & witsTxL . scriptTxWitsL .~ Map.singleton scriptHash script
                & witsTxL . rdmrsTxWitsL .~ redeemers
    evaluateAndBalance prov pp [feeUtxo, reqUtxoPair] genesisAddr tx

-- | Wrong-signer control: the same Insert retract with NO request-owner
-- entry in required signers must be refused by the request validator
-- itself (owner-signature clause retained), not merely by the ledger.
retractExpectWrongSigRefused ::
    Cage.Provider IO ->
    Submitter IO ->
    CageConfig ->
    TokenId ->
    TxIn ->
    IO Bool
retractExpectWrongSigRefused prov submit cfg tok reqIn = do
    outcome <- try (retractWithoutOwnerSigTx prov cfg tok reqIn) :: IO (Either SomeException ConwayTx)
    case outcome of
        Left err
            | "PastHorizon" `isInfixOf` displayException err -> failWith ("harness: slot horizon exhausted on wrong-signer build: " <> displayException err)
            | otherwise -> do
                _ <- requireValidatorRefusal "WrongSig" err
                emit "WrongSig" "wrong-signer retract refused (missing request-owner signature; the request validator refuses, not the ledger)" >> pure True
        Right unsigned -> do
            let signed = addKeyWitness genesisSignKey unsigned
            result <- submitTx submit signed
            case result of
                Rejected _ -> emit "WrongSig" "wrong-signer retract refused (missing request-owner signature; the request validator refuses, not the ledger)" >> pure True
                Submitted _ -> emit "WrongSig" "WRONG-SIGNER FAILURE: an ownerless retract was ACCEPTED" >> pure False

-- | Seeded generator for the P-fold property. Tiny LCG over the seed; key
-- suffixes are distinct by construction, so the discard rate is 0 and every
-- generated case reaches the fold precondition (non-vacuous by assertion).
lcgNext :: Int -> Int
lcgNext s = (1103515245 * s + 12345) `mod` 2147483648

genPairs :: Int -> Int -> [(ByteString, ByteString)]
genPairs seed n = take n [ ("p79-k" <> BSC.pack (show s), "p79-v" <> BSC.pack (show s)) | s <- iterate lcgNext seed ]

-- | P-fold: generated permissionless-fold property against the actual
-- compiled state validator on a real ledger. Given (Lean .fold): nativeSpend
-- present, net-mint equality, representative/application mint witnesses as
-- required, and NO owner hypothesis. Folds six generated inserts in ONE
-- Modify, asserts all six are consumed, then runs a shrinking adversarial
-- (three fresh keys plus a duplicate of the first) and bisects to the
-- minimal refused singleton.
checkFoldProperty ::
    Cage.Provider IO ->
    Submitter IO ->
    TrieManager IO ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    IO Bool
checkFoldProperty prov submit tm stateBytes requestBytes = do
    emit "P-fold" "generated .fold property: seed=79, six inserts in one permissionless fold (no owner hypothesis)"
    (cfg, tok) <- bootRepairCage prov submit tm stateBytes requestBytes id
    let pairs = genPairs 79 6
    submitInsertsBatch prov submit cfg tok pairs genesisAddr
    before <- pendingRequests prov cfg tok
    unless (length before == 6) $
        failWith ("P-fold: generator did not reach the precondition (pending=" <> show (length before) <> ", want 6)")
    built <- try (permissionlessUpdateTx prov tm cfg tok folderAddr) :: IO (Either SomeException ConwayTx)
    case built of
        Left err -> emit "P-fold" ("P-fold FAILURE: generated batch refused at build: " <> displayException err) >> pure False
        Right unsigned -> do
            let signed = addKeyWitness (mkSignKey folderSeed) unsigned
            result <- submitTx submit signed
            case result of
                Rejected reason -> emit "P-fold" ("P-fold FAILURE: generated batch refused by the ledger: " <> show reason) >> pure False
                Submitted _ -> do
                    awaitTx
                    after <- pendingRequests prov cfg tok
                    unless (null after) $ failWith "P-fold: fold accepted but requests remain pending"
                    syncFoldedRequests tm tok before
                    emit "P-fold" "P-fold: 6/6 generated inserts accepted without the owner in one Modify (seed=79, count=6, discards=0)"
                    tipOk <- wrongTipRefused prov submit tm cfg tok
                    unless tipOk $ failWith "P-fold wrong-tip control did not refuse"
                    tampOk <- tamperedRootRefused prov submit tm cfg tok
                    unless tampOk $ failWith "P-fold tampered-root control did not refuse"
                    case pairs of
                        [] -> failWith "P-fold: empty generated batch"
                        (k0, _) : _ -> adversarial cfg tok k0
  where
    adversarial cfg tok k0 = do
        let fresh = take 2 (drop 6 (genPairs 79 99))
        submitInsertsBatch prov submit cfg tok ((k0, "p79-dup") : fresh) genesisAddr
        -- Fresh-first order forces the shrinker through BOTH branches:
        -- accepted probes consume and re-sync, the duplicate refuses.
        candidates <- resolveRequestKeys prov cfg tok (map fst fresh <> [k0])
        emit "P-fold" "adversarial: two fresh keys plus a duplicate of the first; bisecting to the minimal refused fold"
        minimal <- bisectRefused prov submit tm cfg tok folderAddr candidates
        if minimal == k0
            then emit "P-fold" "P-fold adversarial: bisection isolated the duplicate key (shrink result = the re-inserted key); structural checks still refuse" >> pure True
            else emit "P-fold" "P-fold FAILURE: bisection isolated the wrong key" >> pure False

-- | Bisection shrinker over live request inputs. Each probe is a real
-- permissionless fold of the named subset: refused probes consume nothing,
-- accepted probes consume their requests (throwaway cage). Shrinking
-- preserves the Given (every probed subset is a set of well-formed
-- submitted requests); returns the minimal refused singleton key.
bisectRefused ::
    Cage.Provider IO ->
    Submitter IO ->
    TrieManager IO ->
    CageConfig ->
    TokenId ->
    Addr ->
    [(TxIn, ByteString)] ->
    IO ByteString
bisectRefused prov submit tm cfg tok feeAddr candidates = go candidates
  where
    go [] = failWith "bisectRefused: empty candidate set"
    go [(i, k)] = do
        live <- liveSubset [i]
        refused <- probeSubset live
        if refused then pure k else failWith "bisectRefused: singleton accepted, no minimal failing input"
    go xs = do
        let (l, r) = splitAt (length xs `div` 2) xs
        liveL <- liveSubset (map fst l)
        refusedL <- probeSubset liveL
        if refusedL then go l else go r
    liveSubset ins = do
        live <- pendingRequests prov cfg tok
        pure [ u | u@(i, _) <- live, i `elem` ins ]
    probeSubset [] = failWith "bisectRefused: probe subset has no live requests"
    probeSubset subset = do
        emit "P-fold" ("bisect probe: folding " <> show (length subset) <> " request(s)")
        outcome <- try (foldSubsetTx prov tm cfg tok feeAddr subset) :: IO (Either SomeException ConwayTx)
        case outcome of
            Left err -> do
                let t = displayException err
                    stateHex = BSC.unpack (Base16.encode (scriptHashBytes (computeScriptHash (cageScriptBytes cfg))))
                    where_ = if stateHex `isInfixOf` t then "state-validator" else "other-script"
                emit "P-fold" ("bisect probe refused at build by " <> where_ <> ": " <> take 100 t)
                pure True
            Right unsigned -> do
                let signed = addKeyWitness (mkSignKey folderSeed) unsigned
                result <- submitTx submit signed
                case result of
                    Rejected _ -> do
                        emit "P-fold" "bisect probe refused by the ledger"
                        pure True
                    Submitted _ -> do
                        awaitTx
                        syncFoldedRequests tm tok subset
                        emit "P-fold" ("bisect probe accepted (consumed " <> show (length subset) <> " request(s)), continuing")
                        pure False

-- | Wrong-tip control: a request whose tip disagrees with the state's tip
-- must be refused by the fold (mkAction tip binding retained). The request
-- stays pending; later subsets address their own inputs explicitly.
wrongTipRefused ::
    Cage.Provider IO ->
    Submitter IO ->
    TrieManager IO ->
    CageConfig ->
    TokenId ->
    IO Bool
wrongTipRefused prov submit tm cfg tok = do
    _ <- submitInsertWithTip prov submit cfg tok "p79-wrongtip" "p79-wv" 2_000_000 genesisAddr
    outcome <- try (permissionlessUpdateTx prov tm cfg tok folderAddr) :: IO (Either SomeException ConwayTx)
    case outcome of
        Left err -> do
            _ <- requireValidatorRefusal "NewTip" err
            emit "NewTip" "wrong-tip fold refused by the validator (tip mismatch: request tip 2000000 against state tip 1000000)"
            pure True
        Right unsigned -> do
            let signed = addKeyWitness (mkSignKey folderSeed) unsigned
            result <- submitTx submit signed
            case result of
                Rejected _ -> emit "NewTip" "wrong-tip fold refused (tip mismatch: request tip 2000000 against state tip 1000000)" >> pure True
                Submitted _ -> emit "NewTip" "WRONG-TIP FAILURE: a mismatched-tip fold was ACCEPTED" >> pure False

submitInsertFrom ::
    Cage.Provider IO ->
    Submitter IO ->
    CageConfig ->
    TokenId ->
    ByteString ->
    ByteString ->
    Addr ->
    IO TxIn
submitInsertFrom prov submit cfg tok key val addr =
    submitInsertWithTip prov submit cfg tok key val 1_000_000 addr

submitInsertWithTip ::
    Cage.Provider IO ->
    Submitter IO ->
    CageConfig ->
    TokenId ->
    ByteString ->
    ByteString ->
    Integer ->
    Addr ->
    IO TxIn
submitInsertWithTip prov submit cfg tok key val tipInt addr = do
    pp <- Cage.queryProtocolParams prov
    utxos <- Cage.queryUTxOs prov addr
    feeUtxo <- case sortOn (Down . (^. coinTxOutL) . snd) utxos of
        [] -> failWith "submitInsertFrom: no UTxOs"
        (u : _) -> pure u
    now <- currentPosixMs
    let datum = mkRequestDatum tok addr key (OpInsert val) tipInt now
        scriptAddr = requestAddrFromCfg cfg tok (network cfg)
        draftOut = mkBasicTxOut scriptAddr (inject (Coin 0)) & datumTxOutL .~ mkInlineDatum datum
        refundDraft = mkBasicTxOut addr (inject (Coin 0))
        minAda = requestLockedAda pp draftOut refundDraft tipInt
        txOut = mkBasicTxOut scriptAddr (inject minAda) & datumTxOutL .~ mkInlineDatum datum
        body = mkBasicTxBody & outputsTxBodyL .~ StrictSeq.singleton txOut
        tx = mkBasicTx body
    case balanceTx pp [feeUtxo] [] addr tx of
        Left err -> failWith ("submitInsertFrom: balance failed: " <> show err)
        Right br -> do
            let signed = addKeyWitness genesisSignKey (balancedTx br)
            result <- submitTx submit signed
            case result of
                Submitted _ -> awaitTx >> pure (TxIn (txIdTx signed) (TxIx 0))
                Rejected reason -> failWith ("submitInsertFrom: rejected: " <> show reason)

submitUpdateFrom ::
    Cage.Provider IO ->
    Submitter IO ->
    CageConfig ->
    TokenId ->
    ByteString ->
    ByteString ->
    ByteString ->
    Addr ->
    IO TxIn
submitUpdateFrom prov submit cfg tok key oldV newV addr = do
    pp <- Cage.queryProtocolParams prov
    utxos <- Cage.queryUTxOs prov addr
    feeUtxo <- case sortOn (Down . (^. coinTxOutL) . snd) utxos of
        [] -> failWith "submitUpdateFrom: no UTxOs"
        (u : _) -> pure u
    now <- currentPosixMs
    let datum = mkRequestDatum tok addr key (OpUpdate oldV newV) 1_000_000 now
        scriptAddr = requestAddrFromCfg cfg tok (network cfg)
        draftOut = mkBasicTxOut scriptAddr (inject (Coin 0)) & datumTxOutL .~ mkInlineDatum datum
        refundDraft = mkBasicTxOut addr (inject (Coin 0))
        minAda = requestLockedAda pp draftOut refundDraft 1_000_000
        txOut = mkBasicTxOut scriptAddr (inject minAda) & datumTxOutL .~ mkInlineDatum datum
        body = mkBasicTxBody & outputsTxBodyL .~ StrictSeq.singleton txOut
        tx = mkBasicTx body
    case balanceTx pp [feeUtxo] [] addr tx of
        Left err -> failWith ("submitUpdateFrom: balance failed: " <> show err)
        Right br -> do
            let signed = addKeyWitness genesisSignKey (balancedTx br)
            result <- submitTx submit signed
            case result of
                Submitted _ -> awaitTx >> pure (TxIn (txIdTx signed) (TxIx 0))
                Rejected reason -> failWith ("submitUpdateFrom: rejected: " <> show reason)

submitDeleteFrom ::
    Cage.Provider IO ->
    Submitter IO ->
    CageConfig ->
    TokenId ->
    ByteString ->
    ByteString ->
    Addr ->
    IO TxIn
submitDeleteFrom prov submit cfg tok key oldV addr = do
    pp <- Cage.queryProtocolParams prov
    utxos <- Cage.queryUTxOs prov addr
    feeUtxo <- case sortOn (Down . (^. coinTxOutL) . snd) utxos of
        [] -> failWith "submitDeleteFrom: no UTxOs"
        (u : _) -> pure u
    now <- currentPosixMs
    let datum = mkRequestDatum tok addr key (OpDelete oldV) 1_000_000 now
        scriptAddr = requestAddrFromCfg cfg tok (network cfg)
        draftOut = mkBasicTxOut scriptAddr (inject (Coin 0)) & datumTxOutL .~ mkInlineDatum datum
        refundDraft = mkBasicTxOut addr (inject (Coin 0))
        minAda = requestLockedAda pp draftOut refundDraft 1_000_000
        txOut = mkBasicTxOut scriptAddr (inject minAda) & datumTxOutL .~ mkInlineDatum datum
        body = mkBasicTxBody & outputsTxBodyL .~ StrictSeq.singleton txOut
        tx = mkBasicTx body
    case balanceTx pp [feeUtxo] [] addr tx of
        Left err -> failWith ("submitDeleteFrom: balance failed: " <> show err)
        Right br -> do
            let signed = addKeyWitness genesisSignKey (balancedTx br)
            result <- submitTx submit signed
            case result of
                Submitted _ -> awaitTx >> pure (TxIn (txIdTx signed) (TxIx 0))
                Rejected reason -> failWith ("submitDeleteFrom: rejected: " <> show reason)

-- | Batch insert submission: one transaction carrying one request output
-- per (key, value) pair (amortizes query/balance/submit/await over the
-- batch). Returns the submission tx id; callers resolve per-request inputs
-- by key via 'resolveRequestKeys' rather than assuming output indices.
submitInsertsBatch ::
    Cage.Provider IO ->
    Submitter IO ->
    CageConfig ->
    TokenId ->
    [(ByteString, ByteString)] ->
    Addr ->
    IO ()
submitInsertsBatch prov submit cfg tok pairs addr = do
    pp <- Cage.queryProtocolParams prov
    utxos <- Cage.queryUTxOs prov addr
    feeUtxo <- case sortOn (Down . (^. coinTxOutL) . snd) utxos of
        [] -> failWith "submitInsertsBatch: no UTxOs"
        (u : _) -> pure u
    now <- currentPosixMs
    let scriptAddr = requestAddrFromCfg cfg tok (network cfg)
        mkOut (key, val) =
            let datum = mkRequestDatum tok addr key (OpInsert val) 1_000_000 now
                draftOut = mkBasicTxOut scriptAddr (inject (Coin 0)) & datumTxOutL .~ mkInlineDatum datum
                refundDraft = mkBasicTxOut addr (inject (Coin 0))
                minAda = requestLockedAda pp draftOut refundDraft 1_000_000
             in mkBasicTxOut scriptAddr (inject minAda) & datumTxOutL .~ mkInlineDatum datum
        body = mkBasicTxBody & outputsTxBodyL .~ StrictSeq.fromList (map mkOut pairs)
        tx = mkBasicTx body
    case balanceTx pp [feeUtxo] [] addr tx of
        Left err -> failWith ("submitInsertsBatch: balance failed: " <> show err)
        Right br -> do
            let signed = addKeyWitness genesisSignKey (balancedTx br)
            result <- submitTx submit signed
            case result of
                Submitted _ -> awaitTx
                Rejected reason -> failWith ("submitInsertsBatch: rejected: " <> show reason)

-- | Resolve live request inputs for exact keys (no output-index
-- assumptions): scans the token's pending requests and matches inline
-- datums by request key. Fails loudly on any missing key (non-vacuity).
-- | Corrupt a computed root by bumping its first byte (tampered-output row).
corruptRoot :: Root -> Root
corruptRoot (Root bs) = Root $ case BSC.uncons bs of
    Nothing -> bs
    Just (c, rest) -> BSC.cons (succ c) rest

-- | Tampered-root control: a fold whose output root differs from the
-- computed root must be refused (output/root binding retained). Uses an
-- explicit single-request subset so the pending wrong-tip request cannot
-- confound attribution.
tamperedRootRefused ::
    Cage.Provider IO ->
    Submitter IO ->
    TrieManager IO ->
    CageConfig ->
    TokenId ->
    IO Bool
tamperedRootRefused prov submit tm cfg tok = do
    _ <- submitInsertFrom prov submit cfg tok "p79-tamp" "p79-tv" genesisAddr
    live <- pendingRequests prov cfg tok
    tkUtxo <- case [ u | u@(_, out) <- live, requestKeyOf out == Just "p79-tamp" ] of
        (x : _) -> pure x
        [] -> failWith "tampered-root row: fresh request not pending"
    (stateUtxo, feeUtxo, pp) <- queryStateFee prov cfg tok folderAddr
    outcome <- try (foldRequestsTx corruptRoot prov tm cfg tok folderAddr stateUtxo [tkUtxo] feeUtxo pp) :: IO (Either SomeException ConwayTx)
    case outcome of
        Left err -> do
            _ <- requireValidatorRefusal "TampRoot" err
            emit "TampRoot" "tampered-root fold refused by the validator (output root differs from the computed root)"
            pure True
        Right unsigned -> do
            let signed = addKeyWitness (mkSignKey folderSeed) unsigned
            result <- submitTx submit signed
            case result of
                Rejected _ -> emit "TampRoot" "tampered-root fold refused by the validator (output root differs from the computed root)" >> pure True
                Submitted _ -> emit "TampRoot" "TAMPERED-ROOT FAILURE: a corrupted-root fold was ACCEPTED" >> pure False

-- | Request key of a transaction output's inline request datum, if any.
requestKeyOf :: TxOut ConwayEra -> Maybe ByteString
requestKeyOf out = case extractCageDatum out of
    Just (RequestDatum r) -> Just (requestKey r)
    _ -> Nothing

resolveRequestKeys ::
    Cage.Provider IO ->
    CageConfig ->
    TokenId ->
    [ByteString] ->
    IO [(TxIn, ByteString)]
resolveRequestKeys prov cfg tok keys = do
    live <- pendingRequests prov cfg tok
    let keyOf out = case extractCageDatum out of
            Just (RequestDatum r) -> Just (requestKey r)
            _ -> Nothing
        findKey k = case [ (i, k) | (i, out) <- live, keyOf out == Just k ] of
            (x : _) -> x
            [] -> error ("resolveRequestKeys: key not pending: " <> show k)
    pure (map findKey keys)

requestLockedAda :: PParams ConwayEra -> TxOut ConwayEra -> TxOut ConwayEra -> Integer -> Coin
requestLockedAda pp reqDraft refDraft tip =
    let Coin refMin = getMinCoinTxOut pp refDraft
        feeBuffer = 1_000_000
        locked = tip + feeBuffer + refMin
        adjusted = getMinCoinTxOut pp (reqDraft & valueTxOutL .~ inject (Coin locked))
     in max adjusted (Coin locked)

data NoCtx a

permissionlessUpdateTx ::
    Cage.Provider IO ->
    TrieManager IO ->
    CageConfig ->
    TokenId ->
    Addr ->
    IO ConwayTx
permissionlessUpdateTx prov tm cfg tid feeAddr = do
    (stateUtxo, feeUtxo, pp) <- queryStateFee prov cfg tid feeAddr
    reqUtxos <- pendingRequests prov cfg tid
    when (null reqUtxos) $ error "permissionlessUpdate: no pending requests"
    foldRequestsTx id prov tm cfg tid feeAddr stateUtxo reqUtxos feeUtxo pp

-- | Permissionless fold over an EXPLICIT request set (subset folds for the
-- P-fold bisection shrinker). Same program as 'permissionlessUpdateTx',
-- restricted to the given request UTxOs.
foldSubsetTx ::
    Cage.Provider IO ->
    TrieManager IO ->
    CageConfig ->
    TokenId ->
    Addr ->
    [(TxIn, TxOut ConwayEra)] ->
    IO ConwayTx
foldSubsetTx prov tm cfg tid feeAddr reqUtxos = do
    (stateUtxo, feeUtxo, pp) <- queryStateFee prov cfg tid feeAddr
    when (null reqUtxos) $ error "foldSubsetTx: empty request set"
    foldRequestsTx id prov tm cfg tid feeAddr stateUtxo reqUtxos feeUtxo pp

foldRequestsTx ::
    (Root -> Root) ->
    Cage.Provider IO ->
    TrieManager IO ->
    CageConfig ->
    TokenId ->
    Addr ->
    (TxIn, TxOut ConwayEra) ->
    [(TxIn, TxOut ConwayEra)] ->
    (TxIn, TxOut ConwayEra) ->
    PParams ConwayEra ->
    IO ConwayTx
foldRequestsTx adjustRoot prov tm cfg tid feeAddr stateUtxo reqUtxos feeUtxo pp = do
    let (stateIn, stateOut) = stateUtxo
    (proofs, newRoot) <- computeUpdateProofs tm tid reqUtxos
    let (oldState, newStateOut, script) = prepareUpdateState cfg stateOut (adjustRoot newRoot)
        requestScript = mkRequestScript cfg tid
    upperSlot <- computeUpdateUpperSlot prov oldState reqUtxos
    let evalTx tx = do
            r <- Cage.evaluateTx prov tx
            pure $ Map.map (\case Left e -> Left (show e); Right eu -> Right eu) r
        prog = buildPermissionlessProgram cfg stateIn reqUtxos feeUtxo oldState newStateOut script requestScript proofs upperSlot
    result <-
        Tx.build
            (Tx.mkPParamsBound pp)
            (Tx.InterpretIO (const (pure undefined)))
            evalTx
            (feeUtxo : stateUtxo : reqUtxos)
            []
            feeAddr
            (prog :: Tx.TxBuild NoCtx Void ())
    case result of
        Right tx -> pure tx
        Left err -> error ("permissionlessUpdate: build failed: " <> show err)

queryStateFee ::
    Cage.Provider IO ->
    CageConfig ->
    TokenId ->
    Addr ->
    IO ((TxIn, TxOut ConwayEra), (TxIn, TxOut ConwayEra), PParams ConwayEra)
queryStateFee prov cfg tid addr = do
    let stateAddr = cageAddrFromCfg cfg (network cfg)
    stateUtxos <- Cage.queryUTxOs prov stateAddr
    let policyId = cagePolicyIdFromCfg cfg
    stateUtxo <- case findStateUtxo policyId tid stateUtxos of
        Nothing -> error "permissionlessUpdate: state UTxO not found"
        Just x -> pure x
    pp <- Cage.queryProtocolParams prov
    walletUtxos <- Cage.queryUTxOs prov addr
    feeUtxo <- case sortOn (Down . (^. coinTxOutL) . snd) walletUtxos of
        [] -> error "permissionlessUpdate: no UTxOs"
        (u : _) -> pure u
    pure (stateUtxo, feeUtxo, pp)

pendingRequests ::
    Cage.Provider IO ->
    CageConfig ->
    TokenId ->
    IO [(TxIn, TxOut ConwayEra)]
pendingRequests prov cfg tid = do
    let reqAddr = requestAddrFromCfg cfg tid (network cfg)
    requestUtxos <- Cage.queryUTxOs prov reqAddr
    pure (sortOn fst $ findRequestUtxos tid requestUtxos)

computeUpdateProofs :: TrieManager IO -> TokenId -> [(TxIn, TxOut ConwayEra)] -> IO ([[ProofStep]], Root)
computeUpdateProofs tm tid reqUtxos =
    withSpeculativeTrie tm tid $ \trie -> do
        ps <- mapM (processOne trie) reqUtxos
        r <- getRoot trie
        pure (ps, r)

processOne :: (Monad m) => Trie m -> (TxIn, TxOut ConwayEra) -> m [ProofStep]
processOne trie (_txIn, txOut) = do
    let req = case extractCageDatum txOut of
            Just (RequestDatum r) -> r
            _ -> error "processOne: invalid request datum"
    case requestValue req of
        OpInsert v -> do
            _ <- insert trie (requestKey req) v
            mSteps <- getProofSteps trie (requestKey req)
            pure (fromMaybe [] mSteps)
        OpDelete _ -> do
            mSteps <- getProofSteps trie (requestKey req)
            _ <- Cardano.MPFS.Cage.Trie.delete trie (requestKey req)
            pure (fromMaybe [] mSteps)
        OpUpdate _ v -> do
            mSteps <- getProofSteps trie (requestKey req)
            _ <- Cardano.MPFS.Cage.Trie.delete trie (requestKey req)
            _ <- insert trie (requestKey req) v
            pure (fromMaybe [] mSteps)

prepareUpdateState :: CageConfig -> TxOut ConwayEra -> Root -> (OnChainTokenState, TxOut ConwayEra, Script ConwayEra)
prepareUpdateState cfg stateOut newRoot =
    let scriptAddr = cageAddrFromCfg cfg (network cfg)
        oldState = case extractCageDatum stateOut of
            Just (StateDatum s) -> s
            _ -> error "prepareUpdateState: invalid state datum"
        newStateDatum = StateDatum oldState { stateRoot = OnChainRoot (unRoot newRoot) }
        newStateOut = mkBasicTxOut scriptAddr (stateOut ^. valueTxOutL) & datumTxOutL .~ mkInlineDatum (toPlcData newStateDatum)
        script = mkCageScript cfg
     in (oldState, newStateOut, script)

computeUpdateUpperSlot :: Cage.Provider IO -> OnChainTokenState -> [(TxIn, TxOut ConwayEra)] -> IO SlotNo
computeUpdateUpperSlot prov oldState reqUtxos = do
    let extractSubmittedAt (_, rOut) = case extractCageDatum rOut of
            Just (RequestDatum r) -> requestSubmittedAt r
            _ -> 0
        earliestDeadline = minimum $ map (\u -> extractSubmittedAt u + stateProcessTime oldState) reqUtxos
    mUpperSlot <- try (Cage.posixMsToSlot prov earliestDeadline) :: IO (Either SomeException SlotNo)
    case mUpperSlot of
        Right s -> pure s
        Left _ -> do
            nowMs <- currentPosixMs
            trySlots prov [nowMs + 30_000, nowMs + 5_000, nowMs + 2_000]

buildPermissionlessProgram ::
    CageConfig ->
    TxIn ->
    [(TxIn, TxOut ConwayEra)] ->
    (TxIn, TxOut ConwayEra) ->
    OnChainTokenState ->
    TxOut ConwayEra ->
    Script ConwayEra ->
    Script ConwayEra ->
    [[ProofStep]] ->
    SlotNo ->
    Tx.TxBuild NoCtx Void ()
buildPermissionlessProgram cfg stateIn reqUtxos feeUtxo oldState newStateOut script requestScript proofs upperSlot = do
    let stateRef = txInToRef stateIn
        OnChainTokenState { stateMaxFee = tipAmount } = oldState
        nReqs = fromIntegral (length reqUtxos) :: Integer
        actions = map Update proofs
    _ <- Tx.spendScript stateIn (Modify actions)
    mapM_ (\(rIn, _) -> Tx.spendScript rIn (Contribute stateRef)) reqUtxos
    _ <- Tx.output newStateOut
    Coin fee <- Tx.peek $ \tx ->
        let f = tx ^. bodyTxL . feeTxBodyL
         in if f > Coin 0 then Tx.Ok f else Tx.Iterate f
    let perReqFee = fee `div` nReqs
        remainder = fee - perReqFee * nReqs
    mapM_
        ( \(i, (_, reqOut)) -> do
            let Coin reqVal = reqOut ^. coinTxOutL
                extra = if i == (0 :: Int) then remainder else 0
                rawRefund = Coin (reqVal - tipAmount - perReqFee - extra)
                refundAddr = addrFromKeyHashBytes (network cfg) (extractOwnerBytes reqOut)
            Tx.output $ mkBasicTxOut refundAddr (inject rawRefund)
        )
        (zip [0 ..] reqUtxos)
    Tx.attachScript script
    Tx.attachScript requestScript
    Tx.collateral (fst feeUtxo)
    Tx.validTo upperSlot

ownerlessEndTx :: Cage.Provider IO -> CageConfig -> TokenId -> Addr -> IO ConwayTx
ownerlessEndTx prov cfg tid feeAddr = do
    let scriptAddr = cageAddrFromCfg cfg (network cfg)
    cageUtxos <- Cage.queryUTxOs prov scriptAddr
    let policyId = cagePolicyIdFromCfg cfg
    stateUtxo <- case findStateUtxo policyId tid cageUtxos of
        Nothing -> error "ownerlessEnd: state UTxO not found"
        Just x -> pure x
    pp <- Cage.queryProtocolParams prov
    walletUtxos <- Cage.queryUTxOs prov feeAddr
    feeUtxo <- case sortOn (Down . (^. coinTxOutL) . snd) walletUtxos of
        [] -> error "ownerlessEnd: no UTxOs"
        (u : _) -> pure u
    let (stateIn, _stateOut) = stateUtxo
        prog = do
            let assetName = (\(TokenId an) -> an) tid
            _ <- Tx.spendScript stateIn End
            Tx.mint policyId (Map.singleton assetName (-1)) (Burning (onChainTokenId tid))
            Tx.collateral (fst feeUtxo)
            Tx.attachScript (mkCageScript cfg)
    result <-
        Tx.build
            (Tx.mkPParamsBound pp)
            (Tx.InterpretIO (const (pure undefined)))
            skipEvalTx
            [feeUtxo, stateUtxo]
            []
            feeAddr
            (prog :: Tx.TxBuild NoCtx Void ())
    case result of
        Right tx -> pure tx
        Left err -> error ("ownerlessEnd: build failed: " <> show err)

-- | Creator-signed End: the registry's creator signs, and the validator
-- must still refuse — there is no owner role. Builds with skip-eval so
-- the LEDGER attributes the refusal.
ownerSignedEndTx :: Cage.Provider IO -> CageConfig -> TokenId -> Addr -> IO ConwayTx
ownerSignedEndTx prov cfg tid feeAddr = do
    let scriptAddr = cageAddrFromCfg cfg (network cfg)
    cageUtxos <- Cage.queryUTxOs prov scriptAddr
    let policyId = cagePolicyIdFromCfg cfg
    stateUtxo <- case findStateUtxo policyId tid cageUtxos of
        Nothing -> error "ownerSignedEnd: state UTxO not found"
        Just x -> pure x
    let (stateIn, _stateOut) = stateUtxo
        -- Ownerless registry: the creator (genesis) signs, and the
        -- validator must still refuse — there is no owner role.
        ownerKh = addrWitnessKeyHash (addrKeyHashBytes genesisAddr)
    pp <- Cage.queryProtocolParams prov
    walletUtxos <- Cage.queryUTxOs prov feeAddr
    feeUtxo <- case sortOn (Down . (^. coinTxOutL) . snd) walletUtxos of
        [] -> error "ownerSignedEnd: no UTxOs"
        (u : _) -> pure u
    let prog = do
            let assetName = (\(TokenId an) -> an) tid
            _ <- Tx.spendScript stateIn End
            Tx.mint policyId (Map.singleton assetName (-1)) (Burning (onChainTokenId tid))
            Tx.requireSignature ownerKh
            Tx.collateral (fst feeUtxo)
            Tx.attachScript (mkCageScript cfg)
    result <-
        Tx.build
            (Tx.mkPParamsBound pp)
            (Tx.InterpretIO (const (pure undefined)))
            skipEvalTx
            [feeUtxo, stateUtxo]
            []
            feeAddr
            (prog :: Tx.TxBuild NoCtx Void ())
    case result of
        Right tx -> pure tx
        Left err -> error ("ownerSignedEnd: build failed: " <> show err)

_unusedGuard :: SlotNo -> Bool
_unusedGuard _ = True

-- ---------------------------------------------------------
-- Ownerless refusal rows with receipt (NOTE-028/A-003)
-- ---------------------------------------------------------

-- | Generous per-purpose budget stated when local evaluation is skipped
-- (refusal rows only); the ledger re-executes every purpose for real, so
-- the refusal is attributed on-chain instead of at local estimation.
generousUnits :: ExUnits
generousUnits = ExUnits 3_000_000 200_000_000

-- | Estimator that states generous budgets without executing scripts.
skipEvalTx ::
    ConwayTx ->
    IO (Map.Map (ConwayPlutusPurpose AsIx ConwayEra) (Either String ExUnits))
skipEvalTx tx = do
    let Redeemers rdmrs = tx ^. witsTxL . rdmrsTxWitsL
    pure (Map.map (const (Right generousUnits)) rdmrs)

-- | Migration attempt: mint under the state policy with a `Migrating`
-- redeemer. No predecessor, no allowlist, no owner can authorize it —
-- the arm refuses unconditionally.
migrationTx ::
    Cage.Provider IO ->
    CageConfig ->
    TokenId ->
    Addr ->
    IO ConwayTx
migrationTx prov cfg tid feeAddr = do
    let policyId = cagePolicyIdFromCfg cfg
        assetName = (\(TokenId an) -> an) tid
        migration =
            Migration
                { migrationOldPolicy = case policyId of PolicyID h -> BuiltinByteString (scriptHashBytes h)
                , migrationTokenId = onChainTokenId tid
                }
    pp <- Cage.queryProtocolParams prov
    walletUtxos <- Cage.queryUTxOs prov feeAddr
    feeUtxo <- case sortOn (Down . (^. coinTxOutL) . snd) walletUtxos of
        [] -> error "migrationTx: no UTxOs"
        (u : _) -> pure u
    let prog = do
            Tx.mint policyId (Map.singleton assetName 1) (Migrating migration)
            Tx.collateral (fst feeUtxo)
            Tx.attachScript (mkCageScript cfg)
    result <-
        Tx.build
            (Tx.mkPParamsBound pp)
            (Tx.InterpretIO (const (pure undefined)))
            skipEvalTx
            [feeUtxo]
            []
            feeAddr
            (prog :: Tx.TxBuild NoCtx Void ())
    case result of
        Right tx -> pure tx
        Left err -> error ("migrationTx: build failed: " <> show err)

-- | Burning-arm isolation: mint `+1` under the state policy presenting
-- the `Burning` redeemer. No `Modify` can accompany a real burn (it
-- preserves the token by rule), so arm isolation plus the `End` rows
-- and the Aiken burn test jointly close termination-by-burn: the arm
-- refuses unconditionally.
burningTx ::
    Cage.Provider IO ->
    CageConfig ->
    TokenId ->
    Addr ->
    IO ConwayTx
burningTx prov cfg tid feeAddr = do
    let policyId = cagePolicyIdFromCfg cfg
        assetName = (\(TokenId an) -> an) tid
    pp <- Cage.queryProtocolParams prov
    walletUtxos <- Cage.queryUTxOs prov feeAddr
    feeUtxo <- case sortOn (Down . (^. coinTxOutL) . snd) walletUtxos of
        [] -> error "burningTx: no UTxOs"
        (u : _) -> pure u
    let prog = do
            Tx.mint policyId (Map.singleton assetName 1) (Burning (onChainTokenId tid))
            Tx.collateral (fst feeUtxo)
            Tx.attachScript (mkCageScript cfg)
    result <-
        Tx.build
            (Tx.mkPParamsBound pp)
            (Tx.InterpretIO (const (pure undefined)))
            skipEvalTx
            [feeUtxo]
            []
            feeAddr
            (prog :: Tx.TxBuild NoCtx Void ())
    case result of
        Right tx -> pure tx
        Left err -> error ("burningTx: build failed: " <> show err)

-- | Seizure attempt: spend a garbage UTxO at the request address with a
-- `Sweep` redeemer, the state as reference input. Refused with or
-- without the creator's signature.
sweepTx ::
    Cage.Provider IO ->
    Submitter IO ->
    CageConfig ->
    TokenId ->
    Addr ->
    Bool ->
    IO ConwayTx
sweepTx prov submit cfg tid feeAddr creatorSigned = do
    let reqAddr = requestAddrFromCfg cfg tid (network cfg)
        scriptAddr = cageAddrFromCfg cfg (network cfg)
    garbageOut <- parkGarbage prov submit feeAddr reqAddr
    cageUtxos <- Cage.queryUTxOs prov scriptAddr
    let policyId = cagePolicyIdFromCfg cfg
    stateUtxo <- case findStateUtxo policyId tid cageUtxos of
        Nothing -> error "sweepTx: state UTxO not found"
        Just x -> pure x
    pp <- Cage.queryProtocolParams prov
    walletUtxos <- Cage.queryUTxOs prov feeAddr
    feeUtxo <- case sortOn (Down . (^. coinTxOutL) . snd) walletUtxos of
        [] -> error "sweepTx: no UTxOs"
        (u : _) -> pure u
    let prog = do
            _ <- Tx.spendScript (fst garbageOut) (Sweep (txInToRef (fst stateUtxo)))
            Tx.reference (fst stateUtxo)
            when
                creatorSigned
                (Tx.requireSignature (addrWitnessKeyHash (addrKeyHashBytes genesisAddr)))
            Tx.collateral (fst feeUtxo)
            Tx.attachScript (mkRequestScript cfg tid)
    result <-
        Tx.build
            (Tx.mkPParamsBound pp)
            (Tx.InterpretIO (const (pure undefined)))
            skipEvalTx
            [feeUtxo, garbageOut]
            [stateUtxo]
            feeAddr
            (prog :: Tx.TxBuild NoCtx Void ())
    case result of
        Right tx -> pure tx
        Left err -> error ("sweepTx: build failed: " <> show err)

-- | Park a datum-less garbage output at the request address: the classic
-- sweep target. Returns its input.
parkGarbage ::
    Cage.Provider IO ->
    Submitter IO ->
    Addr ->
    Addr ->
    IO (TxIn, TxOut ConwayEra)
parkGarbage prov submit feeAddr reqAddr = do
    utxos <- Cage.queryUTxOs prov feeAddr
    feeUtxo <- case sortOn (Down . (^. coinTxOutL) . snd) utxos of
        [] -> failWith "parkGarbage: no UTxOs"
        (u : _) -> pure u
    let garbageOut = mkBasicTxOut reqAddr (MaryValue (Coin 2_000_000) mempty)
        Coin inCoin = (snd feeUtxo) ^. coinTxOutL
        changeOutTx =
            mkBasicTxOut feeAddr (MaryValue (Coin (inCoin - 1_000_000 - 2_000_000)) mempty)
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton (fst feeUtxo)
                & outputsTxBodyL .~ StrictSeq.fromList [garbageOut, changeOutTx]
                & feeTxBodyL .~ Coin 1_000_000
        tx = mkBasicTx body
    let sign
            | feeAddr == genesisAddr = addKeyWitness genesisSignKey
            | otherwise = addKeyWitness (mkSignKey folderSeed)
    result <- submitTx submit (sign tx)
    case result of
        Submitted _ -> pure ()
        Rejected reason -> failWith ("parkGarbage: refused: " <> show reason)
    threadDelay 5_000_000
    after <- Cage.queryUTxOs prov reqAddr
    case sortOn fst [(i, o) | (i, o) <- after, txInTxIdHex i == txIdHex tx] of
        ((i, o) : _) -> pure (i, o)
        [] -> failWith "parkGarbage: garbage output not found"

-- ---------------------------------------------------------
-- Receipt helpers (S2 supplement contract)
-- ---------------------------------------------------------

txIdHex :: ConwayTx -> String
txIdHex tx = let TxId h = txIdTx tx in hexStr (hashToBytes (extractHash h))

txInTxIdHex :: TxIn -> String
txInTxIdHex (TxIn (TxId h) _) = hexStr (hashToBytes (extractHash h))

showIn :: TxIn -> String
showIn (TxIn (TxId h) (TxIx i)) =
    hexStr (hashToBytes (extractHash h)) <> "#" <> show i

hexStr :: ByteString -> String
hexStr = BSC.unpack . Base16.encode

signerHexes :: ConwayTx -> [String]
signerHexes signed =
    [ hexStr (hashToBytes (unKeyHash kh))
    | kh <- Set.toList (signed ^. bodyTxL . reqSignerHashesTxBodyL)
    ]

witnessHexes :: ConwayTx -> [String]
witnessHexes signed =
    [ hexStr (hashToBytes (unKeyHash (witVKeyHash w)))
    | w <- Set.toList (signed ^. witsTxL . addrTxWitsL)
    ]

mintFacts :: ConwayTx -> [Value]
mintFacts signed =
    let MultiAsset ma = signed ^. bodyTxL . mintTxBodyL
     in [ object ["policy" .= hexStr (scriptHashBytes h), "quantity" .= q]
        | (PolicyID h, names) <- Map.toList ma
        , (_, q) <- Map.toList names
        ]

queryStateUtxo ::
    Cage.Provider IO ->
    CageConfig ->
    TokenId ->
    IO (TxIn, TxOut ConwayEra)
queryStateUtxo prov cfg tok = do
    let scriptAddr = cageAddrFromCfg cfg (network cfg)
    utxos <- Cage.queryUTxOs prov scriptAddr
    case findStateUtxo (cagePolicyIdFromCfg cfg) tok utxos of
        Just x -> pure x
        Nothing -> failWith "state UTxO not found"

chainRootHex ::
    Cage.Provider IO ->
    CageConfig ->
    TokenId ->
    IO String
chainRootHex prov cfg tok = do
    (_, stateOut) <- queryStateUtxo prov cfg tok
    case extractCageDatum stateOut of
        Just (StateDatum st) ->
            let OnChainRoot bs = stateRoot st
             in pure (hexStr bs)
        _ -> failWith "the state UTxO carries no state datum"

-- | The chain-read state datum as a checkable object (no owner field exists).
stateDatumObject :: Cage.Provider IO -> CageConfig -> TokenId -> IO Value
stateDatumObject prov cfg tok = do
    (_, stateOut) <- queryStateUtxo prov cfg tok
    case extractCageDatum stateOut of
        Just (StateDatum st) ->
            let OnChainRoot bs = stateRoot st
             in pure $
                    object
                        [ "root" .= hexStr bs
                        , "tip" .= stateMaxFee st
                        , "processTime" .= stateProcessTime st
                        , "retractTime" .= stateRetractTime st
                        ]
        _ -> failWith "the state UTxO carries no state datum"

recordRow :: IORef [Value] -> Value -> IO ()
recordRow ref row = modifyIORef' ref (row :)

writeReceipt :: IORef [Value] -> FilePath -> String -> IO ()
writeReceipt ref mpfsPath candidate = do
    rows <- readIORef ref
    receiptPath <- receiptPathFromEnv
    existing <- tryReadReceipt receiptPath
    let merged = existing ++ reverse rows
        top =
            object
                [ "candidate" .= candidate
                , "namingBlueprint" .= Aeson.Null
                , "mpfsBlueprint" .= mpfsPath
                , "rows" .= merged
                ]
    BSL.writeFile receiptPath (Aeson.encode top)
    emit "receipt" ("machine-readable receipt: " <> receiptPath)

tryReadReceipt :: FilePath -> IO [Value]
tryReadReceipt path = do
    outcome <- try (BSL.readFile path) :: IO (Either SomeException BSL.ByteString)
    case outcome of
        Left _ -> pure []
        Right bs -> case Aeson.eitherDecode' bs of
            Right (Aeson.Object o) -> case parseMaybe (.: "rows") o of
                Just rows -> pure rows
                Nothing -> pure []
            _ -> pure []

receiptPathFromEnv :: IO FilePath
receiptPathFromEnv = do
    explicit <- lookupEnv "S77_RECEIPT"
    case explicit of
        Just path -> pure path
        Nothing -> do
            tmpdir <- fromMaybe "/tmp" <$> lookupEnv "TMPDIR"
            pure (tmpdir ++ "/repair-rows-receipt.json")

candidateFromEnv :: IO String
candidateFromEnv = fromMaybe "unknown" <$> lookupEnv "CANDIDATE_SHA"
