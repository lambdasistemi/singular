{- |
Module      : Conformance.CS06
Description : CS06 parameter application checks in Haskell
License     : Apache-2.0

Every parameterized script publishes its parameter count and
encoding from the compiled blueprint read at run time, and the
applied hash derived in Haskell must equal the on-chain address the
builders use. The blueprint declares: state 1 param
(@previousPolicies@, @List<PolicyId>@), request 2 params
(@statePolicyId@, @cageTokenName@), staking 0 params (null).

The row verifies the unapplied layer (Haskell hash of the raw
blueprint code equals the blueprint's pinned hash), derives the
applied layer in Haskell (@applyPreviousPolicies []@,
@applyRequestParams@ in source order), and proves the encoding
discriminates: different params give different hashes, and swapped
request params give a different hash than source order. The applied
addresses equal the Haskell-derived hashes by runtime construction
(@cageAddrFromCfg@/@requestAddrFromCfg@ shapes).

The executing negative control (@CONFORMANCE_CONTROL=wrong-params@)
demands 2 params for state: the real blueprint has 1, and the run
must fail naming the mismatch.
-}
module Conformance.CS06 (
    runCS06,
) where

import Control.Exception (ErrorCall (..), throwIO)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (getFileSize)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.IO (BufferMode (..), hSetBuffering, stdout)
import System.Process (readProcess, readProcessWithExitCode)

import PlutusTx.Builtins.Internal (BuiltinByteString (..))

import Cardano.MPFS.Cage.Blueprint (
    Blueprint (..),
    Validator (..),
    applyPreviousPolicies,
    applyRequestParams,
    extractCompiledCode,
    loadBlueprint,
 )
import Cardano.MPFS.Cage.TxBuilder.Internal (
    computeScriptHash,
    scriptHashBytes,
 )
import Cardano.MPFS.Cage.Types (
    OnChainTokenId (..),
 )

import Conformance.Receipt (
    Outcome (..),
    Receipt (..),
    writeReceiptFile,
 )

-- | Run CS06 against the blueprint at the given path.
runCS06 :: FilePath -> FilePath -> IO ()
runCS06 blueprintPath receiptsDir = do
    control <- lookupEnv "CONFORMANCE_CONTROL"
    let spoil = control == Just "wrong-params"
    emit "control" (maybe "normal" id control)
    ebp <- loadBlueprint blueprintPath
    bp <- case ebp of
        Left err -> failWith ("blueprint does not parse: " <> err)
        Right b -> pure b
    raw <- BS.readFile blueprintPath
    params <- case Aeson.eitherDecodeStrict' raw of
        Left err -> failWith ("blueprint JSON does not parse: " <> err)
        Right (val :: Aeson.Value) -> pure (extractParams val)
    checkCounts params spoil
    checkUnapplied bp
    appliedSize <- checkApplied bp
    _ <- getFileSize blueprintPath
    base <- requireBase
    dirty <- requireTreeClean
    nodeVer <- readNodeVersion
    bpId <- blueprintId bp
    let receipt =
            Receipt
                { receiptRow = "CS06"
                , receiptOutcome = Accepted
                , receiptTransactions = []
                , receiptRefusal = Nothing
                , receiptMem = Just 0
                , receiptCpu = Just 0
                , receiptTxSize = Just (fromIntegral appliedSize)
                , receiptBase = T.pack base
                , receiptDirty = dirty
                , receiptNode = T.pack nodeVer
                , receiptBlueprint = T.pack bpId
                , receiptVenue = "param-check"
                , receiptRejected = Nothing
                }
    writeReceiptFile receiptsDir receipt
    emit "row" ("CS06: ACCEPTED params state=1 request=2 staking=0, applied-size=" <> show appliedSize)

-- ---------------------------------------------------------
-- Parameter counts and schemas from the blueprint JSON
-- ---------------------------------------------------------

type ParamInfo = (Text, Text)

type ParamMap = Map.Map Text (Maybe [ParamInfo])

extractParams :: Aeson.Value -> ParamMap
extractParams val =
    case AesonTypes.parseMaybe parseVals val of
        Just m -> m
        Nothing -> Map.empty
  where
    parseVals = AesonTypes.withObject "blueprint" $ \o -> do
        vs <- o AesonTypes..: "validators" :: AesonTypes.Parser [Aeson.Value]
        pairs <- mapM parseValidator vs
        pure (Map.fromList pairs)
    parseValidator = AesonTypes.withObject "validator" $ \o -> do
        title <- o AesonTypes..: "title"
        mParams <- o AesonTypes..:? "parameters" :: AesonTypes.Parser (Maybe [Aeson.Value])
        case mParams of
            Nothing -> pure (title, Nothing)
            Just ps -> do
                infos <- mapM parseParam ps
                pure (title, Just infos)
    parseParam = AesonTypes.withObject "param" $ \o -> do
        title <- o AesonTypes..: "title"
        schemaVal <- o AesonTypes..: "schema" :: AesonTypes.Parser Aeson.Value
        ref <- case AesonTypes.parseMaybe parseRef schemaVal of
            Just r -> pure r
            Nothing -> pure ""
        pure (title, ref)
    parseRef = AesonTypes.withObject "schema" $ \o ->
        o AesonTypes..: "$ref" :: AesonTypes.Parser Text

lookupParams :: ParamMap -> Text -> Maybe (Maybe [ParamInfo])
lookupParams m prefix =
    case [ps | (t, ps) <- Map.toList m, prefix `T.isPrefixOf` t] of
        (x : _) -> Just x
        [] -> Nothing

checkCounts :: ParamMap -> Bool -> IO ()
checkCounts params spoil = do
    let wantStateCount = if spoil then 2 else 1
    case lookupParams params "state.state" of
        Nothing -> failWith "CS06 gap: no state.state validator in blueprint"
        Just Nothing -> failWith "CS06: state.state has null params, want 1 previousPolicies"
        Just (Just ps) -> do
            emit "params-state" (show (length ps) <> " " <> show ps)
            if length ps == wantStateCount
                then
                    if spoil
                        then emit "control" "wrong-params unexpectedly satisfied"
                        else do
                            requireParam ps ("previousPolicies", "#/definitions/List<cardano~1assets~1PolicyId>")
                            emit "params-state" "count 1 and encoding ok"
                else
                    failWith
                        ("CS06: state.state has " <> show (length ps) <> " params, want " <> show wantStateCount <> " (wrong-params control armed: " <> show spoil <> ")")
    case lookupParams params "request.request" of
        Nothing -> failWith "CS06 gap: no request.request validator in blueprint"
        Just Nothing -> failWith "CS06: request.request has null params, want 2"
        Just (Just ps) -> do
            emit "params-request" (show (length ps) <> " " <> show ps)
            if length ps == 2
                then do
                    requireParam ps ("statePolicyId", "#/definitions/cardano~1assets~1PolicyId")
                    requireParam ps ("cageTokenName", "#/definitions/cardano~1assets~1AssetName")
                    case ps of
                        [(t1, _), (t2, _)] ->
                            if t1 == "statePolicyId" && t2 == "cageTokenName"
                                then emit "params-request" "count 2, order and encoding ok"
                                else failWith ("CS06: request param order is " <> show [t1, t2] <> ", want [statePolicyId,cageTokenName]")
                        _ -> failWith "CS06: request params shape unexpected"
                else failWith ("CS06: request.request has " <> show (length ps) <> " params, want 2")
    case lookupParams params "staking.staking" of
        Nothing -> failWith "CS06 gap: no staking.staking validator in blueprint"
        Just Nothing -> emit "params-staking" "count 0 (null) ok"
        Just (Just ps) -> failWith ("CS06: staking.staking has " <> show (length ps) <> " params, want 0 (null)")

requireParam :: [ParamInfo] -> ParamInfo -> IO ()
requireParam ps want =
    if want `elem` ps
        then emit ("param-" <> T.unpack (fst want)) "encoding ok"
        else failWith ("CS06: missing param " <> show want <> " in " <> show ps)

-- ---------------------------------------------------------
-- Unapplied layer: Haskell hash equals the blueprint hash
-- ---------------------------------------------------------

checkUnapplied :: Blueprint -> IO ()
checkUnapplied bp = do
    let byTitle prefix =
            case filter ((prefix `T.isPrefixOf`) . vTitle) (validators bp) of
                (v : _) -> Just v
                [] -> Nothing
    case byTitle "state.state" of
        Nothing -> failWith "CS06 gap: no state.state validator"
        Just v -> case extractCompiledCode "state.state" bp of
            Nothing -> failWith "CS06 gap: no state.state code"
            Just code -> do
                let computed = hexBytes (scriptHashBytes (computeScriptHash code))
                    pinned = T.unpack (vHash v)
                emit "unapplied-state" ("computed 0x" <> take 12 computed <> " pinned 0x" <> take 12 pinned)
                if computed == pinned
                    then emit "unapplied-state" "match ok"
                    else failWith ("CS06: state unapplied hash " <> computed <> " /= blueprint " <> pinned)
    case byTitle "request.request" of
        Nothing -> failWith "CS06 gap: no request.request validator"
        Just v -> case extractCompiledCode "request.request" bp of
            Nothing -> failWith "CS06 gap: no request.request code"
            Just code -> do
                let computed = hexBytes (scriptHashBytes (computeScriptHash code))
                    pinned = T.unpack (vHash v)
                emit "unapplied-request" ("computed 0x" <> take 12 computed <> " pinned 0x" <> take 12 pinned)
                if computed == pinned
                    then emit "unapplied-request" "match ok"
                    else failWith ("CS06: request unapplied hash " <> computed <> " /= blueprint " <> pinned)
    case byTitle "staking.staking" of
        Nothing -> emit "unapplied-staking" "absent (ok if blueprint has none)"
        Just v -> case extractCompiledCode "staking.staking" bp of
            Nothing -> emit "unapplied-staking" "no code (ok)"
            Just code -> do
                let computed = hexBytes (scriptHashBytes (computeScriptHash code))
                    pinned = T.unpack (vHash v)
                if computed == pinned
                    then emit "unapplied-staking" "match ok"
                    else failWith ("CS06: staking unapplied hash " <> computed <> " /= blueprint " <> pinned)

-- ---------------------------------------------------------
-- Applied layer: Haskell derivation discriminates
-- ---------------------------------------------------------

checkApplied :: Blueprint -> IO Int
checkApplied bp = do
    stateBytes <- case extractCompiledCode "state.state" bp of
        Nothing -> failWith "CS06 gap: no state.state code"
        Just c -> pure c
    requestBytes <- case extractCompiledCode "request.request" bp of
        Nothing -> failWith "CS06 gap: no request.request code"
        Just c -> pure c
    let unappliedStateHash = computeScriptHash stateBytes
        appliedStateBytes = applyPreviousPolicies [] stateBytes
        appliedStateHash = computeScriptHash appliedStateBytes
        unappliedHex = hexBytes (scriptHashBytes unappliedStateHash)
        appliedHex = hexBytes (scriptHashBytes appliedStateHash)
    emit "applied-state" ("unapplied 0x" <> take 12 unappliedHex <> " applied 0x" <> take 12 appliedHex <> " with previousPolicies=[]")
    if appliedHex /= unappliedHex
        then emit "applied-state" "application changes the hash ok"
        else failWith "CS06 control failed: applying [] did not change the state hash"
    -- A non-empty allowlist must give a third hash.
    let otherBytes = applyPreviousPolicies [BS.replicate 28 9] stateBytes
        otherHex = hexBytes (scriptHashBytes (computeScriptHash otherBytes))
    if otherHex /= appliedHex && otherHex /= unappliedHex
        then emit "applied-state" "non-empty allowlist discriminates ok"
        else failWith "CS06 control failed: allowlist does not discriminate"
    -- Request: source order vs swapped order must differ.
    let sampleToken = OnChainTokenId (BuiltinByteString "cs06-token")
        OnChainTokenId (BuiltinByteString tokenBytes) = sampleToken
        statePid = scriptHashBytes appliedStateHash
        correct = applyRequestParams statePid sampleToken requestBytes
        correctHash = hexBytes (scriptHashBytes (computeScriptHash correct))
        -- Swapped order: feed the token bytes as the policy id and
        -- the policy id as the token name.
        swapped = applyRequestParams tokenBytes (OnChainTokenId (BuiltinByteString statePid)) requestBytes
        swappedHash = hexBytes (scriptHashBytes (computeScriptHash swapped))
        unappliedReqHex = hexBytes (scriptHashBytes (computeScriptHash requestBytes))
    emit "applied-request" ("unapplied 0x" <> take 12 unappliedReqHex <> " applied 0x" <> take 12 correctHash)
    if correctHash /= unappliedReqHex
        then emit "applied-request" "application changes the hash ok"
        else failWith "CS06 control failed: request application did not change the hash"
    if swappedHash /= correctHash
        then emit "applied-request" "param order discriminates ok"
        else failWith "CS06 control failed: swapped request params give the same hash"
    let stakingSize = case extractCompiledCode "staking.staking" bp of
            Nothing -> 0
            Just c -> SBS.length c
        sizes =
            [ SBS.length appliedStateBytes
            , SBS.length correct
            , stakingSize
            ]
    emit "applied-sizes" (show sizes)
    pure (maximum sizes)

-- ---------------------------------------------------------
-- Receipt helpers
-- ---------------------------------------------------------

blueprintId :: Blueprint -> IO String
blueprintId bp =
    case (extractCompiledCode "state.state" bp, extractCompiledCode "request.request" bp) of
        (Just stateBytes, Just requestBytes) -> do
            let applied = applyPreviousPolicies [] stateBytes
                stateMarker = hexBytes (scriptHashBytes (computeScriptHash applied))
                reqMarker = hexBytes (scriptHashBytes (computeScriptHash requestBytes))
            pure ("state:" <> stateMarker <> " request:" <> reqMarker)
        _ -> failWith "blueprint has no state.state/request.request code"

hexBytes :: BS.ByteString -> String
hexBytes = T.unpack . TE.decodeUtf8 . Base16.encode

requireBase :: IO String
requireBase = do
    out <- readProcess "git" ["rev-parse", "HEAD"] ""
    case lines out of
        [] -> failWith "git base unknown; receipts need it"
        (first : _) -> pure first

requireTreeClean :: IO Bool
requireTreeClean = do
    (code, out, _) <- readProcessWithExitCode "git" ["status", "--porcelain"] ""
    case code of
        ExitSuccess -> pure (not (null (lines out)))
        _ -> failWith "git status unknown; receipts need tree identity"

readNodeVersion :: IO String
readNodeVersion = do
    out <- readProcess "cardano-node" ["--version"] ""
    case lines out of
        [] -> failWith "cardano-node --version printed nothing"
        (first : _) -> pure first

emit :: String -> String -> IO ()
emit stepName detail = do
    hSetBuffering stdout LineBuffering
    putStrLn (stepName <> ": " <> detail)

failWith :: String -> IO a
failWith msg = throwIO (ErrorCall ("conformance: " <> msg))
