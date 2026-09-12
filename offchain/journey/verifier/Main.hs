{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Main
Description : Recompute S3 verdicts from raw run evidence (issue #77)
License     : Apache-2.0

Offline verifier for the connected insert journey. It reads the raw
artifacts a `register-rows` run retained — serialized submitted bodies,
submission outcomes, full address listings, blueprint paths — recomputes
every fact from ledger bytes and the built blueprint, and writes one
verdict per S3 obligation:

> connected-verifier --evidence <dir> --blueprint <path>
>   --mpfs-blueprint <path> --candidate <sha> --out <verdicts.json>

`{ "<obligation>": { "status": "ESTABLISHED" | "REFUTED" |
"COULD-NOT-EVALUATE", "detail": "..." } }`.

What it recomputes (never trusts): txids from bodies; inputs, outputs,
datums and mint fields from bodies; roots by decoding datums with the
library codecs; identities by applying the bound parameters to the
compiled programs; asset and approval names by re-deriving them from
observed datums; purpose-to-script attribution by comparing address
credentials and mint policies against derived hashes; rejection
attribution by binding the hash named in the node reason to the
blueprint. Structural checks corroborate; the node's execution boundary
decides (NOTE-011). Anything missing or undecodable is
COULD-NOT-EVALUATE, never a pass.
-}
module Main (main) where

import Control.Exception (SomeException, try)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.Foldable qualified as Foldable
import Data.Word (Word32)
import Data.List (isInfixOf, isSuffixOf, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((^.))
import PlutusCore.Data qualified as PLC
import System.Directory (doesFileExist, listDirectory)
import System.Environment (getArgs)
import System.Exit (exitWith, ExitCode (..))
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Api.Scripts.Data (Data (..), Datum (..), binaryDataToData)
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body (
    inputsTxBodyL,
    mintTxBodyL,
    outputsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.In (TxIn (..))
import Cardano.Ledger.Api.Tx.Out (TxOut, addrTxOutL, datumTxOutL, valueTxOutL)
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL)
import Cardano.Ledger.Api.Tx (witsTxL)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (extractHash)
import Cardano.Ledger.Credential (Credential (..))

import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..), PolicyID (..))
import Cardano.Ledger.TxIn (TxId (..))

import Cardano.Ledger.Binary (DecCBOR (..), decodeFull', decodeFullAnnotator)
import Cardano.Ledger.Binary.Version (Version)
import Cardano.MPFS.Cage.Blueprint (
    applyBytesParam,
    applyRequestParams,
    extractCompiledCode,
    loadBlueprint,
 )
import Cardano.MPFS.Cage.TxBuilder.Internal (extractCageDatum, onChainTokenId)
import Cardano.MPFS.Cage.Ledger (
    AssetName (..),
    ConwayEra,
    TokenId (..),
 )
import Cardano.MPFS.Cage.TxBuilder.Internal (
    computeScriptHash,
    scriptHashBytes,
 )
import Cardano.MPFS.Cage.Types (
    CageDatum (..),
    OnChainRequest (..),
    OnChainRoot (..),
    OnChainTokenState (..),
 )
import Cardano.Tx.Ledger (ConwayTx)
import Naming.Datum
import Naming.Register
import Naming.Wire
    ( Address (..)
    , WireData (..)
    , addressBytes
    , decodeAddress
    )

-- ---------------------------------------------------------
-- Verdicts
-- ---------------------------------------------------------

data Status
    = Established
    | Refuted
    | CouldNotEvaluate
    deriving (Eq, Show)

data Verdict = Verdict
    { vStatus :: Status
    , vDetail :: String
    }

statusText :: Status -> String
statusText Established = "ESTABLISHED"
statusText Refuted = "REFUTED"
statusText CouldNotEvaluate = "COULD-NOT-EVALUATE"

verdictJson :: Verdict -> Value
verdictJson v =
    object
        [ "status" .= statusText (vStatus v)
        , "detail" .= vDetail v
        ]

established :: String -> Verdict
established = Verdict Established

refuted :: String -> Verdict
refuted = Verdict Refuted

cne :: String -> Verdict
cne = Verdict CouldNotEvaluate

-- ---------------------------------------------------------
-- CLI
-- ---------------------------------------------------------

data Args = Args
    { argEvidence :: FilePath
    , argBlueprint :: FilePath
    , argMpfsBlueprint :: FilePath
    , argCandidate :: String
    , argOut :: FilePath
    }

parseArgs :: [String] -> Maybe Args
parseArgs =
    go (Args "" "" "" "" "")
  where
    go a [] = valid a
    go a ("--evidence" : v : rest) = go (a{argEvidence = v}) rest
    go a ("--blueprint" : v : rest) = go (a{argBlueprint = v}) rest
    go a ("--mpfs-blueprint" : v : rest) = go (a{argMpfsBlueprint = v}) rest
    go a ("--candidate" : v : rest) = go (a{argCandidate = v}) rest
    go a ("--out" : v : rest) = go (a{argOut = v}) rest
    go _ _ = Nothing
    valid a
        | null (argEvidence a)
            || null (argBlueprint a)
            || null (argMpfsBlueprint a)
            || null (argCandidate a)
            || null (argOut a) =
            Nothing
        | otherwise = Just a

usage :: String
usage =
    "connected-verifier --evidence <dir> --blueprint <path> \
    \--mpfs-blueprint <path> --candidate <sha> --out <verdicts.json>"

main :: IO ()
main = do
    argv <- getArgs
    case parseArgs argv of
        Nothing -> do
            hPutStrLn stderr usage
            exitWith (ExitFailure 2)
        Just args -> do
            verdicts <- runVerifier args
            BSL.writeFile (argOut args) (Aeson.encode (object [(Key.fromString k, verdictJson v) | (k, v) <- verdicts]))
            let bad =
                    [ k
                    | (k, Verdict st _) <- verdicts
                    , st /= Established
                    ]
            mapM_
                (\(k, v) -> hPutStrLn stderr (k <> ": " <> statusText (vStatus v) <> " — " <> vDetail v))
                verdicts
            if null bad then pure () else exitWith (ExitFailure 1)

-- ---------------------------------------------------------
-- Evidence loading (missing or undecodable is COULD-NOT-EVALUATE)
-- ---------------------------------------------------------

-- | CBOR version for evidence decoding. Runner and verifier share the
-- identical pinned stack; every recomputation below validates the choice
-- (a skew fails loudly as undecodable or as a txid mismatch, never
-- silently).
evidenceVersion :: Version
evidenceVersion = maxBound

data Evidence = Evidence
    { evDir :: FilePath
    , evMeta :: Aeson.Object
    , evBodies :: Map.Map String ConwayTx
    , evOutcomes :: Map.Map String Aeson.Object
    , evUtxos :: Map.Map String (TxOut ConwayEra)
    }

hexDecode :: String -> Maybe ByteString
hexDecode s = case Base16.decode (TE.encodeUtf8 (T.pack s)) of
    Right bs -> Just bs
    Left _ -> Nothing

loadEvidence :: FilePath -> IO (Either String Evidence)
loadEvidence dir = tryLoad
  where
    tryLoad = do
        files <- try (listDirectory dir) :: IO (Either SomeException [FilePath])
        case files of
            Left e -> pure (Left ("cannot list evidence dir: " <> show e))
            Right names -> do
                meta <- loadMeta dir
                case meta of
                    Left err -> pure (Left err)
                    Right m -> do
                        bodies <- loadBodies dir names
                        case bodies of
                            Left err -> pure (Left err)
                            Right b -> do
                                outcomes <- loadOutcomes dir names
                                utxos <- loadListings dir names
                                pure
                                    ( Right
                                        Evidence
                                            { evDir = dir
                                            , evMeta = m
                                            , evBodies = b
                                            , evOutcomes = outcomes
                                            , evUtxos = utxos
                                            }
                                    )

loadMeta :: FilePath -> IO (Either String Aeson.Object)
loadMeta dir = do
    let path = dir </> "meta.json"
    ok <- doesFileExist path
    if not ok
        then pure (Left "meta.json missing")
        else do
            bs <- BSL.readFile path
            case Aeson.eitherDecode' bs of
                Right (Aeson.Object o) -> pure (Right o)
                Right _ -> pure (Left "meta.json is not an object")
                Left err -> pure (Left ("meta.json undecodable: " <> err))

txTagOf :: FilePath -> Maybe String
txTagOf name
    | "tx-" `isPrefixOf'` name && ".cborhex" `isSuffixOf` name =
        Just (take (length name - 3 - 8) (drop 3 name))
    | otherwise = Nothing
  where
    isPrefixOf' p s = take (length p) s == p

loadBodies :: FilePath -> [FilePath] -> IO (Either String (Map.Map String ConwayTx))
loadBodies dir names = do
    results <- mapM loadOne [t | Just t <- map txTagOf names]
    case [e | Left e <- results] of
        (e : _) -> pure (Left e)
        [] -> pure (Right (Map.fromList [(t, tx) | Right (t, tx) <- results]))
  where
    loadOne tag = do
        content <- try (readFile (dir </> ("tx-" <> tag <> ".cborhex"))) :: IO (Either SomeException String)
        case content of
            Left e -> pure (Left ("cannot read body " <> tag <> ": " <> show e))
            Right hexText -> case hexDecode (filter (/= '\n') hexText) of
                Nothing -> pure (Left ("body hex undecodable: " <> tag))
                Just bs -> case decodeFullAnnotator evidenceVersion "ConwayTx" decCBOR (BSL.fromStrict bs) of
                    Left err -> pure (Left ("body CBOR undecodable: " <> tag <> ": " <> show err))
                    Right tx -> pure (Right (tag, tx))

loadOutcomes :: FilePath -> [FilePath] -> IO (Map.Map String Aeson.Object)
loadOutcomes dir names = do
    pairs <- mapM loadOne [t | Just t <- map txTagOf names]
    pure (Map.fromList [(t, o) | Just (t, o) <- pairs])
  where
    loadOne tag = do
        let path = dir </> ("tx-" <> tag <> ".outcome.json")
        ok <- doesFileExist path
        if not ok
            then pure Nothing
            else do
                bs <- BSL.readFile path
                case Aeson.eitherDecode' bs of
                    Right (Aeson.Object o) -> pure (Just (tag, o))
                    _ -> pure Nothing

loadListings :: FilePath -> [FilePath] -> IO (Map.Map String (TxOut ConwayEra))
loadListings dir names = do
    let listingFiles = [n | n <- names, "listings-" `isPrefixOf'` n && ".json" `isSuffixOf` n]
    pairs <- fmap concat (mapM loadOne listingFiles)
    pure (Map.fromList pairs)
  where
    isPrefixOf' p s = take (length p) s == p
    loadOne file = do
        bs <- BSL.readFile (dir </> file)
        case Aeson.eitherDecode' bs of
            Right (Aeson.Object addrs) ->
                pure (concatMap decodeEntry (concatMap entriesOf (KM.elems addrs)))
            _ -> pure []
    entriesOf (Aeson.Array arr) = [v | v@(Aeson.Object _) <- Foldable.toList arr]
    entriesOf _ = []
    decodeEntry (Aeson.Object o) = case (KM.lookup "outref" o, KM.lookup "txout_cbor" o) of
        (Just (Aeson.String ref), Just (Aeson.String cborHex)) ->
            case hexDecode (T.unpack cborHex) of
                Just bs -> case decodeFull' evidenceVersion bs of
                    Right out -> [((T.unpack ref, out) :: (String, TxOut ConwayEra))]
                    Left _ -> []
                Nothing -> []
        _ -> []
    decodeEntry _ = []

-- ---------------------------------------------------------
-- Blueprint identities (recomputed, never read as claims)
-- ---------------------------------------------------------

data Identities = Identities
    { idAppHash :: ByteString
    , idAppHex :: String
    , idRepUnappliedHex :: String
    , idRepAppliedHash :: ByteString
    , idRepAppliedHex :: String
    , idStateHash :: ByteString
    , idStateHex :: String
    , idReqCode :: SBS.ShortByteString
    }

loadIdentities :: FilePath -> FilePath -> IO (Either String Identities)
loadIdentities namingPath mpfsPath = do
    outcome <- try loadAll :: IO (Either SomeException Identities)
    pure (first show outcome)
  where
    loadAll = do
        nbp <- either fail pure =<< loadBlueprint namingPath
        mbp <- either fail pure =<< loadBlueprint mpfsPath
        case
            ( extractCompiledCode "application.application" nbp
            , extractCompiledCode "representative.representative" nbp
            , extractCompiledCode "state.state" mbp
            , extractCompiledCode "request.request" mbp
            ) of
            (Just appBytes, Just repBytes, Just stateBytes, Just reqBytes) ->
                pure (assemble appBytes repBytes stateBytes reqBytes)
            _ -> fail "required validator code missing from blueprints"
    assemble appBytes repBytes stateBytes reqBytes =
        let appH = scriptHashBytes (computeScriptHash appBytes)
            repApplied = applyBytesParam appH repBytes
            repAppliedH = scriptHashBytes (computeScriptHash repApplied)
         in Identities
                { idAppHash = appH
                , idAppHex = hexStr appH
                , idRepUnappliedHex = hexStr (scriptHashBytes (computeScriptHash repBytes))
                , idRepAppliedHash = repAppliedH
                , idRepAppliedHex = hexStr repAppliedH
                , idStateHash = scriptHashBytes (computeScriptHash stateBytes)
                , idStateHex = hexStr (scriptHashBytes (computeScriptHash stateBytes))
                , idReqCode = reqBytes
                }

hexStr :: ByteString -> String
hexStr = T.unpack . TE.decodeUtf8 . Base16.encode

-- ---------------------------------------------------------
-- Body accessors over decoded transactions
-- ---------------------------------------------------------

txInputs :: ConwayTx -> [TxIn]
txInputs tx = Set.toList (tx ^. bodyTxL . inputsTxBodyL)

txOutputs :: ConwayTx -> [TxOut ConwayEra]
txOutputs tx = Foldable.toList (tx ^. bodyTxL . outputsTxBodyL)

txMint :: ConwayTx -> [(PolicyID, ByteString, Integer)]
txMint tx =
    let MultiAsset ma = tx ^. bodyTxL . mintTxBodyL
     in [ (p, SBS.fromShort n, q)
        | (p, names) <- Map.toList ma
        , (AssetName n, q) <- Map.toList names
        ]

txRedeemers :: ConwayTx -> [(ConwayPlutusPurpose AsIx ConwayEra, PLC.Data)]
txRedeemers tx =
    let Redeemers m = tx ^. witsTxL . rdmrsTxWitsL
     in [(purp, plc) | (purp, (Data plc, _)) <- Map.toList m]

addrCredentialHex :: TxOut ConwayEra -> Maybe String
addrCredentialHex out = case out ^. addrTxOutL of
    Addr _ (ScriptHashObj sh) _ -> Just (hexStr (scriptHashBytes sh))
    _ -> Nothing

-- | Purpose index into the sorted input list.
spendInput :: ConwayTx -> Word32 -> Maybe TxIn
spendInput tx ix = atIndex (sortOn id (txInputs tx)) (fromIntegral ix)

-- | Policy for a mint purpose index (sorted policy order).
mintPolicy :: ConwayTx -> Word32 -> Maybe PolicyID
mintPolicy tx ix =
    let MultiAsset ma = tx ^. bodyTxL . mintTxBodyL
     in atIndex (sortOn id (Map.keys ma)) (fromIntegral ix)

purposeIndex :: ConwayPlutusPurpose AsIx ConwayEra -> Maybe Word32
purposeIndex (ConwaySpending (AsIx w)) = Just w
purposeIndex (ConwayMinting (AsIx w)) = Just w
purposeIndex _ = Nothing

atIndex :: [a] -> Int -> Maybe a
atIndex [] _ = Nothing
atIndex (x : _) 0 = Just x
atIndex (_ : xs) n = atIndex xs (n - 1)

-- ---------------------------------------------------------
-- Datum decoders
-- ---------------------------------------------------------

wireOf :: PLC.Data -> Maybe WireData
wireOf (PLC.Constr i fs)
    | i >= 0 && i <= 6 = Constr (fromIntegral i) <$> traverse wireOf fs
    | otherwise = Nothing
wireOf (PLC.B b) = Just (WBytes b)
wireOf (PLC.I n) = Just (WInt n)
wireOf (PLC.List xs) = WList <$> traverse wireOf xs
wireOf (PLC.Map _) = Nothing

outCageDatum :: TxOut ConwayEra -> Maybe CageDatum
outCageDatum = extractCageDatum

outNamingDatum :: TxOut ConwayEra -> Maybe NamingDatum
outNamingDatum out = case out ^. datumTxOutL of
    Datum bd -> case binaryDataToData bd of
        Data plc -> wireOf plc >>= decodeNamingDatum
    _ -> Nothing

-- ---------------------------------------------------------
-- Shape classification (structural entry points, not verdicts)
-- ---------------------------------------------------------

data Purpose
    = PSpend TxIn PLC.Data
    | PMint PolicyID PLC.Data
    deriving (Show)

txPurposes :: ConwayTx -> [Purpose]
txPurposes tx =
    mapMaybe
        ( \case
            (purp, plc) -> case (purp, purposeIndex purp) of
                (ConwaySpending _, Just w) -> PSpend <$> spendInput tx w <*> pure plc
                (ConwayMinting _, Just w) -> PMint <$> mintPolicy tx w <*> pure plc
                _ -> Nothing
        )
        (txRedeemers tx)

constrIndex :: PLC.Data -> Maybe Integer
constrIndex (PLC.Constr i _) = Just i
constrIndex _ = Nothing

-- | A purpose resolved to the validator it runs under. Redeemer
-- constructor indices are per-validator; resolving first is what makes
-- shape classification sound.
data ResolvedPurpose
    = RStateSpend TxIn Integer
    | RRequestSpend TxIn Integer
    | RAppSpend TxIn Integer
    | RStateMint Integer
    | RAppMint Integer
    | RRepMint Integer
    | RUnresolved String
    deriving (Eq, Show)

data Shape
    = ConnectedFold
    | MpfsFold
    | EndAttempt
    | MigratingMint
    | BurningMint
    | SweepSpend
    | RequestSubmission
    | OtherShape String
    deriving (Eq, Show)

resolvePurposes ::
    Identities -> Map.Map String (TxOut ConwayEra) -> ConwayTx -> [ResolvedPurpose]
resolvePurposes ids utxos tx = map resolve (txPurposes tx)
  where
    resolve (PSpend inp plc) = case Map.lookup (showInShort inp) utxos of
        Just out -> case addrCredentialHex out of
            Just h
                | h == idStateHex ids -> RStateSpend inp (constrIdx plc)
                | h == idAppHex ids -> RAppSpend inp (constrIdx plc)
                | otherwise -> RRequestSpend inp (constrIdx plc)
            Nothing -> RUnresolved ("key input spent: " <> showInShort inp)
        Nothing -> RUnresolved ("spent input not retained: " <> showInShort inp)
      where
        constrIdx p = fromMaybe (-1) (constrIndex p)
    resolve (PMint policy plc) =
        let h = policyHex policy
            idx = fromMaybe (-1) (constrIndex plc)
         in if
                | h == idStateHex ids -> RStateMint idx
                | h == idAppHex ids -> RAppMint idx
                | h == idRepAppliedHex ids -> RRepMint idx
                | otherwise -> RUnresolved ("mint under unknown policy: " <> h)
    policyHex (PolicyID sh) = hexStr (scriptHashBytes sh)

classifyBody :: [ResolvedPurpose] -> Shape
classifyBody purposes
    | 2 `elem` stateIdxs && 1 `elem` requestIdxs && 2 `elem` appIdxs = ConnectedFold
    | 2 `elem` stateIdxs && 1 `elem` requestIdxs && null mintIdxs && length spendCount == 2 = MpfsFold
    | 0 `elem` stateIdxs = EndAttempt
    | stateMintIdxs == [1] && null spendCount = MigratingMint
    | stateMintIdxs == [2] && null spendCount = BurningMint
    | 4 `elem` requestIdxs = SweepSpend
    | null purposes = RequestSubmission
    | otherwise = OtherShape (show purposes)
  where
    stateIdxs = [i | RStateSpend _ i <- purposes]
    requestIdxs = [i | RRequestSpend _ i <- purposes]
    appIdxs = [i | RAppSpend _ i <- purposes]
    stateMintIdxs = [i | RStateMint i <- purposes]
    spendCount =
        [() | RStateSpend _ _ <- purposes]
            <> [() | RRequestSpend _ _ <- purposes]
            <> [() | RAppSpend _ _ <- purposes]
    mintIdxs =
        [() | RStateMint _ <- purposes]
            <> [() | RAppMint _ <- purposes]
            <> [() | RRepMint _ <- purposes]

-- ---------------------------------------------------------
-- Verdict engine
-- ---------------------------------------------------------

runVerifier :: Args -> IO [(String, Verdict)]
runVerifier args = do
    ev <- loadEvidence (argEvidence args)
    case ev of
        Left err -> pure (allCne ("evidence unloadable: " <> err))
        Right evd -> do
            ids <- loadIdentities (argBlueprint args) (argMpfsBlueprint args)
            case ids of
                Left err -> pure (allCne ("blueprint unloadable: " <> err))
                Right idents -> do
                    metaOk <- checkCandidate evd args
                    case metaOk of
                        Just v -> pure (allCne (vDetail v))
                        Nothing -> pure (checkAll evd idents)
  where
    allCne reason = [(k, cne reason) | k <- obligationKeys]

obligationKeys :: [String]
obligationKeys =
    [ "connected.txid"
    , "connected.state-input"
    , "connected.request-input"
    , "connected.continuation"
    , "connected.root-before"
    , "connected.root-after"
    , "representative.applied"
    , "representative.asset"
    , "representative.approval"
    , "representative.key"
    , "refusal.insert"
    , "refusal.end"
    , "refusal.migration"
    , "refusal.sweep"
    , "refusal.burning"
    , "control.free-key"
    , "control.supported-action"
    ]

checkCandidate :: Evidence -> Args -> IO (Maybe Verdict)
checkCandidate evd args = case KM.lookup "candidate" (evMeta evd) of
    Just (Aeson.String c)
        | T.unpack c == argCandidate args -> pure Nothing
        | otherwise ->
            pure
                ( Just
                    ( cne
                        ( "candidate mismatch: evidence says "
                            <> T.unpack c
                            <> " but invoked with "
                            <> argCandidate args
                        )
                    )
                )
    _ -> pure (Just (cne "meta.json carries no candidate"))

checkAll :: Evidence -> Identities -> [(String, Verdict)]
checkAll evd ids =
    [ ("connected.txid", vConnectedTxid ctx)
    , ("connected.state-input", vConnectedStateInput ctx)
    , ("connected.request-input", vConnectedRequestInput ctx)
    , ("connected.continuation", vConnectedContinuation ctx)
    , ("connected.root-before", vConnectedRootBefore ctx)
    , ("connected.root-after", vConnectedRootAfter ctx)
    , ("representative.applied", vRepresentativeApplied ctx)
    , ("representative.asset", vRepresentativeAsset ctx)
    , ("representative.approval", vRepresentativeApproval ctx)
    , ("representative.key", vRepresentativeKey ctx)
    , ("refusal.insert", vRefusalInsert ctx)
    , ("refusal.end", vRefusalEnd ctx)
    , ("refusal.migration", vRefusalMigration ctx)
    , ("refusal.sweep", vRefusalSweep ctx)
    , ("refusal.burning", vRefusalBurning ctx)
    , ("control.free-key", vControlFreeKey ctx)
    , ("control.supported-action", vControlSupported ctx)
    ]
  where
    ctx = Ctx evd ids (classifyAll evd ids)

-- ---------------------------------------------------------
-- Verification context: every body classified once
-- ---------------------------------------------------------

data Ctx = Ctx
    { ctxEvidence :: Evidence
    , ctxIdentities :: Identities
    , ctxShapes :: Map.Map String Shape
    }

classifyAll :: Evidence -> Identities -> Map.Map String Shape
classifyAll evd ids =
    Map.map (classifyBody . resolvePurposes ids (evUtxos evd)) (evBodies evd)

ctxBodies :: Ctx -> [(String, ConwayTx)]
ctxBodies = Map.toList . evBodies . ctxEvidence

bodiesOfShape :: Ctx -> Shape -> [(String, ConwayTx)]
bodiesOfShape ctx shape =
    [(tag, tx) | (tag, tx) <- ctxBodies ctx, Map.lookup tag (ctxShapes ctx) == Just shape]

evOutcome :: Ctx -> String -> Maybe Aeson.Object
evOutcome ctx tag = Map.lookup tag (evOutcomes (ctxEvidence ctx))

outcomeStatus :: Aeson.Object -> Maybe String
outcomeStatus o = case KM.lookup "outcome" o of
    Just (Aeson.String s) -> Just (T.unpack s)
    _ -> Nothing

outcomeTxid :: Aeson.Object -> Maybe String
outcomeTxid o = case KM.lookup "txid" o of
    Just (Aeson.String s) -> Just (T.unpack s)
    _ -> Nothing

outcomeReason :: Aeson.Object -> Maybe String
outcomeReason o = case KM.lookup "reason" o of
    Just (Aeson.String s) -> Just (T.unpack s)
    _ -> Nothing

-- | The accepted connected folds, first by request spelling anchor.
-- Returns (foldTag, body, requestKeyBytes).
acceptedFolds :: Ctx -> [(String, ConwayTx, ByteString)]
acceptedFolds ctx =
    [ (tag, tx, reqKey)
    | (tag, tx) <- bodiesOfShape ctx ConnectedFold
    , Just o <- [evOutcome ctx tag]
    , outcomeStatus o == Just "accepted"
    , Just reqKey <- [foldRequestKey ctx tx]
    ]

-- | The request spelling a connected fold consumes (from the request
-- datum of its Contribute input, resolved through retained listings).
foldRequestKey :: Ctx -> ConwayTx -> Maybe ByteString
foldRequestKey ctx tx = do
    let reqInputs =
            [ inp
            | RRequestSpend inp 1 <- resolvePurposes (ctxIdentities ctx) (evUtxos (ctxEvidence ctx)) tx
            ]
    case reqInputs of
        (inp : _) -> do
            out <- Map.lookup (showInShort inp) (evUtxos (ctxEvidence ctx))
            req <- outCageRequest out
            pure (requestKey req)
        _ -> Nothing

outCageRequest :: TxOut ConwayEra -> Maybe OnChainRequest
outCageRequest out = case outCageDatum out of
    Just (RequestDatum r) -> Just r
    _ -> Nothing

showInShort :: TxIn -> String
showInShort (TxIn (TxId h) (TxIx i)) =
    -- Pinned to the runner's `showIn` format: listings are keyed by it.
    hexStr (hashToBytes (extractHash h)) <> "#" <> show i

-- ---------------------------------------------------------
-- Connected obligations
-- ---------------------------------------------------------

-- | All refused connected-shape bodies with their request keys.
refusedDuplicates :: Ctx -> [(String, ConwayTx, ByteString)]
refusedDuplicates ctx =
    [ (tag, tx, reqKey)
    | (tag, tx) <- bodiesOfShape ctx ConnectedFold
    , Just o <- [evOutcome ctx tag]
    , outcomeStatus o == Just "refused"
    , Just reqKey <- [foldRequestKey ctx tx]
    ]

foldActiveBody :: Ctx -> Maybe (String, ConwayTx, ByteString)
foldActiveBody ctx = case (refusedDuplicates ctx, acceptedFolds ctx) of
    ((_, _, dupKey) : _, folds) ->
        case [f | f@(_, _, k) <- folds, k == dupKey] of
            (f : _) -> Just f
            _ -> Nothing
    _ -> Nothing

vConnectedTxid :: Ctx -> Verdict
vConnectedTxid ctx = case foldActiveBody ctx of
    Nothing -> cne "no anchored fold-active body"
    Just (tag, tx, _) -> case evOutcome ctx tag of
        Nothing -> cne ("no outcome retained for " <> tag)
        Just o -> case (outcomeStatus o, outcomeTxid o) of
            (Just "accepted", Just claimed) ->
                let recomputed = txIdHexTx tx
                 in if recomputed == claimed
                        then established ("txid recomputed from body == submitted " <> claimed)
                        else refuted ("txid mismatch: body hashes to " <> recomputed <> " but submission reported " <> claimed)
            _ -> cne ("fold-active outcome is not an accepted txid: " <> tag)

txIdHexTx :: ConwayTx -> String
txIdHexTx tx = let TxId h = txIdTx tx in hexStr (hashToBytes (extractHash h))

vConnectedStateInput :: Ctx -> Verdict
vConnectedStateInput ctx = case foldActiveBody ctx of
    Nothing -> cne "no anchored fold-active body"
    Just (_tag, tx, _) ->
        let ids = ctxIdentities ctx
            stateIns =
                [ inp
                | RStateSpend inp 2 <- resolvePurposes ids (evUtxos (ctxEvidence ctx)) tx
                ]
         in case stateIns of
                [inp] -> case Map.lookup (showInShort inp) (evUtxos (ctxEvidence ctx)) of
                    Just out -> case outCageDatum out of
                        Just (StateDatum _) ->
                            established ("fold consumes the state UTxO " <> showInShort inp <> " carrying a StateDatum")
                        _ -> refuted ("fold state input carries no StateDatum: " <> showInShort inp)
                    Nothing -> cne ("state input UTxO not retained: " <> showInShort inp)
                _ -> refuted "fold does not consume exactly one state input with Modify"

vConnectedRequestInput :: Ctx -> Verdict
vConnectedRequestInput ctx = case foldActiveBody ctx of
    Nothing -> cne "no anchored fold-active body"
    Just (_tag, tx, _) ->
        let ids = ctxIdentities ctx
            reqIns =
                [ inp
                | RRequestSpend inp 1 <- resolvePurposes ids (evUtxos (ctxEvidence ctx)) tx
                ]
         in case reqIns of
                [inp] -> case Map.lookup (showInShort inp) (evUtxos (ctxEvidence ctx)) of
                    Just out -> case outCageDatum out of
                        Just (RequestDatum _) ->
                            established ("fold consumes the request UTxO " <> showInShort inp <> " carrying a RequestDatum")
                        _ -> refuted ("fold request input carries no RequestDatum: " <> showInShort inp)
                    Nothing -> cne ("request input UTxO not retained: " <> showInShort inp)
                _ -> refuted "fold does not consume exactly one request input with Contribute"

vConnectedContinuation :: Ctx -> Verdict
vConnectedContinuation ctx = case foldActiveBody ctx of
    Nothing -> cne "no anchored fold-active body"
    Just (_tag, tx, _) -> case txOutputs tx of
        (out : _) -> case outCageDatum out of
            Just (StateDatum _) ->
                established "continuing output of this transaction carries the new StateDatum"
            _ -> refuted "continuing output of this transaction carries no StateDatum"
        _ -> refuted "fold transaction has no outputs"

vConnectedRootBefore :: Ctx -> Verdict
vConnectedRootBefore ctx = case foldActiveBody ctx of
    Nothing -> cne "no anchored fold-active body"
    Just (_tag, tx, _) ->
        let ids = ctxIdentities ctx
         in case [inp | RStateSpend inp 2 <- resolvePurposes ids (evUtxos (ctxEvidence ctx)) tx] of
                [inp] -> case Map.lookup (showInShort inp) (evUtxos (ctxEvidence ctx)) >>= outCageDatum of
                    Just (StateDatum st) ->
                        let OnChainRoot bs = stateRoot st
                         in established ("root-before decoded from the consumed state UTxO: " <> hexStr bs)
                    _ -> cne "consumed state datum does not decode"
                _ -> cne "no single state input"

vConnectedRootAfter :: Ctx -> Verdict
vConnectedRootAfter ctx = case foldActiveBody ctx of
    Nothing -> cne "no anchored fold-active body"
    Just (_tag, tx, _) -> case (rootOfConsumed ctx tx, rootOfContinuation tx) of
        (Just before, Just after)
            | before /= after ->
                established ("root-after decoded from this transaction's continuing output, differs: " <> after)
            | otherwise -> refuted "root-after equals root-before: the fold did not move the root"
        _ -> cne "roots do not both decode"
  where
    rootOfConsumed c t = case vConnectedRootBefore' c t of
        Just r -> Just r
        Nothing -> Nothing
    rootOfContinuation t = case txOutputs t of
        (out : _) -> case outCageDatum out of
            Just (StateDatum st) ->
                let OnChainRoot bs = stateRoot st
                 in Just (hexStr bs)
            _ -> Nothing
        _ -> Nothing

vConnectedRootBefore' :: Ctx -> ConwayTx -> Maybe String
vConnectedRootBefore' ctx tx =
    let ids = ctxIdentities ctx
     in case [inp | RStateSpend inp 2 <- resolvePurposes ids (evUtxos (ctxEvidence ctx)) tx] of
            [inp] -> case Map.lookup (showInShort inp) (evUtxos (ctxEvidence ctx)) >>= outCageDatum of
                Just (StateDatum st) ->
                    let OnChainRoot bs = stateRoot st
                     in Just (hexStr bs)
                _ -> Nothing
            _ -> Nothing

-- ---------------------------------------------------------
-- Representative obligations
-- ---------------------------------------------------------

-- | The naming claim a connected fold consumes: the input at the
-- application address carrying the single approval-shaped asset.
foldClaim :: Ctx -> ConwayTx -> Maybe (TxIn, TxOut ConwayEra, NamingDatum, ByteString)
foldClaim ctx tx = do
    let ids = ctxIdentities ctx
        appIns =
            [ inp
            | RAppSpend inp 2 <- resolvePurposes ids (evUtxos (ctxEvidence ctx)) tx
            ]
    case appIns of
        [inp] -> do
            out <- Map.lookup (showInShort inp) (evUtxos (ctxEvidence ctx))
            datum <- outNamingDatum out
            approval <- singleApproval out
            pure (inp, out, datum, approval)
        _ -> Nothing
  where
    singleApproval out = case out ^. valueTxOutL of
        MaryValue _ (MultiAsset ma) -> case
            [(n, q) | (_, ns) <- Map.toList ma, (AssetName n, q) <- Map.toList ns, q /= 0]
            of
            [(n, _)] -> Just (SBS.fromShort n)
            _ -> Nothing

vRepresentativeApplied :: Ctx -> Verdict
vRepresentativeApplied ctx = case foldActiveBody ctx of
    Nothing -> cne "no anchored fold-active body"
    Just (_tag, tx, _) ->
        let ids = ctxIdentities ctx
            minted = [(p, n, q) | (p, n, q) <- txMint tx]
            repMints = [(n, q) | (p, n, q) <- minted, hexStr (policyBytes p) == idRepAppliedHex ids]
         in if idRepAppliedHex ids == idRepUnappliedHex ids
                then refuted "applied identity equals the unapplied hash: the parameter was never applied"
                else case repMints of
                    [(_, 1)] ->
                        established
                            ("mint policy recomputed by applying the bound parameter: " <> idRepAppliedHex ids)
                    _ ->
                        refuted
                            ("no +1 mint under the derived applied policy " <> idRepAppliedHex ids <> ": " <> show minted)
  where
    policyBytes (PolicyID sh) = scriptHashBytes sh

vRepresentativeAsset :: Ctx -> Verdict
vRepresentativeAsset ctx = case foldActiveBody ctx of
    Nothing -> cne "no anchored fold-active body"
    Just (_tag, tx, _) -> case expectedRepName ctx tx of
        Nothing -> cne "expected representative name does not recompute"
        Just expected ->
            let ids = ctxIdentities ctx
                minted =
                    [ (n, q)
                    | (p, n, q) <- txMint tx
                    , hexStr (policyBytes p) == idRepAppliedHex ids
                    ]
             in case minted of
                    [(name, 1)]
                        | name == expected ->
                            established ("representative asset bytes and net +1 under the exact policy: " <> hexStr expected)
                        | otherwise ->
                            refuted ("minted name is not the derived name: minted " <> hexStr name <> " vs derived " <> hexStr expected)
                    _ -> refuted "mint under the applied policy is not exactly one asset at +1"
  where
    policyBytes (PolicyID sh) = scriptHashBytes sh

-- | The expected representative name, re-derived from the observed
-- claim datum: control address to key hash, incarnation 0x00.
expectedRepName :: Ctx -> ConwayTx -> Maybe ByteString
expectedRepName ctx tx = do
    (_, _, datum, _) <- foldClaim ctx tx
    shape <- decodeAddress (addressBytes (controlAddress datum))
    pure (representativeName (addressPaymentHash shape) freshIncarnation)

vRepresentativeApproval :: Ctx -> Verdict
vRepresentativeApproval ctx = case foldActiveBody ctx of
    Nothing -> cne "no anchored fold-active body"
    Just (_tag, tx, _) -> case foldClaim ctx tx of
        Nothing -> cne "fold claim does not resolve"
        Just (_, _, datum, approval) ->
            let expected = insertApprovalName (addressBytes (controlAddress datum)) (nextControlCommitment datum)
                burned =
                    [ n
                    | (p, n, q) <- txMint tx
                    , hexStr (policyBytes p) == idAppHex (ctxIdentities ctx)
                    , q == -1
                    ]
             in if approval /= expected
                    then refuted "queued claim does not carry the bound insert approval"
                    else case burned of
                        [name]
                            | name == expected ->
                                established "insert approval consumed: bound at queue, burned at fold"
                            | otherwise -> refuted "burned approval is not the bound one"
                        _ -> refuted "no single -1 approval burn under the application policy"
  where
    policyBytes (PolicyID sh) = scriptHashBytes sh

vRepresentativeKey :: Ctx -> Verdict
vRepresentativeKey ctx = case foldActiveBody ctx of
    Nothing -> cne "no anchored fold-active body"
    Just (_tag, tx, _) -> case (foldRequestKey ctx tx, expectedRepName ctx tx) of
        (Just spelling, Just rep) -> case BS.unsnoc rep of
            Just (prefixKey, incarnation)
                | BS.length rep == 32
                , BS.take 3 rep == representativePrefix
                , incarnation == freshIncarnation ->
                    established
                        ( "key/incarnation agreement recomputed in-tx: request key "
                            <> show spelling
                            <> " co-consumed with the claim whose control determines "
                            <> hexStr (BS.drop 3 prefixKey)
                            <> " at incarnation 0x00. Residue (NOTE-011): the spelling-to-control binding beyond same-tx co-consumption is Lean's external spellingKey table, not re-derivable here."
                        )
            _ -> refuted "representative name is not Rep||keyHash||0x00"
        _ -> cne "request key or expected name does not recompute"

-- ---------------------------------------------------------
-- Refusal obligations (attribution binds rejection text to blueprint)
-- ---------------------------------------------------------

-- | A refused body of the given shape whose node reason attributes to
-- the expected script. Structural checks corroborate; without the
-- attribution the verdict is COULD-NOT-EVALUATE (NOTE-011).
refusedAttributed :: Ctx -> Shape -> String -> String -> Maybe Verdict
refusedAttributed ctx shape operation expectedHex = do
    let candidates =
            [ (tag, tx)
            | (tag, tx) <- bodiesOfShape ctx shape
            , Just o <- [evOutcome ctx tag]
            , outcomeStatus o == Just "refused"
            ]
    case candidates of
        [] -> Just (cne ("no refused " <> operation <> " body retained"))
        ((tag, tx) : _) -> case evOutcome ctx tag >>= outcomeReason of
            Nothing -> Just (cne (operation <> ": refusal reason not retained"))
            Just reason
                | "PlutusFailure" `isInfixOf` reason
                , expectedHex `isInfixOf` reason ->
                    Just
                        ( established
                            ( operation
                                <> " refused by "
                                <> expectedHex
                                <> " as "
                                <> txIdHexTx tx
                            )
                        )
                | "PlutusFailure" `isInfixOf` reason ->
                    Just (cne (operation <> ": refusal does not name " <> expectedHex))
                | otherwise -> Just (refuted (operation <> ": refused without phase-2 evidence"))

-- | The request validator hash for this run's token: the boot mint
-- names the token under the state policy; applying the bound parameters
-- (state policy id, token name) to the compiled request program gives
-- the applied identity the Sweep spend resolves through.
requestAppliedHex :: Ctx -> Maybe String
requestAppliedHex ctx = do
    (_, bootTx) <- findBoot ctx
    (policyId, name, qty) <- findMint bootTx
    if hexStr (policyBytes policyId) /= idStateHex (ctxIdentities ctx) || qty /= 1
        then Nothing
        else Just (hexStr (requestHashFor ctx name))
  where
    policyBytes (PolicyID sh) = scriptHashBytes sh
    findBoot c =
        let boots =
                [ (tag, tx)
                | (tag, tx) <- ctxBodies c
                , Just o <- [evOutcome c tag]
                , outcomeStatus o == Just "accepted"
                , isBootShape tx
                ]
         in case boots of
                (b : _) -> Just b
                _ -> Nothing
    isBootShape tx = case txMint tx of
        [(_, _, 1)] -> null [() | PSpend _ _ <- txPurposes tx]
        _ -> False
    findMint tx = case txMint tx of
        [(p, n, q)] -> Just (p, n, q)
        _ -> Nothing

requestHashFor :: Ctx -> ByteString -> ByteString
requestHashFor ctx name = scriptHashBytes (computeScriptHash applied)
  where
    applied =
        applyRequestParams
            statePolicyBytes
            (onChainTokenId (TokenId (AssetName (SBS.toShort name))))
            (idReqCode (ctxIdentities ctx))
    statePolicyBytes = idStateHash (ctxIdentities ctx)

vRefusalInsert :: Ctx -> Verdict
vRefusalInsert ctx = case refusedDuplicates ctx of
    [] -> cne "no refused duplicate body retained"
    ((tag, tx, dupKey) : _) -> case evOutcome ctx tag >>= outcomeReason of
        Nothing -> cne "insert: refusal reason not retained"
        Just reason
            | "PlutusFailure" `isInfixOf` reason
            , idStateHex (ctxIdentities ctx) `isInfixOf` reason ->
                case acceptedFolds ctx of
                    folds
                        | any (\(_, _, k) -> k == dupKey) folds ->
                            established
                                ("insert refused by the state validator for the taken spelling; duplicate shape matches the accepted fold's key as "
                                    <> txIdHexTx tx
                                )
                        | otherwise -> refuted "duplicate key matches no accepted fold"
            | "PlutusFailure" `isInfixOf` reason ->
                cne "insert: refusal does not name the state validator"
            | otherwise -> refuted "insert: refused without phase-2 evidence"

vRefusalEnd :: Ctx -> Verdict
vRefusalEnd ctx =
    fromMaybe
        (cne "no refused End body retained")
        (refusedAttributed ctx EndAttempt "end" (idStateHex (ctxIdentities ctx)))

vRefusalMigration :: Ctx -> Verdict
vRefusalMigration ctx =
    fromMaybe
        (cne "no refused Migrating body retained")
        (refusedAttributed ctx MigratingMint "migration" (idStateHex (ctxIdentities ctx)))

vRefusalBurning :: Ctx -> Verdict
vRefusalBurning ctx =
    fromMaybe
        (cne "no refused Burning body retained")
        (refusedAttributed ctx BurningMint "burning" (idStateHex (ctxIdentities ctx)))

vRefusalSweep :: Ctx -> Verdict
vRefusalSweep ctx = case requestAppliedHex ctx of
    Nothing -> cne "request applied identity does not recompute"
    Just reqHex ->
        fromMaybe
            (cne "no refused Sweep body retained")
            (refusedAttributed ctx SweepSpend "sweep" reqHex)

-- ---------------------------------------------------------
-- Control obligations
-- ---------------------------------------------------------

vControlFreeKey :: Ctx -> Verdict
vControlFreeKey ctx = case (refusedDuplicates ctx, acceptedFolds ctx) of
    ((_, dupTx, dupKey) : _, folds) ->
        case [f | f@(_, _, k) <- folds, k /= dupKey] of
            ((tag, tx, k) : _) ->
                let dupReqs = requestInputsOf ctx dupTx
                    txReqs = requestInputsOf ctx tx
                    dupClaims = claimInputsOf ctx dupTx
                    txClaims = claimInputsOf ctx tx
                 in if k /= dupKey && txReqs /= dupReqs && txClaims /= dupClaims
                        then case evOutcome ctx tag >>= outcomeTxid of
                            Just claimed
                                | claimed == txIdHexTx tx ->
                                    established
                                        ("free key accepted: spelling "
                                            <> show k
                                            <> " vs taken "
                                            <> show dupKey
                                            <> ", distinct request and claim inputs (the shared state input is expected: the refused duplicate consumed nothing)"
                                        )
                            _ -> cne "free-key txid does not recompute"
                        else refuted "free-key name inputs do not genuinely differ"
            _ -> cne "no accepted fold with a different key"
    _ -> cne "no refused duplicate to control against"
  where
    requestInputsOf c t =
        [inp | RRequestSpend inp 1 <- resolvePurposes (ctxIdentities c) (evUtxos (ctxEvidence c)) t]
    claimInputsOf c t =
        [inp | RAppSpend inp 2 <- resolvePurposes (ctxIdentities c) (evUtxos (ctxEvidence c)) t]

vControlSupported :: Ctx -> Verdict
vControlSupported ctx =
    let producers = producerIndex ctx
        foldOk = case
            [ tx
            | (tag, tx) <- bodiesOfShape ctx MpfsFold
            , isAccepted tag
            , foldRequestProduced producers tx
            ] of
            (tx : _) -> Just (("fold" :: String), txIdHexTx tx)
            _ -> Nothing
        requestOk = case
            [ (tag, tx)
            | (tag, tx) <- ctxBodies ctx
            , isAccepted tag
            , isRequestSubmission tx
            ] of
            ((_, tx) : _) -> Just ((("request" :: String)), txIdHexTx tx)
            _ -> Nothing
        retractOk = case
            [ tx
            | (tag, tx) <- ctxBodies ctx
            , isAccepted tag
            , Just _ <- [retractedRequest producers tx]
            ] of
            (tx : _) -> Just ((("retract" :: String)), txIdHexTx tx)
            _ -> Nothing
     in case (foldOk, requestOk, retractOk) of
            (Just _, Just _, Just _) ->
                established "supported fold, request and retraction each accepted; the fold consumes a submitted request and the retract consumes the submitted aged request"
            _ ->
                cne
                    ( "supported actions incomplete: fold=" <> show (fst <$> foldOk)
                        <> " request="
                        <> show (fst <$> requestOk)
                        <> " retract="
                        <> show (fst <$> retractOk)
                    )
  where
    isAccepted tag = case evOutcome ctx tag of
        Just o -> outcomeStatus o == Just "accepted"
        _ -> False
    -- outref -> (producing txid, accepted?) over every retained body.
    producerIndex c =
        Map.fromList
            [ (outrefOf tx ix, (txIdHexTx tx, isAccepted tag))
            | (tag, tx) <- ctxBodies c
            , (ix, _) <- zip [0 :: Int ..] (txOutputs tx)
            ]
    outrefOf tx ix =
        let TxId h = txIdTx tx
         in hexStr (hashToBytes (extractHash h)) <> "#" <> show ix
    -- The fold's request input was produced by an accepted submission.
    foldRequestProduced producers tx =
        not (null reqIns)
            && all producedAccepted reqIns
      where
        reqIns = [inp | RRequestSpend inp 1 <- resolved tx]
        resolved t = resolvePurposes (ctxIdentities ctx) (evUtxos (ctxEvidence ctx)) t
        producedAccepted inp = case Map.lookup (showInShort inp) producers of
            Just (_, True) -> True
            _ -> False
    isRequestSubmission t =
        null (txPurposes t) && any createsRequest (txOutputs t)
    createsRequest out = case outCageRequest out of
        Just _ -> True
        _ -> case addrCredentialHex out of
            Just h -> h == fromMaybe "" (requestAppliedHex ctx)
            _ -> False
    retractedRequest producers tx =
        case [inp | RRequestSpend inp 3 <- resolvePurposes (ctxIdentities ctx) (evUtxos (ctxEvidence ctx)) tx] of
            [inp] -> case Map.lookup (showInShort inp) producers of
                Just (_, True) -> Just inp
                _ -> Nothing
            _ -> Nothing
