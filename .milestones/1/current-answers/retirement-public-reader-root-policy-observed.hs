{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Main (retirement-verify)
Description : Independent reader for retirement creation evidence
License     : Apache-2.0

Verifies recovery/controller/quorum retirements from DURABLE PUBLIC
artifacts only — retained transaction CBOR plus public log lines —
without the old signing key and without runner setup constants.
See the module header in the previous revision for the full design;
the rules, briefly:

- creation control: claim-tx datum bytes (outref-chased), never env;
- retire key: retire-tx redeemer bytes (strict Retire shape);
- registry token: request-tx datum bytes;
- state policy: state output's own address bytes;
- rep: recomputed with the library formula, checked against custody
  output bytes and the log;
- rotation: creation/recover/retire linked by body outrefs; route
  signers checked against datum-derived control/quorum.

Exit 0 with VERIFIED lines, non-zero with the first mismatch.
-}
module Main (main) where

import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Short qualified as SBS
import Data.Char (isHexDigit)
import Data.List (isPrefixOf, tails)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import System.Directory (listDirectory)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.Scripts.Data (Data (..), Datum (..), binaryDataToData)
import Cardano.Ledger.Api.Tx (
    bodyTxL,
    txIdTx,
    witsTxL,
 )
import Cardano.Ledger.Api.Tx.Body (
    inputsTxBodyL,
    outputsTxBodyL,
    reqSignerHashesTxBodyL,
 )
import Cardano.Ledger.Api.Tx.In (TxIn (..))
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    datumTxOutL,
    valueTxOutL,
 )
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes (Network (..), TxIx (..))
import Cardano.Ledger.Binary (
    decodeFullAnnotatorFromHexText,
    decCBOR,
    natVersion,
 )
import Cardano.Ledger.Core (extractHash)
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Hashes (unKeyHash)
import Cardano.Ledger.Keys (KeyHash (..))
import Cardano.Ledger.Mary.Value (
    MaryValue (..),
    MultiAsset (..),
 )
import Cardano.Ledger.TxIn (TxId (..))
import Data.Aeson (FromJSON (..), eitherDecode', withObject, (.:))
import qualified Data.ByteString.Lazy as BSL
import Data.Foldable (toList)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((^.))
import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins.Internal (BuiltinByteString (..))

import Cardano.MPFS.Cage.Ledger (AssetName (..), ConwayEra)
import Cardano.MPFS.Cage.TxBuilder.Internal (
    extractCageDatum,
    pinScriptHash,
    scriptHashBytes,
 )
import Cardano.MPFS.Cage.Types (
    CageDatum (..),
    OnChainOperation (..),
    OnChainRequest (..),
    OnChainTokenId (..),
 )
import Cardano.Tx.Ledger (ConwayTx)
import Naming.Datum (
    NamingDatum (..),
    RetirementQuorum (..),
    decodeNamingDatum,
 )
import Naming.Register (representativeName)
import Naming.Wire (
    Address (..),
    PaymentCredential (..),
    WireData (..),
    addressPaymentHash,
 )

-- ---------------------------------------------------------
-- CLI
-- ---------------------------------------------------------

data Args = Args
    { argEvidenceDir :: FilePath
    , argLogFile :: FilePath
    , argNamingManifest :: FilePath
    }

parseArgs :: [String] -> IO Args
parseArgs xs = go xs (Args "" "" "")
  where
    go [] a
        | null (argEvidenceDir a)
            || null (argLogFile a)
            || null (argNamingManifest a) =
            failWith "usage: retirement-verify --evidence-dir DIR --log-file LOG --naming-manifest MANIFEST"
        | otherwise = pure a
    go ("--evidence-dir" : v : rest) a = go rest a{argEvidenceDir = v}
    go ("--log-file" : v : rest) a = go rest a{argLogFile = v}
    go ("--naming-manifest" : v : rest) a = go rest a{argNamingManifest = v}
    go (flag : _) _ = failWith ("unknown flag: " <> flag)

failWith :: String -> IO a
failWith msg = hPutStrLn stderr ("retirement-verify: " <> msg) >> exitWith (ExitFailure 1)

-- ---------------------------------------------------------
-- Small parsers (log lines, hex, manifests)
-- ---------------------------------------------------------

findAfter :: String -> String -> Maybe String
findAfter needle hay =
    case [drop (length needle) t | t <- tails hay, needle `isPrefixOf` t] of
        (r : _) -> Just r
        [] -> Nothing

hexBytes :: String -> Maybe ByteString
hexBytes s = case Base16.decode (TE.encodeUtf8 (T.pack s)) of
    Left _ -> Nothing
    Right bs -> Just bs

hexOf :: ByteString -> String
hexOf = T.unpack . TE.decodeUtf8 . Base16.encode

-- | A creation-material record parsed from one public log line.
data CreationUnit = CreationUnit
    { cuRecord :: String
    , cuCreationTx :: String
    , cuCreationHash :: ByteString
    , cuRepLog :: ByteString
    }
    deriving stock (Show)

parseCreationLine :: String -> Maybe CreationUnit
parseCreationLine line = do
    rest <- findAfter "creation-material:" line
    let kvs = take 4 (filter (elem '=') (words rest))
    case kvs of
        [rec, ctx, hsh, rep] ->
            CreationUnit
                <$> pure (snd (splitKv rec))
                <*> pure (snd (splitKv ctx))
                <*> hexBytes (strip0x (snd (splitKv hsh)))
                <*> hexBytes (strip0x (snd (splitKv rep)))
        _ -> Nothing
  where
    splitKv t = case break (== '=') t of
        (k, '=' : v) -> (k, v)
        (k, _) -> (k, "")
    strip0x s = case s of
        '0' : 'x' : r -> r
        _ -> s

data ManifestPin = ManifestPin
    { mpTitle :: T.Text
    , mpHash :: T.Text
    }

newtype PinManifest = PinManifest {manifestValidators :: [ManifestPin]}

instance FromJSON PinManifest where
    parseJSON = withObject "PinManifest" $ \o -> PinManifest <$> o .: "validators"

instance FromJSON ManifestPin where
    parseJSON = withObject "ManifestPin" $ \o -> ManifestPin <$> o .: "title" <*> o .: "hash"

pinUnder :: PinManifest -> String -> IO ByteString
pinUnder manifest prefix =
    case [mpHash p | p <- manifestValidators manifest, T.pack prefix `T.isPrefixOf` mpTitle p] of
        [] -> failWith ("manifest: no pin under " <> prefix)
        (h : _) -> case hexBytes (T.unpack h) of
            Just bs | BS.length bs == 28 -> pure bs
            _ -> failWith ("manifest: bad pin bytes under " <> prefix)

readManifest :: FilePath -> IO PinManifest
readManifest path = do
    bytes <- BSL.readFile path
    case eitherDecode' bytes of
        Left err -> failWith ("manifest parse: " <> err)
        Right m -> pure m

-- ---------------------------------------------------------
-- Transaction bodies from retained hex
-- ---------------------------------------------------------

decodeTxFile :: FilePath -> IO ConwayTx
decodeTxFile path = do
    content <- readFile path
    let hexText = T.pack (filter isHexDigit content)
    case decodeFullAnnotatorFromHexText (natVersion @11) "Conway transaction" decCBOR hexText of
        Left err -> failWith (path <> ": tx decode failed: " <> show err)
        Right tx -> pure tx

txIdHexOf :: ConwayTx -> String
txIdHexOf tx = case txIdTx tx of
    TxId h -> hexOf (hashToBytes (extractHash h))

txInputs :: ConwayTx -> [TxIn]
txInputs tx = toList (tx ^. bodyTxL . inputsTxBodyL)

txOutputs :: ConwayTx -> [TxOut ConwayEra]
txOutputs tx = toList (tx ^. bodyTxL . outputsTxBodyL)

txRedeemerDatas :: ConwayTx -> [PLC.Data]
txRedeemerDatas tx = case tx ^. witsTxL . rdmrsTxWitsL of
    Redeemers m -> [d | (Data d, _) <- Map.elems m]

txSignatories :: ConwayTx -> [ByteString]
txSignatories tx =
    [hashToBytes (unKeyHash kh) | kh <- toList (tx ^. bodyTxL . reqSignerHashesTxBodyL)]

-- ---------------------------------------------------------
-- Datum readers over decoded bodies
-- ---------------------------------------------------------

datumDataOfTxOut :: TxOut ConwayEra -> Maybe PLC.Data
datumDataOfTxOut out = case out ^. datumTxOutL of
    Datum bd -> let Data d = binaryDataToData bd in Just d
    _ -> Nothing

wireOf :: PLC.Data -> Maybe WireData
wireOf (PLC.Constr i fs)
    | i >= 0 && i <= 6 = Constr (fromIntegral i) <$> traverse wireOf fs
    | otherwise = Nothing
wireOf (PLC.B b) = Just (WBytes b)
wireOf _ = Nothing

namingDatumOfTxOut :: TxOut ConwayEra -> Maybe NamingDatum
namingDatumOfTxOut out = datumDataOfTxOut out >>= wireOf >>= decodeNamingDatum

data OutRef = OutRef
    { outRefTx :: String
    , outRefIx :: Int
    }
    deriving stock (Eq, Show)

parseOutRef :: String -> Maybe OutRef
parseOutRef s = case break (== '#') (reverse s) of
    (revIx, '#' : revTx) -> case reads (reverse revIx) of
        [(ix, "")] -> Just (OutRef (reverse revTx) ix)
        _ -> Nothing
    _ -> Nothing

txInOutRef :: TxIn -> OutRef
txInOutRef (TxIn (TxId h) (TxIx i)) =
    OutRef (hexOf (hashToBytes (extractHash h))) (fromIntegral i)

-- ---------------------------------------------------------
-- Main verification
-- ---------------------------------------------------------

main :: IO ()
main = do
    args <- parseArgs =<< getArgs
    logText <- readFile (argLogFile args)
    let creations = mapMaybe parseCreationLine (lines logText)
    when (null creations) $
        failWith "no creation-material lines in log"
    files <- listDirectory (argEvidenceDir args)
    let hexFiles =
            [ argEvidenceDir args </> f
            | f <- files
            , ".cborhex" `isSuffixOf` f
            ]
    txs <- mapM (\p -> (,) <$> pure p <*> decodeTxFile p) hexFiles
    index <-
        fmap Map.fromList $
            mapM
                (\(p, tx) -> pure (txIdHexOf tx, (p, tx)))
                txs
    namingManifest <- readManifest (argNamingManifest args)
    custodyHash <- pinUnder namingManifest "retirement_custody"
    let acceptedTxids =
            [ txid
            | line <- lines logText
            , "accepted tx=" `isInfixOf` line
            , txid <- maybeToList (extractAcceptedTx line)
            ]
    mapM_ (verifyUnit index custodyHash acceptedTxids) creations
    putStrLn
        ( "VERIFIED "
            <> show (length creations)
            <> " retirement units from public evidence (no keys, no setup constants)"
        )
  where
    isSuffixOf suf s = reverse suf `isPrefixOf` reverse s
    isInfixOf needle hay = any (needle `isPrefixOf`) (tails hay)
    maybeToList (Just x) = [x]
    maybeToList Nothing = []
    extractAcceptedTx line =
        case findAfter "accepted tx=" line of
            Nothing -> Nothing
            Just rest -> Just (takeWhile isHexDigit rest)

verifyUnit ::
    Map.Map String (FilePath, ConwayTx) ->
    ByteString ->
    [String] ->
    CreationUnit ->
    IO ()
verifyUnit index custodyHash acceptedTxids unit = do
    let label = cuRecord unit
    (_, creationTx) <- lookupTx index (cuCreationTx unit) "creation"
    recOut <- case parseOutRef label of
        Just o | outRefTx o == cuCreationTx unit -> pure o
        _ -> failWith (label <> ": record outref does not name the creation tx")
    claimControls <- claimControlsOf index creationTx
    claimControl <- case claimControls of
        [(c, _)] -> pure c
        _ ->
            failWith
                ( label
                    <> ": expected exactly one naming-claim input in creation tx, found "
                    <> show (length claimControls)
                )
    reqTokens <- requestTokensOf index creationTx
    tokenName <- case reqTokens of
        [] -> failWith (label <> ": no MPFS request input in creation tx")
        (t : ts) -> do
            unless (all (== t) ts) $
                failWith (label <> ": creation-tx requests disagree on token")
            pure t
    (spendTxid, _, finalRec) <- followSpendingChain index label recOut
    (retireTxid, retireTx, keyHash) <- findRetireTx index finalRec
    unless (keyHash == claimControl) $
        failWith (label <> ": retire key_hash is not the claim-derived creation hash")
    unless (keyHash == cuCreationHash unit) $
        failWith (label <> ": retire key_hash differs from public creation material")
    unless (claimControl == cuCreationHash unit) $
        failWith (label <> ": claim-derived control differs from public creation material")
    policyBytes <- statePolicyOf creationTx
    -- Custody rep first: its trailing incarnation byte feeds the
    -- recomputation (self-describing version byte, not key material).
    repCustody <- custodyRep retireTx custodyHash
    incarnation <- case BS.unsnoc repCustody of
        Just (_, w) -> pure w
        Nothing -> failWith (label <> ": custody rep name is empty")
    let repComputed = representativeName claimControl policyBytes tokenName incarnation
    unless (repComputed == repCustody) $
        failWith (label <> ": recomputed rep differs from custody output")
    unless (repComputed == cuRepLog unit) $
        failWith (label <> ": recomputed rep differs from public creation material")
    unless (retireTxid `elem` acceptedTxids) $
        failWith (label <> ": retire tx not recorded as accepted in log")
    unless (spendTxid `elem` acceptedTxids) $
        failWith (label <> ": spending tx not recorded as accepted in log")
    creatingDatum <- creatingRecordDatum index finalRec
    checkRouteSigners retireTx creatingDatum
    putStrLn
        ( "VERIFIED "
            <> label
            <> " retire="
            <> retireTxid
            <> " key=creation-hash rep-bound"
        )

-- ---------------------------------------------------------
-- Byte-level resolvers (every input re-derived, never trusted)
-- ---------------------------------------------------------

lookupTx ::
    Map.Map String (FilePath, ConwayTx) -> String -> String -> IO (FilePath, ConwayTx)
lookupTx index txid purpose =
    case Map.lookup txid index of
        Just found -> pure found
        Nothing -> failWith ("tx not retained: " <> txid <> " (" <> purpose <> ")")

-- | Resolve an outref to its creating output by scan.
resolveOut ::
    Map.Map String (FilePath, ConwayTx) -> OutRef -> Maybe (String, TxOut ConwayEra)
resolveOut index ref = do
    (_, ctx) <- Map.lookup (outRefTx ref) index
    let outs = txOutputs ctx
    if outRefIx ref < length outs then Just (outRefTx ref, outs !! outRefIx ref) else Nothing

-- | Creation control hash from a decoded record: payment-key
-- credentials only (script/malformed controls refuse — same rule the
-- validators enforce, read off the already-decoded fields).
controlHashOfDatum :: NamingDatum -> Maybe ByteString
controlHashOfDatum datum = case addressPaymentCredential (controlAddress datum) of
    PaymentKey ->
        let h = addressPaymentHash (controlAddress datum)
         in if BS.length h == 28 then Just h else Nothing
    _ -> Nothing

-- | The naming-claim inputs of a tx: spent outrefs resolving to outputs
-- whose datum decodes as a naming envelope. Returns
-- (control-hash, creating-tx).
claimControlsOf ::
    Map.Map String (FilePath, ConwayTx) -> ConwayTx -> IO [(ByteString, String)]
claimControlsOf index tx =
    fmap concat $
        mapM
            ( \inRef -> case resolveOut index inRef of
                Nothing -> pure []
                Just (ctid, out) -> case namingDatumOfTxOut out of
                    Just datum -> case controlHashOfDatum datum of
                        Just h -> pure [(h, ctid)]
                        Nothing -> pure []
                    Nothing -> pure []
            )
            (map txInOutRef (txInputs tx))

-- | The MPFS request token names spent by a tx.
requestTokensOf ::
    Map.Map String (FilePath, ConwayTx) -> ConwayTx -> IO [ByteString]
requestTokensOf index tx =
    fmap concat $
        mapM
            ( \inRef -> case resolveOut index inRef of
                Nothing -> pure []
                Just (_, out) -> case extractCageDatum out of
                    Just (RequestDatum req) ->
                        pure [tokenNameOf (requestToken req)]
                    _ -> pure []
            )
            (map txInOutRef (txInputs tx))
  where
    tokenNameOf (OnChainTokenId (BuiltinByteString bs)) = bs

-- | Follow Recover-shaped spends from a record outref to the final
-- record (RR units rotate once; LT units have no recover step).
-- Returns (spending-txid, spending-tx, final-record-outref).
followSpendingChain ::
    Map.Map String (FilePath, ConwayTx) ->
    String ->
    OutRef ->
    IO (String, ConwayTx, OutRef)
followSpendingChain index label ref = do
    spenders <- pure (spendingTxs index ref)
    case spenders of
        [] -> failWith (label <> ": record outref spent by no retained tx")
        [(stxid, stx)] -> case recoverContinuation stx ref of
            Just rotated -> pure (stxid, stx, rotated)
            Nothing -> pure (stxid, stx, ref)
        _ ->
            failWith
                ( label
                    <> ": record outref spent by several retained txs ("
                    <> show (length spenders)
                    <> ")"
                )

-- | Transactions (txid, tx) spending an outref with any script-spend
-- redeemer present (accepted or refused — outcomes partition later).
spendingTxs ::
    Map.Map String (FilePath, ConwayTx) -> OutRef -> [(String, ConwayTx)]
spendingTxs index ref =
    [ (ctid, tx)
    | (ctid, tx) <- Map.toList (Map.map snd index)
    , ref `elem` map txInOutRef (txInputs tx)
    , not (null (txRedeemerDatas tx))
    ]

newtype TxOutcome = TxOutcome {outcomeState :: T.Text}

instance FromJSON TxOutcome where
    parseJSON = withObject "TxOutcome" $ \o -> TxOutcome <$> o .: "outcome"

-- | Submission outcome sibling of a retained tx (same basename).
readOutcome :: FilePath -> IO String
readOutcome cborPath = do
    let outcomePath = reverse (drop 8 (reverse cborPath)) <> "outcome.json"
    bytes <- BSL.readFile outcomePath
    case eitherDecode' bytes of
        Right (TxOutcome st) -> pure (T.unpack st)
        Left err -> failWith (outcomePath <> ": outcome parse failed: " <> err)

-- | If a tx recovers the given record, return the continuation
-- record outref (the single naming-datum output).
recoverContinuation :: ConwayTx -> OutRef -> Maybe OutRef
recoverContinuation tx _ref = do
    _ <- findRecoverRedeemer tx
    let outs = txOutputs tx
        named =
            [ i
            | (i, out) <- zip [0 ..] outs
            , Just _ <- [namingDatumOfTxOut out]
            ]
    case named of
        [i] -> Just (OutRef (txIdHexOf tx) i)
        _ -> Nothing

-- | The retire tx spending a record: exactly one spender with exactly
-- one strict Retire-shaped redeemer. Returns (txid, tx, key-hash).
findRetireTx ::
    Map.Map String (FilePath, ConwayTx) -> OutRef -> IO (String, ConwayTx, ByteString)
findRetireTx index ref = do
    let spenders = spendingTxs index ref
    cands <- fmap concat $
        mapM
            ( \(ctid, tx) -> case retireKeyHashOf tx of
                Just kh -> pure [(ctid, tx, kh)]
                Nothing -> pure []
            )
            spenders
    accepted <- fmap concat $
        mapM
            (\(ctid, tx, kh) -> do
                oc <- readOutcomeOf index ctid
                pure (if oc == "accepted" then [(ctid, tx, kh)] else [])
            )
            cands
    case accepted of
        [(ctid, tx, kh)] -> pure (ctid, tx, kh)
        _ ->
            failWith
                ( "expected exactly one accepted Retire-shaped spender, found "
                    <> show (length accepted)
                    <> " ("
                    <> show (length cands)
                    <> " shaped)"
                )

-- | Outcome state of a retained tx, resolved via its cborhex path.
readOutcomeOf :: Map.Map String (FilePath, ConwayTx) -> String -> IO String
readOutcomeOf index ctid = case Map.lookup ctid index of
    Just (path, _) -> readOutcome path
    Nothing -> failWith ("tx not indexed: " <> ctid)

-- | Strict Retire redeemer: Constr 3 [List _, B keyHash], exactly one
-- per tx (fail otherwise — ambiguous invocations prove nothing).
retireKeyHashOf :: ConwayTx -> Maybe ByteString
retireKeyHashOf tx = case mapMaybe matchRetire (txRedeemerDatas tx) of
    [kh] -> Just kh
    _ -> Nothing
  where
    matchRetire (PLC.Constr 3 [PLC.List _, PLC.B kh]) = Just kh
    matchRetire _ = Nothing

-- | Strict Recover redeemer marker: Constr 4 [B _, List _, B _].
findRecoverRedeemer :: ConwayTx -> Maybe ()
findRecoverRedeemer tx =
    case filter isRecover (txRedeemerDatas tx) of
        [_] -> Just ()
        _ -> Nothing
  where
    isRecover (PLC.Constr 4 [PLC.B _, PLC.List _, PLC.B _]) = True
    isRecover _ = False

-- | State policy bytes from the state output's own address (the output
-- whose datum decodes as an MPFS state; exactly one per honest tx).
statePolicyOf :: ConwayTx -> IO ByteString
statePolicyOf tx = case mapMaybe stateAddr (txOutputs tx) of
    [h] -> pure h
    xs ->
        failWith
            ("expected exactly one state output, found " <> show (length xs))
  where
    stateAddr out = case extractCageDatum out of
        Just (StateDatum _) -> case out ^. addrTxOutL of
            Addr _ (ScriptHashObj sh) _ -> Just (scriptHashBytes sh)
            _ -> Nothing
        _ -> Nothing

-- | The custody representative: the single non-ADA asset of the output
-- at the custody script address (exactly one per honest retire).
custodyRep :: ConwayTx -> ByteString -> IO ByteString
custodyRep tx custodyHash = case mapMaybe custodyAsset (txOutputs tx) of
    [(name, 1)] -> pure name
    xs ->
        failWith
            ("expected exactly one custody asset at qty 1, found " <> show (length xs))
  where
    custodyAddr = Addr Testnet (ScriptHashObj (pinScriptHash custodyHash)) StakeRefNull
    custodyAsset out = case out ^. addrTxOutL of
        addr | addr == custodyAddr -> case out ^. valueTxOutL of
            MaryValue _ (MultiAsset ma) ->
                case
                    [ (aname, qty)
                    | (_, names) <- Map.toList ma
                    , (AssetName aname, qty) <- Map.toList names
                    ] of
                    [(n, q)] -> Just (SBS.fromShort n, q)
                    _ -> Nothing
        _ -> Nothing

-- | The creating datum of a record outref (claim datum for LT units,
-- recover successor for RR units — resolved, never assumed).
creatingRecordDatum :: Map.Map String (FilePath, ConwayTx) -> OutRef -> IO NamingDatum
creatingRecordDatum index ref = case resolveOut index ref of
    Just (_, out) -> case namingDatumOfTxOut out of
        Just d -> pure d
        Nothing -> failWith "record outref has no creating naming datum"
    Nothing -> failWith "record outref has no creating tx"

-- | Route signers from bytes: singleton sets must be the record's
-- current control (controller route, rotated or not); larger sets must
-- equal the quorum members with the control absent (quorum route).
checkRouteSigners :: ConwayTx -> NamingDatum -> IO ()
checkRouteSigners tx datum = do
    control <- case controlHashOfDatum datum of
        Just h -> pure h
        Nothing -> failWith "creating datum control is not a payment key"
    let members = quorumMembers (retirementQuorum datum)
        signers = txSignatories tx
    case signers of
        [s] ->
            unless (s == control) $
                failWith "singleton signer is not the record control"
        ss -> do
            unless (length ss == length members) $
                failWith "signer set matches neither route"
            unless (all (`elem` members) ss) $
                failWith "quorum-route signer outside the quorum"
            unless (control `notElem` ss) $
                failWith "quorum route signed by the controller"
