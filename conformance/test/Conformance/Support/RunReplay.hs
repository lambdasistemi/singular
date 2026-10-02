{-# LANGUAGE LambdaCase #-}

{- | The two checks a replay makes before it evaluates anything: the capture
resolves every output the transaction names, and the traced code gets the
deployed application's parameters — shown by the untraced code under them
hashing to the failing hash.
-}
module Conformance.Support.RunReplay (spec) where

import Data.Aeson
    ( Value (..)
    , eitherDecodeFileStrict
    , object
    , toJSON
    , (.=)
    )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Char8 qualified as BSC
import Data.ByteString.Short (ShortByteString)
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.IORef (readIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((&), (.~))
import System.Directory
    ( createDirectoryIfMissing
    , getTemporaryDirectory
    , removePathForcibly
    )
import System.FilePath (takeDirectory, (</>))
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldNotBe
    , shouldReturn
    , shouldSatisfy
    )

import Cardano.Ledger.Api.Tx (mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , feeTxBodyL
    , inputsTxBodyL
    , mkBasicTxBody
    , referenceInputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (TxOut, mkBasicTxOut)
import Cardano.Ledger.BaseTypes (Network (..), TxIx (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import PlutusCore qualified as PLC
import PlutusCore.Data qualified as PLC (Data (..))
import PlutusCore.Evaluation.Error qualified as PLC
    ( EvaluationError (..)
    )
import PlutusCore.Evaluation.ErrorWithCause (ErrorWithCause (..))
import PlutusCore.Evaluation.Machine.ExBudget
    ( ExBudget (..)
    , ExRestrictingBudget (..)
    )
import PlutusCore.Evaluation.Machine.Exception (MachineError (..))
import PlutusLedgerApi.Common (serialiseUPLC)
import PlutusLedgerApi.Common qualified as P
import UntypedPlutusCore qualified as UPLC
import UntypedPlutusCore.Evaluation.Machine.Cek (CekUserError (..))

import Singular.Registry.Blueprint (applyBytesParam, applyDataParam)
import Singular.Registry.Ledger (AssetName (..), TokenId (..))
import Singular.Registry.Trie (TrieManager (..))
import Singular.Registry.Trie qualified as CageTrie
import Singular.Registry.Trie.PureManager (mkPureTrieManager)
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , computeScriptHash
    , leafTerminal
    )

import Conformance.Receipt (Receipt (..), loadReceipts)
import Conformance.Replay
    ( PurposeReplay (..)
    , ReasonComparison (..)
    , ReplayClass (..)
    , ReplayEvidence (..)
    , ReplayRun (..)
    , RunOutcome (..)
    , TracedProvenance (..)
    , UnobservedCause (..)
    , admittedFor
    , stepComparison
    )
import Conformance.Run.Book (keyProof, speculativeStep)
import Conformance.Run.Control
    ( ReasonControl (..)
    , controlledReason
    , parseReasonControl
    )
import Conformance.Run.Replay
import Paths_conformance (getDataFileName)
import Singular.Registry.Types (edgeUpdateTerminal)

-- | A distinct output reference, named by the ledger's own transaction id.
named :: Integer -> TxIn
named n =
    TxIn
        (txIdTx (mkBasicTx (mkBasicTxBody & feeTxBodyL .~ Coin n) :: ConwayTx))
        (TxIx 0)

output :: TxOut ConwayEra
output =
    mkBasicTxOut
        (addrFromKeyHashBytes Testnet (mconcat (replicate 28 "\x21")))
        (MaryValue (Coin 2_000_000) mempty)

spent, referenced, collateral :: TxIn
spent = named 1
referenced = named 2
collateral = named 3

rejected :: ConwayTx
rejected =
    mkBasicTx
        ( mkBasicTxBody
            & inputsTxBodyL .~ Set.fromList [spent]
            & referenceInputsTxBodyL .~ Set.fromList [referenced]
            & collateralInputsTxBodyL .~ Set.fromList [collateral]
        )

resolvedAt :: [TxIn] -> Map.Map TxIn (TxOut ConwayEra)
resolvedAt ins = Map.fromList [(i, output) | i <- ins]

-- | A one-parameter validator: @\\p -> body@, flat-encoded.
program
    :: UPLC.Term UPLC.DeBruijn PLC.DefaultUni PLC.DefaultFun ()
    -> ShortByteString
program body =
    serialiseUPLC
        ( UPLC.Program
            ()
            PLC.latestVersion
            (UPLC.LamAbs () (UPLC.DeBruijn 0) body)
        )

untraced, traced :: ShortByteString
untraced = program (UPLC.Var () (UPLC.DeBruijn 1))
traced =
    program
        ( UPLC.Apply
            ()
            (UPLC.LamAbs () (UPLC.DeBruijn 0) (UPLC.Var () (UPLC.DeBruijn 1)))
            (UPLC.Var () (UPLC.DeBruijn 1))
        )

codes :: Map.Map Text (ShortByteString, ShortByteString)
codes = Map.singleton "request.request" (untraced, traced)

-- | A two-parameter validator: @\\kind registry -> body@, flat-encoded.
program2
    :: UPLC.Term UPLC.DeBruijn PLC.DefaultUni PLC.DefaultFun ()
    -> ShortByteString
program2 body =
    serialiseUPLC
        ( UPLC.Program
            ()
            PLC.latestVersion
            ( UPLC.LamAbs
                ()
                (UPLC.DeBruijn 0)
                (UPLC.LamAbs () (UPLC.DeBruijn 0) body)
            )
        )

witnessUntraced, witnessTraced :: ShortByteString
witnessUntraced = program2 (UPLC.Var () (UPLC.DeBruijn 1))
witnessTraced = program2 (UPLC.Var () (UPLC.DeBruijn 2))

witnessCodes :: Map.Map Text (ShortByteString, ShortByteString)
witnessCodes = Map.singleton "witness.witness" (witnessUntraced, witnessTraced)

application :: String -> DeployedApplication
application token =
    DeployedApplication
        { daTitle = "request.request"
        , daParameters = T.pack token
        , daApply = applyBytesParam (BSC.pack token)
        }

spec :: Spec
spec = describe "before a replay evaluates" $ do
    describe "the capture" $ do
        it "resolving every input, reference input and collateral is complete" $
            checkResolved rejected (resolvedAt [spent, referenced, collateral])
                `shouldBe` Right (resolvedAt [spent, referenced, collateral])
        it "an unresolved reference input makes it capture-incomplete" $
            checkResolved rejected (resolvedAt [spent, collateral])
                `shouldBe` Left CaptureIncomplete
        it "an unresolved spent input makes it capture-incomplete" $
            checkResolved rejected (resolvedAt [referenced, collateral])
                `shouldBe` Left CaptureIncomplete
        it "an unresolved collateral input makes it capture-incomplete" $
            checkResolved rejected (resolvedAt [spent, referenced])
                `shouldBe` Left CaptureIncomplete
    describe "the parameters" $ do
        let failing = computeScriptHash (applyBytesParam "cage-b" untraced)
        it
            "the application reproducing the failing hash gives the traced code"
            $ applyDeployedParameters
                codes
                [application "cage-a", application "cage-b"]
                failing
                `shouldBe` Right
                    AppliedTraced
                        { atTitle = "request.request"
                        , atParameters = "cage-b"
                        , atBytes = applyBytesParam "cage-b" traced
                        , atHash = computeScriptHash (applyBytesParam "cage-b" traced)
                        }
        it "a wrong parameter value is parameters-mismatch" $
            applyDeployedParameters codes [application "cage-a"] failing
                `shouldBe` Left ParametersMismatch
        it "a parameter of the wrong kind is parameters-mismatch" $
            applyDeployedParameters
                codes
                [ DeployedApplication
                    "request.request"
                    "0"
                    (applyDataParam (PLC.I 0))
                ]
                failing
                `shouldBe` Left ParametersMismatch
        it "the traced hash is not the failing hash" $
            fmap
                atHash
                (applyDeployedParameters codes [application "cage-b"] failing)
                `shouldSatisfy` (/= Right failing)
    describe "the witness a registry deployed" $ do
        let active token =
                applyBytesParam ("state-policy" <> token) . applyDataParam (PLC.I 1)
            failing = computeScriptHash (active "cage-b" witnessUntraced)
        it
            "its application under the captured registry and kind reproduces the failing policy"
            $ fmap
                (\a -> (atTitle a, atBytes a))
                ( applyDeployedParameters
                    witnessCodes
                    (witnessApplications "state-policy" ["cage-a", "cage-b"])
                    failing
                )
                `shouldBe` Right ("witness.witness", active "cage-b" witnessTraced)
        it "a registry the capture does not name reproduces nothing" $
            applyDeployedParameters
                witnessCodes
                (witnessApplications "state-policy" ["cage-a"])
                failing
                `shouldBe` Left ParametersMismatch
        it "a kind outside the three is not a candidate" $
            applyDeployedParameters
                witnessCodes
                (witnessApplications "state-policy" ["cage-b"])
                ( computeScriptHash
                    ( applyBytesParam
                        "state-policycage-b"
                        (applyDataParam (PLC.I 3) witnessUntraced)
                    )
                )
                `shouldBe` Left ParametersMismatch
    describe "the proof a fold carries for a key" $ do
        let tid = TokenId (AssetName (SBS.toShort "registry"))
            withControl action = do
                manager <- mkPureTrieManager
                createTrie manager tid
                _ <- withTrie manager tid $ \trie -> CageTrie.insert trie "control" leafTerminal
                action manager
        it
            "a key the trie does not hold gets a non-empty exclusion proof, the trie untouched"
            $ withControl
            $ \manager -> do
                before <- withTrie manager tid CageTrie.getRoot
                proof <-
                    withSpeculativeTrie
                        manager
                        tid
                        (`keyProof` "never-registered")
                after <- withTrie manager tid CageTrie.getRoot
                proof `shouldSatisfy` (not . null)
                after `shouldBe` before
        it "a key the trie holds gets its inclusion proof" $
            withControl $ \manager -> do
                inclusion <-
                    withTrie manager tid (`CageTrie.getProofSteps` "control")
                proof <-
                    withSpeculativeTrie manager tid (`keyProof` "control")
                Just proof `shouldBe` inclusion
    describe "a speculative fold's step for one request" $ do
        let tid = TokenId (AssetName (SBS.toShort "registry"))
            stepOn key = do
                manager <- mkPureTrieManager
                createTrie manager tid
                _ <-
                    withTrie manager tid $ \trie ->
                        CageTrie.insert trie "control" leafTerminal
                withSpeculativeTrie manager tid $ \trie -> do
                    before <- CageTrie.getRoot trie
                    inclusion <- CageTrie.getProofSteps trie key
                    proof <- speculativeStep trie key edgeUpdateTerminal
                    after <- CageTrie.getRoot trie
                    held <- CageTrie.lookup trie key
                    pure (proof, before == after, held, inclusion)
        it
            "retiring a key the trie does not hold carries a non-empty exclusion proof and leaves the trie"
            $ do
                (proof, unchanged, held, _) <- stepOn "never-registered"
                proof `shouldSatisfy` (not . null)
                unchanged `shouldBe` True
                held `shouldBe` Nothing
        it "retiring a key the trie holds still carries its inclusion proof" $ do
            (proof, _, held, inclusion) <- stepOn "control"
            Just proof `shouldBe` inclusion
            held `shouldSatisfy` isJust
    describe "how an evaluation that did not finish ended" $ do
        let cek e = P.CekError (ErrorWithCause e Nothing)
        it "running out of the budget is budget-exhausted" $
            classify
                ( cek
                    ( PLC.OperationalError
                        (CekOutOfExError (ExRestrictingBudget (ExBudget (-1) (-1))))
                    )
                )
                `shouldBe` BudgetExhausted
        it "a script's error call is a validator failure" $
            classify (cek (PLC.OperationalError CekEvaluationFailure))
                `shouldBe` ValidatorFailure
        it "a failed case over a builtin is a validator failure" $
            classify (cek (PLC.OperationalError (CekCaseBuiltinError "case")))
                `shouldBe` ValidatorFailure
        it "a non-unit result is a validator failure" $
            classify P.InvalidReturnValue `shouldBe` ValidatorFailure
        it "a malformed program is the evaluator's error, not the validator's" $
            classify (cek (PLC.StructuralError OpenTermEvaluatedMachineError))
                `shouldSatisfy` isEvaluationError
        it "a cost model the evaluator cannot use is the evaluator's error" $
            classify P.CostModelParameterMismatch
                `shouldSatisfy` isEvaluationError
    describe "the replay index a refused step's comparison is written to"
        $ it
            "a differing step leaves its entry with Lean's reason and the comparison"
        $ do
            dir <- (</> "conformance-replay-index-spec") <$> getTemporaryDirectory
            removePathForcibly dir
            index <- newReplayIndex dir
            let entry txid =
                    object
                        [ "rejectedTxId" .= (txid :: Text)
                        , "modelReason" .= Null
                        , "comparison" .= Null
                        , "extentClass" .= ("unclassified" :: Text)
                        ]
            addRejection
                index
                "tx-other"
                (entry "tx-other")
                [("m", Admitted "deposit-returned")]
                []
            addRejection
                index
                "tx-step"
                (entry "tx-step")
                [("m", Admitted "retract-owner")]
                []
            recordComparison
                index
                "tx-step"
                "not-phase2"
                (Differs "retract-owner" "not-phase2")
            written <- eitherDecodeFileStrict (dir </> "replay" </> "index.json")
            let fieldOf txid name = case written of
                    Right entries ->
                        [ KM.lookup name o
                        | Object o <- entries
                        , KM.lookup "rejectedTxId" o == Just (String txid)
                        ]
                    Left _ -> []
            fieldOf "tx-step" "comparison" `shouldBe` [Just (String "differs")]
            fieldOf "tx-step" "modelReason"
                `shouldBe` [Just (String "not-phase2")]
            fieldOf "tx-step" "extentClass" `shouldBe` [Just (String "A")]
            fieldOf "tx-other" "comparison" `shouldBe` [Just Null]
    describe "the replay evidence a refused step's receipt carries" $
        it "is kept by rejection, for the receipt of the step that refused" $
            do
                dir <-
                    (</> "conformance-replay-evidence-spec") <$> getTemporaryDirectory
                removePathForcibly dir
                index <- newReplayIndex dir
                let evidence reason =
                        [ ReplayEvidence
                            { replayDeployedHash = "m"
                            , replayTracedHash = Just "t"
                            , replayReason = Just reason
                            , replayCause = Nothing
                            , replayCaptureId = Just "c"
                            }
                        ]
                addRejection
                    index
                    "tx-one"
                    (object ["rejectedTxId" .= ("tx-one" :: Text)])
                    [("m", Admitted "key-exists")]
                    (evidence "key-exists")
                addRejection
                    index
                    "tx-two"
                    (object ["rejectedTxId" .= ("tx-two" :: Text)])
                    [("m", Admitted "not-booked")]
                    (evidence "not-booked")
                replayEvidenceOf index "tx-one" `shouldReturn` evidence "key-exists"
                replayEvidenceOf index "tx-two" `shouldReturn` evidence "not-booked"
                replayEvidenceOf index "tx-none" `shouldReturn` []
    describe "a receipts directory two sessions share"
        $ it
            "keeps the first session's replay entries when the second writes its own"
        $ do
            dir <-
                (</> "conformance-replay-shared-spec") <$> getTemporaryDirectory
            removePathForcibly dir
            first <- newReplayIndex dir
            addEntry first (object ["rejectedTxId" .= ("tx-first" :: Text)])
            second <- newReplayIndex dir
            addEntry second (object ["rejectedTxId" .= ("tx-second" :: Text)])
            written <- eitherDecodeFileStrict (dir </> "replay" </> "index.json")
            fmap
                (map (\case Object o -> KM.lookup "rejectedTxId" o; _ -> Nothing))
                (written :: Either String [Value])
                `shouldBe` Right [Just (String "tx-first"), Just (String "tx-second")]
    describe "the offline compiler diagnostic of a capsule" $ do
        it
            "is refused for a blueprint that does not correspond or traces only user lines"
            $ do
                diagnosticSetupProblem (Left ToolchainMismatch) `shouldSatisfy` isJust
                diagnosticSetupProblem (Right (diagnosticBuild userDefinedFlags))
                    `shouldSatisfy` isJust
                diagnosticSetupProblem (Right (diagnosticBuild allFlags))
                    `shouldBe` Nothing
        it
            "evaluates only the purposes the user-defined replay left without a user trace"
            $ fmap
                (map (prDeployedHash . fst))
                (diagnosedPurposes userDefinedCS04 (diagnosticCS04 Nothing))
                `shouldBe` Right ["state", "request"]
        it
            "is refused when the diagnostic code could not be applied with the deployed parameters"
            $ diagnosedPurposes
                userDefinedCS04
                (diagnosticCS04 (Just ("request", Unobserved ParametersMismatch)))
                `shouldSatisfy` isLeftE
        it
            "is refused when the deployed bytes no longer reproduce the refusal"
            $ diagnosedPurposes
                userDefinedCS04
                ( map
                    (\p -> p{prDeployed = Just (run Succeeded [])})
                    (diagnosticCS04 Nothing)
                )
                `shouldSatisfy` isLeftE
        it "names each way a diagnostic run ends, and none is a reason" $
            map
                diagnosticCategory
                [ run Succeeded []
                , run BudgetExhausted []
                , run (EvaluationError "no machine") []
                , run ValidatorFailure []
                , run ValidatorFailure ["", "  "]
                , run ValidatorFailure ["expect Some(x) = datum"]
                ]
                `shouldBe` [ "succeeded"
                           , "budget-exhausted"
                           , "evaluation-error"
                           , "silent"
                           , "silent"
                           , "logged"
                           ]
        it "writes compiler diagnostics with their logs, never a reason" $ do
            let outcome = case diagnosedPurposes userDefinedCS04 (diagnosticCS04 Nothing) of
                    Right pairs ->
                        diagnosticOutcome "txid" "capture" (diagnosticBuild allFlags) pairs
                    Left _ -> Null
            textAt ["kind"] outcome `shouldBe` Just "compiler-diagnostic"
            map (textAt ["outcome"]) (purposesAt outcome)
                `shouldBe` [Just "logged", Just "silent"]
            map (textAt ["diagnosticHash"]) (purposesAt outcome)
                `shouldBe` [Just "diagnostic-state", Just "diagnostic-request"]
            map (lookupPath ["logs"]) (purposesAt outcome)
                `shouldBe` [ Just (toJSON ["expect Some(x) = datum" :: Text])
                           , Just (toJSON ([] :: [Text]))
                           ]
            keysOf outcome
                `shouldSatisfy` (\ks -> "reason" `notElem` ks && "admitted" `notElem` ks)
    describe
        "the offline compiler diagnostic beside the evidence it follows"
        $ do
            it "is written beside the offline outcome, which stays byte-identical" $ do
                dir <- freshDiagnosticDir "conformance-diagnostic-offline-spec"
                let offline = dir </> "replay-offline" </> "tx-cs04" </> "outcome.json"
                    original = "{\"purposes\":[],\"classes\":[]}"
                createDirectoryIfMissing True (takeDirectory offline)
                BSC.writeFile offline original
                diagnose dir
                BSC.readFile offline `shouldReturn` original
                written <-
                    eitherDecodeFileStrict
                        (dir </> "replay-diagnostic" </> "tx-cs04" </> "outcome.json")
                fmap (textAt ["kind"]) written
                    `shouldBe` Right (Just "compiler-diagnostic")
            it
                "is read by none of the index, admission, comparison or receipt loading"
                $ do
                    dir <- freshDiagnosticDir "conformance-diagnostic-readers-spec"
                    let refusal =
                            object
                                [ "kind" .= ("refusal" :: Text)
                                , "rejectedTxId" .= ("tx-cs04" :: Text)
                                , "row" .= ("CS04" :: Text)
                                ]
                    session <- newReplayIndex dir
                    addRejection
                        session
                        "tx-cs04"
                        refusal
                        [("state", Unobserved NoUserTrace)]
                        []
                    receipt <- getDataFileName "test/fixtures/receipts/receipt-CG05.json"
                    BSC.readFile receipt >>= BSC.writeFile (dir </> "receipt-CG05.json")
                    diagnose dir
                    reread <- newReplayIndex dir
                    readIORef (riEntries reread) `shouldReturn` [refusal]
                    purposes <- purposesOf reread "tx-cs04"
                    purposes `shouldBe` []
                    admittedFor "state" purposes `shouldBe` Nothing
                    stepComparison "state" "key-exists" purposes
                        `shouldBe` Uncompared ContextUnavailable
                    fmap (map receiptRow) <$> loadReceipts dir
                        `shouldReturn` Right ["CG05"]
    describe "the wrong-reason control" $ do
        let control = ReasonControl "CG07" 0 "retract-owner"
        it "reads ROW:STEP:REASON" $
            parseReasonControl "CG07:0:retract-owner" `shouldBe` Right control
        it "refuses a control it cannot read" $ do
            parseReasonControl "CG07:first:retract-owner" `shouldSatisfy` isLeftE
            parseReasonControl "CG07:0" `shouldSatisfy` isLeftE
            parseReasonControl "CG07:0:" `shouldSatisfy` isLeftE
        it "the altered step cannot compare agrees" $
            stepComparison
                "m"
                (controlledReason (Just control) "CG07" 0 "not-phase2")
                [("m", Admitted "not-phase2")]
                `shouldNotBe` Agrees
        it "every other step, and the run without the control, is untouched" $ do
            controlledReason (Just control) "CG07" 2 "not-phase2"
                `shouldBe` "not-phase2"
            controlledReason (Just control) "CG22" 0 "not-booked"
                `shouldBe` "not-booked"
            controlledReason Nothing "CG07" 0 "not-phase2" `shouldBe` "not-phase2"
  where
    isEvaluationError = \case
        EvaluationError _ -> True
        _ -> False
    isLeftE :: Either String a -> Bool
    isLeftE = either (const True) (const False)

-- | A diagnostic build's provenance, with the given trace flags.
diagnosticBuild :: Text -> TracedProvenance
diagnosticBuild flags =
    TracedProvenance
        { tpSource = "/nix/store/source"
        , tpCompiler = "v1.1.21"
        , tpFlags = flags
        , tpUntracedHashes = Map.fromList [("state.state.spend", "state")]
        }

allFlags, userDefinedFlags :: Text
allFlags = "--trace-filter all --trace-level verbose"
userDefinedFlags = "--trace-filter user-defined --trace-level verbose"

-- | An evaluation that ended as given, with these log lines.
run :: RunOutcome -> [Text] -> ReplayRun
run outcome logs =
    ReplayRun
        { runBytesHash = "bytes"
        , runBudgetLimit = (100, 100)
        , runBudgetUsed = Nothing
        , runOutcome = outcome
        , runLogs = logs
        }

-- | CS04's user-defined replay: the witness admitted, state and request silent.
userDefinedCS04 :: [PurposeReplay]
userDefinedCS04 =
    [ purpose "mint 0" "witness" (Admitted "no-fold") ["no-fold"]
    , purpose "spend 2" "state" (Unobserved NoUserTrace) []
    , purpose "spend 0" "request" (Unobserved NoUserTrace) []
    ]
  where
    purpose name hash cls logs =
        PurposeReplay
            { prPurpose = name
            , prDeployedHash = hash
            , prTracedHash = Just ("traced-" <> hash)
            , prDeployed = Just (run ValidatorFailure [])
            , prTraced = Just (run ValidatorFailure logs)
            , prClass = cls
            }

{- | The same capsule replayed with the diagnostic build: the state script
logs one compiler trace, the request script none; one purpose may instead be
given the cause its diagnostic application ended with.
-}
diagnosticCS04 :: Maybe (Text, ReplayClass) -> [PurposeReplay]
diagnosticCS04 failed =
    [ applied "mint 0" "witness" ["no-fold"]
    , applied "spend 2" "state" ["expect Some(x) = datum"]
    , applied "spend 0" "request" []
    ]
  where
    applied name hash logs = case failed of
        Just (failing, cls)
            | failing == hash ->
                PurposeReplay name hash Nothing Nothing Nothing cls
        _ ->
            PurposeReplay
                { prPurpose = name
                , prDeployedHash = hash
                , prTracedHash = Just ("diagnostic-" <> hash)
                , prDeployed = Just (run ValidatorFailure [])
                , prTraced = Just (run ValidatorFailure logs)
                , prClass = Unobserved NoUserTrace
                }

lookupPath :: [Text] -> Value -> Maybe Value
lookupPath [] value = Just value
lookupPath (name : rest) (Object o) = lookupPath rest =<< KM.lookup (Key.fromText name) o
lookupPath _ _ = Nothing

textAt :: [Text] -> Value -> Maybe Text
textAt path value = case lookupPath path value of
    Just (String t) -> Just t
    _ -> Nothing

purposesAt :: Value -> [Value]
purposesAt value = case lookupPath ["purposes"] value of
    Just (Array items) -> toList items
    _ -> []

-- | Every key at any depth.
keysOf :: Value -> [Text]
keysOf = \case
    Object o -> concat [Key.toText k : keysOf v | (k, v) <- KM.toList o]
    Array items -> concatMap keysOf items
    _ -> []

-- | An empty receipts directory under the temporary directory.
freshDiagnosticDir :: FilePath -> IO FilePath
freshDiagnosticDir name = do
    dir <- (</> name) <$> getTemporaryDirectory
    removePathForcibly dir
    createDirectoryIfMissing True (dir </> "replay" </> "tx-cs04")
    pure dir

-- | The diagnostic write path, run on CS04's replays in a receipts directory.
diagnose :: FilePath -> IO ()
diagnose dir =
    writeDiagnostic
        ["replay-capsule"]
        dir
        (dir </> "replay" </> "tx-cs04")
        "capture"
        "tx-cs04"
        "deployed.json"
        "diagnostic.json"
        userDefinedCS04
        ( Right
            ReplaySetup
                { rsProvenance = diagnosticBuild allFlags
                , rsCodes = Map.empty
                , rsStatePolicy = ""
                , rsUnrouted = []
                }
        )
        (const (pure (diagnosticCS04 Nothing)))
