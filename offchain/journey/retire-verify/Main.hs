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
    mintTxBodyL,
    outputsTxBodyL,
    reqSignerHashesTxBodyL,
 )
import Cardano.Ledger.Api.Tx.In (TxIn (..))
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    addrTxOutL,
    datumTxOutL,
    valueTxOutL,
 )
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), addrTxWitsL, rdmrsTxWitsL, witVKeyHash)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.BaseTypes (Network (..), TxIx (..))
import Cardano.Ledger.Binary (
    decodeFullAnnotatorFromHexText,
    decCBOR,
    natVersion,
 )
import Cardano.Ledger.Core (extractHash)
import Cardano.Ledger.Credential (Credential (..), StakeReference (..))
import Cardano.Ledger.Keys (KeyHash (..))
import Cardano.Ledger.Mary.Value (
    MaryValue (..),
    MultiAsset (..),
    PolicyID (..),
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
    OnChainRoot (..),
    OnChainTokenId (..),
    OnChainTokenState (..),
 )
import Cardano.Tx.Ledger (ConwayTx)
import Naming.Datum (
    NamingDatum (..),
    RetirementQuorum (..),
    decodeNamingDatum,
 )
import Naming.Verify (
    CompleteEvidence (..),
    RetireEvidence (..),
    positiveMintPolicy,
    verifyCompletion,
    verifyRetireEvidence,
 )
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
wireOf (PLC.I n) = Just (WInt n)
wireOf (PLC.List xs) = WList <$> traverse wireOf xs
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
    verified <- mapM (verifyUnit index custodyHash acceptedTxids) creations
    mapM_ (verifyCompletionTx index custodyHash acceptedTxids) verified
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
    IO VerifiedRetire
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
    policyBytes <- statePolicyOf creationTx
    (custodyPolicy, custodyName, custodyQty) <- custodyTriple retireTx custodyHash
    incarnation <- case BS.unsnoc custodyName of
        Just (_, w) -> pure w
        Nothing -> failWith (label <> ": custody rep name is empty")
    creatingDatum <- creatingRecordDatum index finalRec
    currentControl <- controlHashOfDatum label creatingDatum
    let evidence =
            RetireEvidence
                { reRecord = label
                , reRetireTx = retireTxid
                , reKeyHash = keyHash
                , reCreationHash = claimControl
                , reCreationHashLog = cuCreationHash unit
                , reStatePolicy = policyBytes
                , reToken = tokenName
                , reIncarnation = incarnation
                , reCreationMint = mintTriples creationTx
                , reCustodyPolicy = custodyPolicy
                , reCustodyName = custodyName
                , reCustodyQty = custodyQty
                , reRepLog = cuRepLog unit
                , reSigners = txSignatories retireTx
                , reWitnesses = txWitnesses retireTx
                , reCurrentControl = currentControl
                , reQuorum = quorumMembersOfDatum creatingDatum
                }
    case verifyRetireEvidence evidence of
        Left err -> failWith (label <> ": " <> err)
        Right () -> pure ()
    unless (retireTxid `elem` acceptedTxids) $
        failWith (label <> ": retire tx not recorded as accepted in log")
    unless (spendTxid `elem` acceptedTxids) $
        failWith (label <> ": spending tx not recorded as accepted in log")
    putStrLn
        ( "VERIFIED "
            <> label
            <> " retire="
            <> retireTxid
            <> " key=creation-hash rep-bound"
        )
    repPolicy <- case positiveMintPolicy (mintTriples creationTx) of
        Right p -> pure p
        Left err -> failWith (label <> ": " <> err)
    pure
        VerifiedRetire
            { vrLabel = label
            , vrRepPolicy = repPolicy
            , vrRepName = cuRepLog unit
            , vrRetireTxid = retireTxid
            , vrRetireTx = retireTx
            , vrControl = currentControl
            , vrQuorum = quorumMembersOfDatum creatingDatum
            }

-- | One verified retirement, threaded into completion verification.
data VerifiedRetire = VerifiedRetire
    { vrLabel :: String
    , vrRepPolicy :: ByteString
    , vrRepName :: ByteString
    , vrRetireTxid :: String
    , vrRetireTx :: ConwayTx
    , vrControl :: ByteString
    , vrQuorum :: [ByteString]
    }

-- | Verify the permissionless completion closing a verified retire:
-- the tx spending the retire's custody outref must burn exactly the
-- verified pair while folding the retire's own request in a genuine
-- singleton-`Modify` transition, with no required signer and the
-- fee owner as the sole witness outside every route. No such tx in
-- evidence states custody intact (never assumed spent).
verifyCompletionTx ::
    Map.Map String (FilePath, ConwayTx) ->
    ByteString ->
    [String] ->
    VerifiedRetire ->
    IO ()
verifyCompletionTx index custodyHash acceptedTxids vr = do
    let label = vrLabel vr
        custodyAddr = Addr Testnet (ScriptHashObj (pinScriptHash custodyHash)) StakeRefNull
        custodyOuts =
            [ OutRef (vrRetireTxid vr) i
            | (i, out) <- zip [0 ..] (txOutputs (vrRetireTx vr))
            , out ^. addrTxOutL == custodyAddr
            , carriesPair out (vrRepPolicy vr) (vrRepName vr)
            ]
    custodyOut <- case custodyOuts of
        [o] -> pure o
        _ ->
            failWith
                ( label
                    <> ": expected exactly one rep-carrying custody output in retire tx, found "
                    <> show (length custodyOuts)
                )
    let spenders =
            [ (ctid, tx)
            | (ctid, tx) <- Map.toList (Map.map snd index)
            , custodyOut `elem` map txInOutRef (txInputs tx)
            , not (null (txRedeemerDatas tx))
            ]
        -- Refused attempts (withdrawal/burn-only probes, retained as
        -- refused) spend the same custody without consuming it: only
        -- an accepted spender closes the unit.
        accepted = filter (\(ctid, _) -> ctid `elem` acceptedTxids) spenders
    case accepted of
        [] ->
            putStrLn ("COMPLETION-ABSENT " <> label <> " (no custody spend in evidence; custody intact)")
        [(ctid, tx)] -> verifyCompletionBody index label ctid tx custodyOut vr acceptedTxids
        _ ->
            failWith (label <> ": custody outref spent by several accepted txs")

-- | The completion body check (single spender resolved above).
verifyCompletionBody ::
    Map.Map String (FilePath, ConwayTx) ->
    String ->
    String ->
    ConwayTx ->
    OutRef ->
    VerifiedRetire ->
    [String] ->
    IO ()
verifyCompletionBody index label ctid tx custodyOut vr acceptedTxids = do
    (_, custodyOutTx) <- lookupTx index (outRefTx custodyOut) "custody creator"
    custodyOuts <- case outRefIx custodyOut < length (txOutputs custodyOutTx) of
        True -> pure (txOutputs custodyOutTx !! outRefIx custodyOut)
        False -> failWith (label <> ": custody outref index out of range")
    (custodyPolicy, custodyName, custodyQty) <- valueTriple label custodyOuts
    -- State spend: exactly one input resolving to a state datum;
    -- its redeemer shape gives Modify-ness plus the action count
    -- (mirroring the scripts, which count rather than interpret).
    stateIns <- fmap concat $
        mapM
            ( \inRef -> case resolveOut index inRef of
                Nothing -> pure []
                Just (_, out) -> case extractCageDatum out of
                    Just (StateDatum st) -> pure [(inRef, st)]
                    _ -> pure []
            )
            (map txInOutRef (txInputs tx))
    (stateIn, stateSt) <- case stateIns of
        [(i, s)] -> pure (i, s)
        _ ->
            failWith
                ( label
                    <> ": expected exactly one state-datum input in completion, found "
                    <> show (length stateIns)
                )
    let statePurpose = [d | (p, d) <- redeemerPurposes tx, resolvesTo tx p stateIn]
    (isModify, actionCount) <- case statePurpose of
        [PLC.Constr 2 [PLC.List as]] -> pure (True, length as)
        [_] -> pure (False, 0)
        _ ->
            failWith (label <> ": expected exactly one redeemer at the state spend")
    rootBefore <- pure (unOnChainRoot (stateRoot stateSt))
    rootAfter <- case txOutputs tx of
        (o : _) -> case extractCageDatum o of
            Just (StateDatum st) -> pure (unOnChainRoot (stateRoot st))
            _ -> failWith (label <> ": outputs[0] carries no state datum")
        [] -> failWith (label <> ": completion has no outputs")
    -- Request fold: exactly one input resolving to a request datum;
    -- co-creation ties it to the retire (same creator txid).
    reqIns <- fmap concat $
        mapM
            ( \inRef -> case resolveOut index inRef of
                Nothing -> pure []
                Just (_, out) -> case extractCageDatum out of
                    Just (RequestDatum _) -> pure [inRef]
                    _ -> pure []
            )
            (map txInOutRef (txInputs tx))
    reqIn <- case reqIns of
        [r] -> pure r
        _ ->
            failWith
                ( label
                    <> ": expected exactly one request-datum input in completion, found "
                    <> show (length reqIns)
                )
    -- Request value relation (NOTE-031): the folded Update moves
    -- the burned asset to its Over marker (decoded from the retained
    -- request datum — the value proof mirror lookup cannot give).
    (_, reqOut) <- lookupTx index (outRefTx reqIn) "folded request"
    reqOutTx <- case outRefIx reqIn < length (txOutputs reqOut) of
        True -> pure (txOutputs reqOut !! outRefIx reqIn)
        False -> failWith (label <> ": request outref index out of range")
    (reqOld, reqNew) <- case extractCageDatum reqOutTx of
        Just (RequestDatum req) -> case requestValue req of
            OpUpdate old new -> pure (old, new)
            _ -> failWith (label <> ": folded request is not an Update")
        _ -> failWith (label <> ": folded request input carries no request datum")
    -- Fee owner: every payment-key input shares one owner, and the
    -- witness set is exactly that key (fee ownership mechanics — the
    -- Q-file on the no-signature criterion states the interpretation).
    feeOwners <- fmap concat $
        mapM
            ( \inRef -> case resolveOut index inRef of
                Nothing -> failWith (label <> ": completion input does not resolve")
                Just (_, out) -> case paymentHashOfOut out of
                    Just h -> pure [h]
                    Nothing -> pure []
            )
            (map txInOutRef (txInputs tx))
    feeOwner <- case feeOwners of
        (h : t) | all (== h) t -> pure h
        _ -> failWith (label <> ": fee inputs share no single owner")
    let evidence =
            CompleteEvidence
                { ceRetireTx = vrRetireTxid vr
                , ceCompleteTx = ctid
                , ceCustodyTxid = outRefTx custodyOut
                , ceRequestTxid = outRefTx reqIn
                , ceRepPolicy = vrRepPolicy vr
                , ceRepName = vrRepName vr
                , ceCustodyPolicy = custodyPolicy
                , ceCustodyName = custodyName
                , ceCustodyQty = custodyQty
                , ceMint = mintTriples tx
                , ceBurnRedeemerOk =
                    any
                        ( \(p, d) -> case p of
                            ConwayMinting _ -> d == PLC.Constr 1 []
                            _ -> False
                        )
                        (redeemerPurposes tx)
                , ceIsModify = isModify
                , ceActionCount = actionCount
                , ceRootBefore = rootBefore
                , ceRootAfter = rootAfter
                , ceReqOld = reqOld
                , ceReqNew = reqNew
                , ceReqSigners = txSignatories tx
                , ceWitnesses = txWitnesses tx
                , ceFeeOwner = feeOwner
                , ceRouteKeys = vrControl vr : vrQuorum vr
                }
    case verifyCompletion evidence of
        Left err -> failWith (label <> ": " <> err)
        Right () -> pure ()
    unless (ctid `elem` acceptedTxids) $
        failWith (label <> ": completion tx not recorded as accepted in log")
    putStrLn
        ( "VERIFIED-COMPLETE "
            <> label
            <> " complete="
            <> ctid
            <> " burn=0x"
            <> hexOf (vrRepName vr)
            <> " root=0x"
            <> hexOf rootBefore
            <> "->0x"
            <> hexOf rootAfter
        )

-- | True iff the purpose resolves to the given input through the
-- builder's sorted-input index rule (mirrors retireKeysFor).
resolvesTo :: ConwayTx -> ConwayPlutusPurpose AsIx ConwayEra -> OutRef -> Bool
resolvesTo tx (ConwaySpending (AsIx n)) ref =
    fromIntegral n < length inputs && txInOutRef (inputs !! fromIntegral n) == ref
  where
    inputs = txInputs tx
resolvesTo _ _ _ = False

-- | True iff an output carries the pair once.
carriesPair :: TxOut ConwayEra -> ByteString -> ByteString -> Bool
carriesPair out policy name = (policy, name, 1) `elem` valueTriples out

-- | Every non-ADA asset triple of an output.
valueTriples :: TxOut ConwayEra -> [(ByteString, ByteString, Integer)]
valueTriples out = case out ^. valueTxOutL of
    MaryValue _ (MultiAsset ma) ->
        [ (scriptHashBytes psh, SBS.fromShort aname, qty)
        | (PolicyID psh, names) <- Map.toList ma
        , (AssetName aname, qty) <- Map.toList names
        ]

-- | The single-asset triple of an output's non-ADA asset.
valueTriple :: String -> TxOut ConwayEra -> IO (ByteString, ByteString, Integer)
valueTriple label out = case valueTriples out of
    [(p, n, q)] -> pure (p, n, q)
    xs -> failWith (label <> ": expected exactly one non-ADA asset, found " <> show (length xs))

-- | Payment-key hash of an output's address, if payment-key owned.
paymentHashOfOut :: TxOut ConwayEra -> Maybe ByteString
paymentHashOfOut out = case out ^. addrTxOutL of
    Addr _ (KeyHashObj pkh) _ -> Just (hashToBytes (unKeyHash pkh))
    _ -> Nothing

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

-- | Creation control hash from a decoded record (payment-key only).
controlHashOfDatum :: String -> NamingDatum -> IO ByteString
controlHashOfDatum label datum = case controlHashOfDatumMaybe datum of
    Just h -> pure h
    Nothing -> failWith (label <> ": creating datum control is not a payment key")

controlHashOfDatumMaybe :: NamingDatum -> Maybe ByteString
controlHashOfDatumMaybe datum = case addressPaymentCredential (controlAddress datum) of
    PaymentKey ->
        let h = addressPaymentHash (controlAddress datum)
         in if BS.length h == 28 then Just h else Nothing
    _ -> Nothing

quorumMembersOfDatum :: NamingDatum -> [ByteString]
quorumMembersOfDatum = quorumMembers . retirementQuorum

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
                    Just datum -> case controlHashOfDatumMaybe datum of
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

-- | If a tx recovers the given record, return the continuation
-- record outref (the single naming-datum output). The Recover
-- invocation is purpose-bound exactly like Retire: a strict
-- Recover-shaped redeemer sitting at the ConwaySpending purpose whose
-- sorted-input index resolves to the record (NOTE-027 honesty: no
-- untagged redeemer scan — an unrelated Constr 4 elsewhere in the tx
-- must not link a rotation that is not there).
recoverContinuation :: ConwayTx -> OutRef -> Maybe OutRef
recoverContinuation tx ref = do
    if recoverBoundTo tx ref then pure () else Nothing
    let outs = txOutputs tx
        named =
            [ i
            | (i, out) <- zip [0 ..] outs
            , Just _ <- [namingDatumOfTxOut out]
            ]
    case named of
        [i] -> Just (OutRef (txIdHexOf tx) i)
        _ -> Nothing

-- | Whether exactly one strict Recover marker (Constr 4
-- [B _, List _, B _]) sits at a ConwaySpending purpose whose
-- sorted-input index resolves to the outref (mirrors retireKeysFor's
-- index rule).
recoverBoundTo :: ConwayTx -> OutRef -> Bool
recoverBoundTo tx ref =
    case [() | (purpose, dat) <- redeemerPurposes tx, isBound purpose dat] of
        [_] -> True
        _ -> False
  where
    inputs = txInputs tx
    isBound (ConwaySpending (AsIx n)) d =
        fromIntegral n < length inputs
            && txInOutRef (inputs !! fromIntegral n) == ref
            && isRecover d
    isBound _ _ = False
    isRecover (PLC.Constr 4 [PLC.B _, PLC.List _, PLC.B _]) = True
    isRecover _ = False

-- | The retire tx spending a record: purpose-bound Retire invocation.
-- Every ConwaySpending purpose carrying a strict Retire-shaped
-- redeemer resolves through the builder's own index rule (sorted
-- inputs, mirroring spendingIndex) and must land on the record;
-- exactly one such invocation per tx, exactly one retire tx per
-- record across the evidence (refused replays share the shape but
-- carry no acceptance — see the log cross-check in verifyUnit).
-- Returns (txid, tx, key-hash).
findRetireTx ::
    Map.Map String (FilePath, ConwayTx) -> OutRef -> IO (String, ConwayTx, ByteString)
findRetireTx index ref = do
    let spenders = spendingTxs index ref
    bound <- fmap concat $
        mapM
            (\(ctid, tx) -> pure [(ctid, tx, kh) | kh <- retireKeysFor tx ref])
            spenders
    case bound of
        [(ctid, tx, kh)] -> pure (ctid, tx, kh)
        _ ->
            failWith
                ( "expected exactly one purpose-bound Retire invocation, found "
                    <> show (length bound)
                )

-- | Strict Retire key hashes bound to an outref: redeemer Datas of
-- shape Constr 3 [List _, B keyHash] sitting at spending purposes
-- whose sorted-input index resolves to the outref.
retireKeysFor :: ConwayTx -> OutRef -> [ByteString]
retireKeysFor tx ref =
    [ kh
    | (purpose, dat) <- redeemerPurposes tx
    , kh <- purposeKey purpose dat
    ]
  where
    inputs = txInputs tx
    purposeKey (ConwaySpending (AsIx n)) d =
        if fromIntegral n < length inputs && txInOutRef (inputs !! fromIntegral n) == ref
            then matchRetire d
            else []
    purposeKey _ _ = []
    matchRetire (PLC.Constr 3 [PLC.List _, PLC.B kh]) = [kh]
    matchRetire _ = []

redeemerPurposes :: ConwayTx -> [(ConwayPlutusPurpose AsIx ConwayEra, PLC.Data)]
redeemerPurposes tx = case tx ^. witsTxL . rdmrsTxWitsL of
    Redeemers m ->
        [(p, d) | (p, (Data d, _)) <- Map.toList m]

-- | Mint triples of a tx: (policy, name, quantity) across all mint
-- policies, in map order.
mintTriples :: ConwayTx -> [(ByteString, ByteString, Integer)]
mintTriples tx = case tx ^. bodyTxL . mintTxBodyL of
    MultiAsset ma ->
        [ (policyIdBytes pid, assetNameRaw name, qty)
        | (pid, names) <- Map.toList ma
        , (name, qty) <- Map.toList names
        ]
  where
    policyIdBytes (PolicyID sh) = scriptHashBytes sh
    assetNameRaw (AssetName sbs) = SBS.fromShort sbs

-- | Actual key-witness bytes present in a tx (not merely declared
-- signatories): every expected signer must appear here.
txWitnesses :: ConwayTx -> [ByteString]
txWitnesses tx =
    [hashToBytes (unKeyHash (witVKeyHash w)) | w <- toList (tx ^. witsTxL . addrTxWitsL)]

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

-- | The custody triple: (policy, name, quantity) of the single asset
-- at the custody script address (exactly one asset per honest retire;
-- policy bound by the caller, never assumed here).
custodyTriple :: ConwayTx -> ByteString -> IO (ByteString, ByteString, Integer)
custodyTriple tx custodyHash = case mapMaybe custodyAsset (txOutputs tx) of
    [(p, n, q)] -> pure (p, n, q)
    xs ->
        failWith
            ("expected exactly one custody asset, found " <> show (length xs))
  where
    custodyAddr = Addr Testnet (ScriptHashObj (pinScriptHash custodyHash)) StakeRefNull
    custodyAsset out = case out ^. addrTxOutL of
        addr | addr == custodyAddr -> case out ^. valueTxOutL of
            MaryValue _ (MultiAsset ma) ->
                case
                    [ (scriptHashBytes psh, SBS.fromShort aname, qty)
                    | (PolicyID psh, names) <- Map.toList ma
                    , (AssetName aname, qty) <- Map.toList names
                    ] of
                    [(p, n, q)] -> Just (p, n, q)
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
