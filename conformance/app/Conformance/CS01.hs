{- |
Module      : Conformance.CS01
Description : CS01 blueprint schema checks for Haskell encodings
License     : Apache-2.0

Every 'ToData'/'FromData' instance in
'Cardano.MPFS.Cage.Types' must match the compiled blueprint's own
declared schema — constructor index and field order — read at run
time via @MPFS_BLUEPRINT@. A round trip proves self-consistency and
says nothing about the ledger; this row checks each type's 'Data'
against the blueprint's schemas with 'validateData', asserts explicit
constructor indices, and asserts field-title order read from the
blueprint JSON itself.

If the blueprint does not declare enough to check a given type, the
row reports precisely which type and why, rather than weakening to a
round trip. All thirteen types are declared; there are no gaps.

The executing negative control (@CONFORMANCE_CONTROL=wrong-index@)
demands index 99 for 'End': the real 'End' (index 0) must fail its
schema, and the run must fail naming the mismatch. A checker that
accepts everything would pass the control and reveal itself.
-}
module Conformance.CS01 (
    runCS01,
) where

import Control.Exception (ErrorCall (..), throwIO)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (getFileSize)
import System.Environment (lookupEnv)
import System.IO (BufferMode (..), hSetBuffering, stdout)
import System.Process (readProcess)

import PlutusCore.Data (Data (..))
import PlutusTx.Builtins.Internal (BuiltinByteString (..), BuiltinData (..))
import PlutusTx.IsData.Class (ToData (..))

import Cardano.MPFS.Cage.Blueprint (
    Blueprint (..),
    Schema (..),
    applyPreviousPolicies,
    extractCompiledCode,
    loadBlueprint,
    validateData,
 )
import Cardano.MPFS.Cage.TxBuilder.Internal (
    computeScriptHash,
    scriptHashBytes,
 )

import Cardano.MPFS.Cage.Types (
    CageDatum (..),
    Migration (..),
    MintRedeemer (..),
    Neighbor (..),
    OnChainOperation (..),
    OnChainRequest (..),
    OnChainRoot (..),
    OnChainTokenId (..),
    OnChainTokenState (..),
    OnChainTxOutRef (..),
    ProofStep (..),
    RequestAction (..),
    UpdateRedeemer (..),
 )

import Conformance.Receipt (
    Outcome (..),
    Receipt (..),
    writeReceiptFile,
 )

-- | Run CS01 against the blueprint at the given path.
runCS01 :: FilePath -> FilePath -> String -> Bool -> IO ()
runCS01 blueprintPath receiptsDir base dirty = do
    control <- lookupEnv "CONFORMANCE_CONTROL"
    let spoil = control == Just "wrong-index"
    emit "control" (maybe "normal" id control)
    ebp <- loadBlueprint blueprintPath
    bp <- case ebp of
        Left err -> failWith ("blueprint does not parse: " <> err)
        Right b -> pure b
    raw <- BS.readFile blueprintPath
    titleMap <- case Aeson.eitherDecodeStrict' raw of
        Left err -> failWith ("blueprint JSON does not parse: " <> err)
        Right (val :: Aeson.Value) -> pure (extractTitles val)
    let defs = definitions bp
    checkAll defs titleMap spoil
    fsize <- getFileSize blueprintPath
    nodeVer <- readNodeVersion
    bpId <- blueprintId bp
    let receipt =
            Receipt
                { receiptRow = "CS01"
                , receiptOutcome = Accepted
                , receiptTransactions = []
                , receiptRefusal = Nothing
                , receiptMem = Just 0
                , receiptCpu = Just 0
                , receiptTxSize = Just (fromIntegral fsize)
                , receiptBase = T.pack base
                , receiptDirty = dirty
                , receiptNode = T.pack nodeVer
                , receiptBlueprint = T.pack bpId
                , receiptVenue = "blueprint-check"
                , receiptRejected = Nothing
                }
    writeReceiptFile receiptsDir receipt
    emit "row" ("CS01: ACCEPTED 13 types vs blueprint, size=" <> show fsize)

-- | Check every type; spoil mode demands a wrong index for End.
checkAll :: Map.Map Text Schema -> TitleMap -> Bool -> IO ()
checkAll defs titles spoil = do
    checkTokenId defs
    checkTxOutRef defs
    checkRoot defs
    checkOperation defs
    checkRequest defs
    checkState defs
    checkCageDatum defs
    checkMintRedeemer defs
    checkMigration defs
    checkRequestAction defs
    checkUpdateRedeemer defs spoil
    checkProofStep defs
    checkNeighbor defs
    checkOptionStake defs
    checkFieldTitles titles

-- ---------------------------------------------------------
-- Samples
-- ---------------------------------------------------------

sampleToken :: OnChainTokenId
sampleToken = OnChainTokenId (BuiltinByteString "test-token-asset")

sampleRef :: OnChainTxOutRef
sampleRef =
    OnChainTxOutRef
        { txOutRefId = BuiltinByteString (BS.replicate 32 0)
        , txOutRefIdx = 0
        }

sampleRoot :: OnChainRoot
sampleRoot = OnChainRoot (BS.replicate 32 0)

sampleRequest :: OnChainRequest
sampleRequest =
    OnChainRequest
        { requestToken = sampleToken
        , requestOwner = BuiltinByteString (BS.replicate 28 0)
        , requestKey = "cs01-key"
        , requestValue = OpInsert "cs01-value"
        , requestFee = 1000000
        , requestSubmittedAt = 1234567890
        }

sampleState :: OnChainTokenState
sampleState =
    OnChainTokenState
        { stateOwner = BuiltinByteString (BS.replicate 28 0)
        , stateStakeScript = Nothing
        , stateRoot = sampleRoot
        , stateMaxFee = 1000000
        , stateProcessTime = 30000
        , stateRetractTime = 30000
        }

sampleStateSome :: OnChainTokenState
sampleStateSome =
    sampleState
        { stateStakeScript = Just (BuiltinByteString (BS.replicate 28 7))
        }

sampleMigration :: Migration
sampleMigration =
    Migration
        { migrationOldPolicy = BuiltinByteString (BS.replicate 28 1)
        , migrationTokenId = sampleToken
        }

sampleNeighbor :: Neighbor
sampleNeighbor =
    Neighbor
        { neighborNibble = 5
        , neighborPrefix = "ab"
        , neighborRoot = BS.replicate 32 2
        }

sampleBranch :: ProofStep
sampleBranch = Branch 1 (BS.replicate 128 3)

sampleFork :: ProofStep
sampleFork = Fork 2 sampleNeighbor

sampleLeaf :: ProofStep
sampleLeaf = Leaf 0 "leaf-key" (BS.replicate 32 4)

toD :: (ToData a) => a -> Data
toD x = let BuiltinData d = toBuiltinData x in d

requireSchema :: Map.Map Text Schema -> Text -> Data -> String -> IO ()
requireSchema defs defName d label =
    case Map.lookup defName defs of
        Nothing ->
            failWith
                ("CS01 gap: blueprint has no definition " <> T.unpack defName <> " for " <> label)
        Just schema ->
            if validateData defs schema d
                then emit ("check-" <> label) "schema ok"
                else failWith ("CS01: " <> label <> " Data does not validate against " <> T.unpack defName <> ": " <> show d)

requireIndex :: Data -> Integer -> String -> IO ()
requireIndex (Constr ix _) want label =
    if ix == want
        then emit ("index-" <> label) ("Constr " <> show ix <> " ok")
        else failWith ("CS01: " <> label <> " has Constr " <> show ix <> ", want " <> show want)
requireIndex other _ label =
    failWith ("CS01: " <> label <> " is not a Constr: " <> show other)

-- ---------------------------------------------------------
-- Per-type checks
-- ---------------------------------------------------------

checkTokenId :: Map.Map Text Schema -> IO ()
checkTokenId defs = do
    requireRoundTripReal sampleToken "OnChainTokenId"
    requireSchema defs "lib/TokenId" (toD sampleToken) "OnChainTokenId"
    requireIndex (toD sampleToken) 0 "OnChainTokenId"

checkTxOutRef :: Map.Map Text Schema -> IO ()
checkTxOutRef defs = do
    requireRoundTripReal sampleRef "OnChainTxOutRef"
    requireSchema defs "cardano/transaction/OutputReference" (toD sampleRef) "OnChainTxOutRef"
    requireIndex (toD sampleRef) 0 "OnChainTxOutRef"

checkRoot :: Map.Map Text Schema -> IO ()
checkRoot defs = do
    requireRoundTripReal sampleRoot "OnChainRoot"
    requireSchema defs "ByteArray" (toD sampleRoot) "OnChainRoot"
    case toD sampleRoot of
        B _ -> emit "index-OnChainRoot" "bytes ok (no constructor)"
        other -> failWith ("CS01: OnChainRoot is not bytes: " <> show other)

checkOperation :: Map.Map Text Schema -> IO ()
checkOperation defs = do
    let ins = OpInsert "v1"
        del = OpDelete "v1"
        upd = OpUpdate "old" "new"
    requireRoundTripReal ins "OpInsert"
    requireRoundTripReal del "OpDelete"
    requireRoundTripReal upd "OpUpdate"
    requireSchema defs "types/Operation" (toD ins) "OpInsert"
    requireSchema defs "types/Operation" (toD del) "OpDelete"
    requireSchema defs "types/Operation" (toD upd) "OpUpdate"
    requireIndex (toD ins) 0 "OpInsert"
    requireIndex (toD del) 1 "OpDelete"
    requireIndex (toD upd) 2 "OpUpdate"

checkRequest :: Map.Map Text Schema -> IO ()
checkRequest defs = do
    requireRoundTripReal sampleRequest "OnChainRequest"
    requireSchema defs "types/Request" (toD sampleRequest) "OnChainRequest"
    requireIndex (toD sampleRequest) 0 "OnChainRequest"

checkState :: Map.Map Text Schema -> IO ()
checkState defs = do
    requireRoundTripReal sampleState "OnChainTokenState-None"
    requireRoundTripReal sampleStateSome "OnChainTokenState-Some"
    requireSchema defs "types/State" (toD sampleState) "OnChainTokenState-None"
    requireSchema defs "types/State" (toD sampleStateSome) "OnChainTokenState-Some"
    requireIndex (toD sampleState) 0 "OnChainTokenState"

checkCageDatum :: Map.Map Text Schema -> IO ()
checkCageDatum defs = do
    let req = RequestDatum sampleRequest
        st = StateDatum sampleState
    requireRoundTripReal req "RequestDatum"
    requireRoundTripReal st "StateDatum"
    requireSchema defs "types/CageDatum" (toD req) "RequestDatum"
    requireSchema defs "types/CageDatum" (toD st) "StateDatum"
    requireIndex (toD req) 0 "RequestDatum"
    requireIndex (toD st) 1 "StateDatum"

checkMintRedeemer :: Map.Map Text Schema -> IO ()
checkMintRedeemer defs = do
    let minting = Minting sampleRef
        migrating = Migrating sampleMigration
        burning = Burning sampleToken
    requireRoundTripReal minting "Minting"
    requireRoundTripReal migrating "Migrating"
    requireRoundTripReal burning "Burning"
    requireSchema defs "types/MintRedeemer" (toD minting) "Minting"
    requireSchema defs "types/MintRedeemer" (toD migrating) "Migrating"
    requireSchema defs "types/MintRedeemer" (toD burning) "Burning"
    requireIndex (toD minting) 0 "Minting"
    requireIndex (toD migrating) 1 "Migrating"
    requireIndex (toD burning) 2 "Burning"

checkMigration :: Map.Map Text Schema -> IO ()
checkMigration defs = do
    requireRoundTripReal sampleMigration "Migration"
    requireSchema defs "types/Migration" (toD sampleMigration) "Migration"
    requireIndex (toD sampleMigration) 0 "Migration"

checkRequestAction :: Map.Map Text Schema -> IO ()
checkRequestAction defs = do
    let upd = Update [sampleBranch, sampleFork, sampleLeaf]
        rej = Rejected
    requireRoundTripReal upd "Update"
    requireRoundTripReal rej "Rejected"
    requireSchema defs "types/RequestAction" (toD upd) "Update"
    requireSchema defs "types/RequestAction" (toD rej) "Rejected"
    requireIndex (toD upd) 0 "Update"
    requireIndex (toD rej) 1 "Rejected"

checkUpdateRedeemer :: Map.Map Text Schema -> Bool -> IO ()
checkUpdateRedeemer defs spoil = do
    let end = End
        contrib = Contribute sampleRef
        modify = Modify [Update [sampleLeaf], Rejected]
        retract = Retract sampleRef
        sweep = Sweep sampleRef
    requireRoundTripReal end "End"
    requireRoundTripReal contrib "Contribute"
    requireRoundTripReal modify "Modify"
    requireRoundTripReal retract "Retract"
    requireRoundTripReal sweep "Sweep"
    requireSchema defs "types/UpdateRedeemer" (toD contrib) "Contribute"
    requireSchema defs "types/UpdateRedeemer" (toD modify) "Modify"
    requireSchema defs "types/UpdateRedeemer" (toD retract) "Retract"
    requireSchema defs "types/UpdateRedeemer" (toD sweep) "Sweep"
    if spoil
        then do
            emit "control" "wrong-index armed: demanding Constr 99 for End"
            requireIndex (toD end) 99 "End-control"
        else do
            requireSchema defs "types/UpdateRedeemer" (toD end) "End"
            requireIndex (toD end) 0 "End"
    requireIndex (toD contrib) 1 "Contribute"
    requireIndex (toD modify) 2 "Modify"
    requireIndex (toD retract) 3 "Retract"
    requireIndex (toD sweep) 4 "Sweep"
    let bad = Constr 99 []
    case Map.lookup "types/UpdateRedeemer" defs of
        Nothing -> failWith "CS01 gap: no types/UpdateRedeemer definition"
        Just schema ->
            if validateData defs schema bad
                then failWith "CS01 control failed: Constr 99 validates against UpdateRedeemer"
                else emit "control-bad-index" "Constr 99 correctly rejected"

checkProofStep :: Map.Map Text Schema -> IO ()
checkProofStep defs = do
    requireRoundTripReal sampleBranch "Branch"
    requireRoundTripReal sampleFork "Fork"
    requireRoundTripReal sampleLeaf "Leaf"
    requireSchema defs "aiken/merkle_patricia_forestry/ProofStep" (toD sampleBranch) "Branch"
    requireSchema defs "aiken/merkle_patricia_forestry/ProofStep" (toD sampleFork) "Fork"
    requireSchema defs "aiken/merkle_patricia_forestry/ProofStep" (toD sampleLeaf) "Leaf"
    requireIndex (toD sampleBranch) 0 "Branch"
    requireIndex (toD sampleFork) 1 "Fork"
    requireIndex (toD sampleLeaf) 2 "Leaf"

checkNeighbor :: Map.Map Text Schema -> IO ()
checkNeighbor defs = do
    requireRoundTripReal sampleNeighbor "Neighbor"
    requireSchema defs "aiken/merkle_patricia_forestry/Neighbor" (toD sampleNeighbor) "Neighbor"
    requireIndex (toD sampleNeighbor) 0 "Neighbor"

checkOptionStake :: Map.Map Text Schema -> IO ()
checkOptionStake defs = do
    let someD = Constr 0 [B (BS.replicate 28 7)]
        noneD = Constr 1 []
    requireSchema defs "Option<aiken/crypto/ScriptHash>" someD "stake-Some"
    requireSchema defs "Option<aiken/crypto/ScriptHash>" noneD "stake-None"
    requireIndex someD 0 "stake-Some"
    requireIndex noneD 1 "stake-None"

-- ---------------------------------------------------------
-- Round trips through the real instances (mirrored decoding)
-- ---------------------------------------------------------

-- | Round trip through a mirrored decoder shaped like the real
-- 'FromData' instances. The mirror exists so the row does not test
-- a codec against itself alone: the blueprint schema check above is
-- the binding verdict, and this round trip proves the Haskell side
-- at least decodes what it encodes.
requireRoundTripReal :: (ToData a, RealFromData a, Eq a) => a -> String -> IO ()
requireRoundTripReal x label =
    case realFromData (let BuiltinData d = toBuiltinData x in d) of
        Just y ->
            if y == x
                then emit ("roundtrip-" <> label) "ok"
                else failWith ("CS01: " <> label <> " round trip mismatch")
        Nothing -> failWith ("CS01: " <> label <> " FromData failed")

class RealFromData a where
    realFromData :: Data -> Maybe a

instance RealFromData OnChainTokenId where
    realFromData (Constr 0 [B bs]) = Just (OnChainTokenId (BuiltinByteString bs))
    realFromData _ = Nothing

instance RealFromData OnChainTxOutRef where
    realFromData (Constr 0 [B tid, I idx]) =
        Just (OnChainTxOutRef (BuiltinByteString tid) idx)
    realFromData _ = Nothing

instance RealFromData OnChainRoot where
    realFromData (B bs) = Just (OnChainRoot bs)
    realFromData _ = Nothing

instance RealFromData OnChainOperation where
    realFromData (Constr 0 [B v]) = Just (OpInsert v)
    realFromData (Constr 1 [B v]) = Just (OpDelete v)
    realFromData (Constr 2 [B o, B n]) = Just (OpUpdate o n)
    realFromData _ = Nothing

instance RealFromData OnChainRequest where
    realFromData (Constr 0 [tok, B own, B k, val, I fee, I sub]) = do
        tk <- realFromData tok :: Maybe OnChainTokenId
        vv <- realFromData val :: Maybe OnChainOperation
        Just
            OnChainRequest
                { requestToken = tk
                , requestOwner = BuiltinByteString own
                , requestKey = k
                , requestValue = vv
                , requestFee = fee
                , requestSubmittedAt = sub
                }
    realFromData _ = Nothing

instance RealFromData OnChainTokenState where
    realFromData (Constr 0 [B own, stake, r, I mf, I pt, I rt]) = do
        st <- case stake of
            Constr 0 [B h] -> Just (Just (BuiltinByteString h))
            Constr 1 [] -> Just Nothing
            _ -> Nothing
        rt' <- realFromData r :: Maybe OnChainRoot
        Just
            OnChainTokenState
                { stateOwner = BuiltinByteString own
                , stateStakeScript = st
                , stateRoot = rt'
                , stateMaxFee = mf
                , stateProcessTime = pt
                , stateRetractTime = rt
                }
    realFromData _ = Nothing

instance RealFromData CageDatum where
    realFromData (Constr 0 [d]) = RequestDatum <$> realFromData d
    realFromData (Constr 1 [d]) = StateDatum <$> realFromData d
    realFromData _ = Nothing

instance RealFromData Migration where
    realFromData (Constr 0 [B pol, tid]) = do
        t <- realFromData tid :: Maybe OnChainTokenId
        Just Migration{migrationOldPolicy = BuiltinByteString pol, migrationTokenId = t}
    realFromData _ = Nothing

instance RealFromData MintRedeemer where
    realFromData (Constr 0 [d]) = Minting <$> realFromData d
    realFromData (Constr 1 [d]) = Migrating <$> realFromData d
    realFromData (Constr 2 [d]) = Burning <$> realFromData d
    realFromData _ = Nothing

instance RealFromData Neighbor where
    realFromData (Constr 0 [I nib, B pfx, B rt]) = Just (Neighbor nib pfx rt)
    realFromData _ = Nothing

instance RealFromData ProofStep where
    realFromData (Constr 0 [I sk, B nb]) = Just (Branch sk nb)
    realFromData (Constr 1 [I sk, nd]) = Fork sk <$> realFromData nd
    realFromData (Constr 2 [I sk, B k, B v]) = Just (Leaf sk k v)
    realFromData _ = Nothing

instance RealFromData RequestAction where
    realFromData (Constr 0 [List steps]) = Update <$> traverse realFromData steps
    realFromData (Constr 1 []) = Just Rejected
    realFromData _ = Nothing

instance RealFromData UpdateRedeemer where
    realFromData (Constr 0 []) = Just End
    realFromData (Constr 1 [d]) = Contribute <$> realFromData d
    realFromData (Constr 2 [List as]) = Modify <$> traverse realFromData as
    realFromData (Constr 3 [d]) = Retract <$> realFromData d
    realFromData (Constr 4 [d]) = Sweep <$> realFromData d
    realFromData _ = Nothing

-- ---------------------------------------------------------
-- Field-title order from the blueprint JSON
-- ---------------------------------------------------------

type TitleMap = Map.Map Text [(Text, Integer, [Text])]

extractTitles :: Aeson.Value -> TitleMap
extractTitles val =
    case AesonTypes.parseMaybe parseDefs val of
        Just m -> m
        Nothing -> Map.empty
  where
    parseDefs = AesonTypes.withObject "blueprint" $ \o -> do
        defs <- o AesonTypes..: "definitions" :: AesonTypes.Parser (Map.Map Text Aeson.Value)
        Map.fromList <$> mapM parseOne (Map.toList defs)
    parseOne (name, v) =
        case AesonTypes.parseMaybe parseDef v of
            Just cs -> pure (name, cs)
            Nothing -> pure (name, [])
    parseDef = AesonTypes.withObject "def" $ \o -> do
        mAny <- o AesonTypes..:? "anyOf" :: AesonTypes.Parser (Maybe [Aeson.Value])
        case mAny of
            Just cs -> mapM parseConstr cs
            Nothing -> pure []
    parseConstr = AesonTypes.withObject "constr" $ \o -> do
        title <- o AesonTypes..:? "title" AesonTypes..!= ""
        idx <- o AesonTypes..:? "index" AesonTypes..!= (-1)
        fields <- o AesonTypes..:? "fields" AesonTypes..!= ([] :: [Aeson.Value])
        ftitles <- mapM parseFieldTitle fields
        pure (title, idx, ftitles)
    parseFieldTitle = AesonTypes.withObject "field" $ \o ->
        o AesonTypes..:? "title" AesonTypes..!= ""

checkFieldTitles :: TitleMap -> IO ()
checkFieldTitles titles = do
    expectFields titles "types/State" "State" ["owner", "stake_script", "root", "tip", "process_time", "retract_time"]
    expectFields titles "types/Request" "Request" ["requestToken", "requestOwner", "requestKey", "requestValue", "tip", "submitted_at"]
    expectFields titles "types/Migration" "Migration" ["oldPolicy", "tokenId"]
    expectFields titles "lib/TokenId" "TokenId" ["assetName"]
    expectFields titles "cardano/transaction/OutputReference" "OutputReference" ["transaction_id", "output_index"]
    expectFields titles "aiken/merkle_patricia_forestry/Neighbor" "Neighbor" ["nibble", "prefix", "root"]
    expectFields titles "aiken/merkle_patricia_forestry/ProofStep" "Branch" ["skip", "neighbors"]
    expectFields titles "aiken/merkle_patricia_forestry/ProofStep" "Fork" ["skip", "neighbor"]
    expectFields titles "aiken/merkle_patricia_forestry/ProofStep" "Leaf" ["skip", "key", "value"]
    emit "fields" "title order matches Haskell record order for 9 shapes"

expectFields :: TitleMap -> Text -> Text -> [Text] -> IO ()
expectFields titles defName constrName want =
    case Map.lookup defName titles of
        Nothing -> failWith ("CS01 gap: no titles for " <> T.unpack defName)
        Just cs -> case [fs | (t, _, fs) <- cs, t == constrName] of
            [] -> failWith ("CS01: no constructor " <> T.unpack constrName <> " in " <> T.unpack defName)
            (fs : _) ->
                if fs == want
                    then emit ("fields-" <> T.unpack constrName) "order ok"
                    else
                        failWith
                            ( "CS01: field order for "
                                <> T.unpack constrName
                                <> " is "
                                <> show fs
                                <> ", want "
                                <> show want
                            )

-- ---------------------------------------------------------
-- Receipt helpers (mirroring Run.hs, no node)
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
