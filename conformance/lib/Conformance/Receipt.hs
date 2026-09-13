{- |
Module      : Conformance.Receipt
Description : Run receipts: the only way a row becomes executed
License     : Apache-2.0

A receipt is written by a @run@ that actually executed a row,
recording the row id, the outcome, the transaction ids the chain
accepted or the refusal attribution, the measured execution units
and size, the base commit, and the node and blueprint identities.
@list@ prints a row as executed iff a receipt for it exists and its
base matches the current tree; otherwise it prints the declared
plan. Receipts live under the run's own output directory — never in
the tracked tree — and @list@ takes the directory as @--receipts@
or @CONFORMANCE_RECEIPTS@, defaulting to none.

Two venues need no node. CS01 checks Haskell encodings against the
compiled blueprint's declared schemas read at run time
(@blueprint-check@); CS06 checks parameter application in Haskell
(@param-check@). Both record @mem@/@cpu@ zero — no script executed
— and @txSize@ the measured serialized bytes, with no transactions.
Every other accepted row is a @node-submit@ observation with
transactions and units from the running node.
-}
module Conformance.Receipt (
    Outcome (..),
    Verdict (..),
    RefusalInfo (..),
    ConstructorStanding (..),
    ConstructorEvidence (..),
    PartialInfo (..),
    DerivationOutcome (..),
    DerivationEvidence (..),
    derivationMatches,
    Receipt (..),
    declaredConstructors,
    derivationVenue,
    maxReceiptBytes,
    checkReceiptSize,
    loadReceipts,
    writeReceiptFile,
    currentBase,
) where

import Control.Exception (ErrorCall (..), throwIO)

import Data.Aeson (
    FromJSON (..),
    ToJSON (..),
    eitherDecode,
    encode,
    object,
    withObject,
    withText,
    (.:),
    (.:?),
    (.=),
 )
import Data.ByteString.Lazy qualified as BSL
import Data.List (isPrefixOf, isSuffixOf, sort)
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (doesDirectoryExist, listDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.Process (readProcessWithExitCode)

-- | A row's observed outcome on the ledger.
data Outcome
    = Accepted
    | Refused
    deriving stock (Show, Eq)

instance FromJSON Outcome where
    parseJSON = withText "Outcome" $ \t -> case t of
        "accepted" -> pure Accepted
        "refused" -> pure Refused
        _ -> fail ("unknown receipt outcome: " <> T.unpack t)

instance ToJSON Outcome where
    toJSON Accepted = toJSON ("accepted" :: Text)
    toJSON Refused = toJSON ("refused" :: Text)

{- | The refusal attribution for a refused row: the scripts that
refused — one role, or several @+@-joined roles in ledger-reported
order when a malformed transaction trips two validators at once —
and the node's phase-2 reason verbatim.
-}
data RefusalInfo = RefusalInfo
    { refusalScript :: !Text
    , refusalReason :: !Text
    , refusalPhase :: !Text
    -- ^ observed phase (phase-2 for script-execution failures)
    , refusalHashes :: ![Text]
    -- ^ extracted failure script hashes (structured attribution)
    , refusalBranch :: !(Maybe Text)
    -- ^ named validator branch, when the compiled trace exposes
    -- one; Nothing states explicitly that none is available (never
    -- infer a branch name from the intended property)
    , refusalLimit :: !(Maybe Text)
    -- ^ explicit attribution limit when no branch is available
    }
    deriving stock (Show, Eq)

instance FromJSON RefusalInfo where
    parseJSON = withObject "RefusalInfo" $ \o ->
        RefusalInfo
            <$> o .: "script"
            <*> o .: "reason"
            <*> o .: "phase"
            <*> o .: "hashes"
            <*> o .:? "branch"
            <*> o .:? "limit"

instance ToJSON RefusalInfo where
    toJSON r =
        object
            [ "script" .= refusalScript r
            , "reason" .= refusalReason r
            , "phase" .= refusalPhase r
            , "hashes" .= refusalHashes r
            , "branch" .= refusalBranch r
            , "limit" .= refusalLimit r
            ]

-- | How a completed row stands against the behavioral models. The
-- chain outcome ('Outcome') is a fact; the verdict compares it with
-- what the models require. Q-002 (story 2, escalated to the user)
-- decides which model is the behavioral authority where Singular's
-- Lean and the consumer's theorems disagree; a row whose observation
-- contradicts the consumer's theorem while Singular's Lean permits
-- it is 'HeldQ002' — recorded, published, and never read as a pass:
-- the run exits non-zero while any row is held.
data Verdict
    = -- | the observation is what the behavioral model requires (or
      -- the model constrains nothing here)
      AgreesWithModel
    | -- | Singular's Lean and the consumer's theorem disagree and
      -- the chain sided with Singular's Lean: held pending the user
      -- ruling (Q-002, story 2)
      HeldQ002
    | -- | the chain contradicts Singular's Lean itself
      DivergesFromLean
    | -- | a user ruling resolved the row's question; the observation
      -- is retained (as history or defect evidence) under the ruling,
      -- never read as a pass and never as conformance credit (A-001:
      -- CG13 is resolved-by-ruling, not a fourth unresolved hold)
      ResolvedByRuling
    | -- | the row executed its available legs but named constructors
      -- stay unexercised, enumerated in 'receiptPartial' (E18 §3:
      -- explicit named residual, never green). A partial row is not
      -- fulfilled conformance: the session ends partial and the
      -- inventory overlay renders it partial, never executed.
      Partial
    deriving stock (Show, Eq, Enum, Bounded)

instance FromJSON Verdict where
    parseJSON = withText "Verdict" $ \t -> case t of
        "agrees-with-model" -> pure AgreesWithModel
        "held-q002" -> pure HeldQ002
        "diverges-from-lean" -> pure DivergesFromLean
        "resolved-by-ruling" -> pure ResolvedByRuling
        "partial" -> pure Partial
        _ -> fail ("unknown receipt verdict: " <> T.unpack t)

instance ToJSON Verdict where
    toJSON AgreesWithModel = toJSON ("agrees-with-model" :: Text)
    toJSON HeldQ002 = toJSON ("held-q002" :: Text)
    toJSON DivergesFromLean = toJSON ("diverges-from-lean" :: Text)
    toJSON ResolvedByRuling = toJSON ("resolved-by-ruling" :: Text)
    toJSON Partial = toJSON ("partial" :: Text)

{- | Per-constructor standing inside a partial row's receipt (E18
§3/§4, NOTE-052): every constructor the row names is accounted —
exercised accepts with transaction evidence, named residuals with
reason and limit, pre-existing gaps with their gap evidence. No
general framework: the declared constructor set per row is fixed
below and the loader requires it exactly. StandingRefused exists
for E18's future refusal witnesses; this bounded schema admits
none — any refused entry fails closed (NOTE-055).
-}
data ConstructorStanding
    = StandingAccepted
    | StandingRefused
    | StandingResidual
    | StandingGap
    deriving stock (Show, Eq)

instance FromJSON ConstructorStanding where
    parseJSON = withText "ConstructorStanding" $ \t -> case t of
        "accepted" -> pure StandingAccepted
        "refused" -> pure StandingRefused
        "residual" -> pure StandingResidual
        "gap" -> pure StandingGap
        _ -> fail ("unknown constructor standing: " <> T.unpack t)

instance ToJSON ConstructorStanding where
    toJSON StandingAccepted = toJSON ("accepted" :: Text)
    toJSON StandingRefused = toJSON ("refused" :: Text)
    toJSON StandingResidual = toJSON ("residual" :: Text)
    toJSON StandingGap = toJSON ("gap" :: Text)

data ConstructorEvidence = ConstructorEvidence
    { ceConstructor :: !Text
    , ceIndex :: !Integer
    , ceStanding :: !ConstructorStanding
    , ceEvidence :: !Text
    }
    deriving stock (Show, Eq)

instance FromJSON ConstructorEvidence where
    parseJSON = withObject "ConstructorEvidence" $ \o ->
        ConstructorEvidence
            <$> o .: "constructor"
            <*> o .: "index"
            <*> o .: "standing"
            <*> o .: "evidence"

instance ToJSON ConstructorEvidence where
    toJSON c =
        object
            [ "constructor" .= ceConstructor c
            , "index" .= ceIndex c
            , "standing" .= ceStanding c
            , "evidence" .= ceEvidence c
            ]

data PartialInfo = PartialInfo
    { partialConstructors :: ![ConstructorEvidence]
    }
    deriving stock (Show, Eq)

instance FromJSON PartialInfo where
    parseJSON = withObject "PartialInfo" $ \o ->
        PartialInfo <$> o .: "constructors"

instance ToJSON PartialInfo where
    toJSON p =
        object ["constructors" .= partialConstructors p]

{- | The complete declared constructor set per partial-capable row
(constructor name, wire index). The loader requires EVERY receipt
for these rows to carry exactly this accounting: a receipt written
before the schema has no accounting and resolves unknown or
incomplete — never covered. Silence must not mean success.
Per-constructor data determines full/partial truth, not the
caller's verdict: green requires every entry accepted-or-refused;
any residual or gap forces partial.
-}
declaredConstructors :: Text -> Maybe [(Text, Integer)]
declaredConstructors "CS03" =
    Just
        [ ("Contribute", 1)
        , ("Modify", 2)
        , ("Retract", 3)
        , ("End", 0)
        , ("Sweep", 4)
        ]
declaredConstructors "CS05" =
    Just
        [ ("Update", 0)
        , ("Rejected", 1)
        , ("Minting", 0)
        , ("Burning", 2)
        , ("Migrating", 1)
        ]
declaredConstructors _ = Nothing

{- | Off-chain identity-derivation evidence (CA04, E18 venue): the
deployed address derived through the PRODUCTION path against the
ACTUAL observed chain address, per validator by declared arity.
This is explicitly NOT phase-2 ledger evidence — the venue string
is fixed and loader-enforced so no later reader can mistake it.
-}
data DerivationOutcome
    = DerivMatch
    | DerivDistinct
    | DerivRefused
    deriving stock (Show, Eq, Ord)

instance FromJSON DerivationOutcome where
    parseJSON = withText "DerivationOutcome" $ \t -> case t of
        "match" -> pure DerivMatch
        "distinct" -> pure DerivDistinct
        "refused" -> pure DerivRefused
        _ -> fail ("unknown derivation outcome: " <> T.unpack t)

instance ToJSON DerivationOutcome where
    toJSON DerivMatch = toJSON ("match" :: Text)
    toJSON DerivDistinct = toJSON ("distinct" :: Text)
    toJSON DerivRefused = toJSON ("refused" :: Text)

data DerivationEvidence = DerivationEvidence
    { deValidator :: !Text
    -- ^ e.g. state.state / request.request
    , deArity :: !Integer
    -- ^ declared parameter count (0 / 2)
    , deComputed :: !Text
    -- ^ address derived through the production path
    , deReference :: !Text
    -- ^ comparison side: the observed chain address for match and
    -- refused outcomes; the UNAPPLIED address for distinct outcomes
    -- (request arity 2) — labelled by the outcome, never conflated.
    , deOutcome :: !DerivationOutcome
    , deVenue :: !Text
    -- ^ always derivationVenue (loader-enforced)
    }
    deriving stock (Show, Eq)

instance FromJSON DerivationEvidence where
    parseJSON = withObject "DerivationEvidence" $ \o ->
        DerivationEvidence
            <$> o .: "validator"
            <*> o .: "arity"
            <*> o .: "computed"
            <*> o .: "reference"
            <*> o .: "outcome"
            <*> o .: "venue"

instance ToJSON DerivationEvidence where
    toJSON d =
        object
            [ "validator" .= deValidator d
            , "arity" .= deArity d
            , "computed" .= deComputed d
            , "reference" .= deReference d
            , "outcome" .= deOutcome d
            , "venue" .= deVenue d
            ]

{- | The fixed venue string for derivation evidence. The loader
rejects any other venue: an identity check must not be readable
as ledger evidence.
-}
derivationVenue :: Text
derivationVenue = "off-chain-identity (not phase-2)"

{- | Evidence that a row executed. Accepted rows name the chain's
transaction ids and carry measurements; refused rows carry the
attribution and the submitted transaction's id under @rejected@
(empty @transactions@: nothing was accepted). @receiptVenue@
records where the refusal was observed: @node-submit@ (a node
ruling on a submitted transaction) or @ledger-eval@ (local ledger
evaluation only — never described as ledger execution).
@receiptDirty@ records whether the running tree had uncommitted
changes: a receipt from a dirty tree is honest working evidence,
but only a clean-tree receipt names a commit that reproduces it.
-}
data Receipt = Receipt
    { receiptRow :: !Text
    , receiptOutcome :: !Outcome
    , receiptVerdict :: !Verdict
    , receiptTransactions :: ![Text]
    , receiptRefusal :: !(Maybe RefusalInfo)
    , receiptMem :: !(Maybe Integer)
    , receiptCpu :: !(Maybe Integer)
    , receiptTxSize :: !(Maybe Integer)
    , receiptBase :: !Text
    , receiptNode :: !Text
    , receiptBlueprint :: !Text
    , receiptVenue :: !Text
    , receiptRejected :: !(Maybe Text)
    , receiptDirty :: !Bool
    , receiptPartial :: !(Maybe PartialInfo)
    -- ^ per-constructor accounting for partial rows (Nothing for
    -- every complete row; JSON-compatible: absent on old receipts).
    , receiptDerivation :: !(Maybe [DerivationEvidence])
    -- ^ off-chain identity-derivation evidence (CA04 only; Nothing
    -- elsewhere; JSON-compatible).
    }
    deriving stock (Show, Eq)

instance FromJSON Receipt where
    parseJSON = withObject "Receipt" $ \o ->
        Receipt
            <$> o .: "row"
            <*> o .: "outcome"
            <*> o .: "verdict"
            <*> o .: "transactions"
            <*> o .:? "refusal"
            <*> o .:? "mem"
            <*> o .:? "cpu"
            <*> o .:? "txSize"
            <*> o .: "base"
            <*> o .: "node"
            <*> o .: "blueprint"
            <*> o .: "venue"
            <*> o .:? "rejected"
            <*> o .: "dirty"
            <*> o .:? "partial"
            <*> o .:? "derivation"

instance ToJSON Receipt where
    toJSON r =
        object
            [ "row" .= receiptRow r
            , "outcome" .= receiptOutcome r
            , "verdict" .= receiptVerdict r
            , "transactions" .= receiptTransactions r
            , "refusal" .= receiptRefusal r
            , "rejected" .= receiptRejected r
            , "mem" .= receiptMem r
            , "cpu" .= receiptCpu r
            , "txSize" .= receiptTxSize r
            , "base" .= receiptBase r
            , "dirty" .= receiptDirty r
            , "node" .= receiptNode r
            , "blueprint" .= receiptBlueprint r
            , "venue" .= receiptVenue r
            , "partial" .= receiptPartial r
            , "derivation" .= receiptDerivation r
            ]

{- | Write one @receipt-<ROW>.json@ under the run's output directory.
Receipts over 'maxReceiptBytes' fail the run: a receipt nobody
can open is weak evidence, and a size convention would quietly
break on a later row.
-}
writeReceiptFile :: FilePath -> Receipt -> IO ()
writeReceiptFile dir r = case checkReceiptSize r of
    Left err -> throwIO (ErrorCall err)
    Right () ->
        BSL.writeFile
            (dir </> ("receipt-" <> T.unpack (receiptRow r) <> ".json"))
            (encode r)

{- | Receipts stay readable: the CG05 refusal once embedded the whole
compiled validator (~30KB of base64) because @show@ on the
evaluation context prints every script and cost model.
-}
maxReceiptBytes :: Int
maxReceiptBytes = 16384

{- | The size bound, purely: oversized receipts are an error naming
the row and the byte count.
-}
checkReceiptSize :: Receipt -> Either String ()
checkReceiptSize r
    | BSL.length (encode r) <= fromIntegral maxReceiptBytes = Right ()
    | otherwise =
        Left
            ( "receipt for row "
                <> T.unpack (receiptRow r)
                <> " is "
                <> show (BSL.length (encode r))
                <> " bytes, over the "
                <> show maxReceiptBytes
                <> " limit"
            )

{- | The derivation decision (NOTE-067): compare the produced
address against the reference and return both. Pure so the
wiring is unit-testable and mutation-provable: replacing the
comparison with True must make an observed-negative fail.
-}
derivationMatches :: (Eq a) => a -> a -> (a, Bool)
derivationMatches actual expected = (actual, actual == expected)

{- | CA04 completeness: exactly the state match, the request
distinct and the corrupted refusal — a missing negative is an
incomplete receipt, never a pass.
-}
completeCA04 :: [DerivationEvidence] -> Bool
completeCA04 ds =
    sort [(deValidator d, deOutcome d) | d <- ds]
        == sort
            [ ("request.request", DerivDistinct)
            , ("state.state", DerivMatch)
            , ("state.state", DerivRefused)
            ]

{- | Load every @receipt-*.json@ in a directory. A malformed receipt,
an accepted row with no transactions or measurements, a refused row
with no attribution, a partial verdict without its constructor
accounting, a success verdict carrying partial constructors, or
two receipts for one row is an error naming the file: evidence
that does not parse is not evidence, and a guard that cannot fail
is not a guard.
-}
loadReceipts :: FilePath -> IO (Either String [Receipt])
loadReceipts dir = do
    exists <- doesDirectoryExist dir
    if not exists
        then
            pure
                ( Left
                    ("receipt directory does not exist: " <> dir)
                )
        else do
            names <- listDirectory dir
            let files =
                    [ dir </> n
                    | n <- names
                    , "receipt-" `isPrefixOf` n
                    , ".json" `isSuffixOf` n
                    ]
            parsed <- mapM loadOne files
            pure (sequence parsed >>= checkReceipts)
  where
    loadOne path = do
        content <- BSL.readFile path
        pure $ case eitherDecode content of
            Left err ->
                Left (path <> " does not parse: " <> err)
            Right r -> checkOne path r >>= checkPartial path >>= checkDerivation path
    checkDerivation path r = case receiptDerivation r of
        Nothing ->
            if receiptRow r == "CA04"
                then
                    Left
                        ( path
                            <> ": CA04 receipt names no derivation evidence — unknown or incomplete, never covered"
                        )
                else Right r
        Just ds
            | receiptRow r /= "CA04" ->
                Left
                    ( path
                        <> ": only CA04 carries derivation evidence"
                    )
            | not (completeCA04 ds) ->
                Left
                    ( path
                        <> ": CA04 derivation evidence is incomplete — want state match, request distinct and corrupted refused"
                    )
            | null ds ->
                Left (path <> ": derivation evidence is empty")
            | any (T.null . deValidator) ds
            || any (T.null . deComputed) ds
            || any (T.null . deReference) ds ->
                Left (path <> ": derivation evidence names empty validator or address")
            | any ((/= derivationVenue) . deVenue) ds ->
                Left
                    ( path
                        <> ": derivation venue must be "
                        <> T.unpack derivationVenue
                    )
            | otherwise -> Right r
    checkPartial path r = case (receiptVerdict r, receiptPartial r) of
        (_, Nothing) -> case declaredConstructors (receiptRow r) of
            Nothing -> Right r
            Just _ ->
                Left
                    ( path
                        <> ": row "
                        <> T.unpack (receiptRow r)
                        <> " names no constructor accounting — unknown or incomplete, never covered"
                    )
        (Partial, Just pinfo) -> checkPartialConstructors path r pinfo
        (v, Just _) ->
            Left
                ( path
                    <> ": receipt claims "
                    <> show v
                    <> " while carrying partial constructors"
                )
    checkPartialConstructors path r pinfo =
        case declaredConstructors (receiptRow r) of
            Nothing ->
                Left
                    ( path
                        <> ": partial row "
                        <> T.unpack (receiptRow r)
                        <> " declares no constructor set"
                    )
            Just declared
                | sortPairs have /= sortPairs declared ->
                    Left
                        ( path
                            <> ": partial row "
                            <> T.unpack (receiptRow r)
                            <> " accounts "
                            <> show have
                            <> ", declared "
                            <> show declared
                        )
                | any refusedStanding ces ->
                    Left
                        ( path
                            <> ": partial row "
                            <> T.unpack (receiptRow r)
                            <> " carries a refused constructor witness — this bounded schema admits none (NOTE-055 fail-closed; no production row exercises a refusal witness)"
                        )
                | null residuals ->
                    Left
                        ( path
                            <> ": partial row "
                            <> T.unpack (receiptRow r)
                            <> " verdict partial lists no residual or gap constructor"
                        )
                | not (all boundAccepts accepts) ->
                    Left
                        ( path
                            <> ": partial row "
                            <> T.unpack (receiptRow r)
                            <> " names accepted-constructor evidence outside its transactions"
                        )
                | any (T.null . ceEvidence) ces ->
                    Left
                        ( path
                            <> ": partial row "
                            <> T.unpack (receiptRow r)
                            <> " carries empty constructor evidence"
                        )
                | otherwise -> Right r
      where
        ces = partialConstructors pinfo
        have = [(ceConstructor c, ceIndex c) | c <- ces]
        sortPairs = sort
        residuals =
            [ c
            | c <- ces
            , ceStanding c == StandingResidual || ceStanding c == StandingGap
            ]
        refusedStanding c = ceStanding c == StandingRefused
        accepts = [c | c <- ces, ceStanding c == StandingAccepted]
        boundAccepts c = ceEvidence c `elem` receiptTransactions r
    checkOne path r = case receiptOutcome r of
        Accepted -> checkAccepted path r
        Refused
            | null (receiptTransactions r)
            , Just info <- receiptRefusal r
            , receiptVenue r == "node-submit"
            , Just _ <- receiptRejected r ->
                checkRefused path r info
            | null (receiptTransactions r)
            , Just info <- receiptRefusal r
            , receiptVenue r == "ledger-eval"
            , Nothing <- receiptRejected r ->
                checkRefused path r info
            | otherwise ->
                Left
                    ( path
                        <> ": refused row "
                        <> T.unpack (receiptRow r)
                        <> " must carry a refusal, no transactions, and "
                        <> "a rejected id exactly for node-submit"
                    )
    -- Structural refusal fields (NOTE-071): observed phase,
    -- extracted hashes, and an explicit branch-or-limit. Legacy
    -- absence cannot claim the new attributed observation.
    checkRefused path r info = checkPhase
      where
        rowName = T.unpack (receiptRow r)
        checkPhase =
            if refusalPhase info /= "phase-2"
                then Left (path <> ": refused row " <> rowName <> " phase is not phase-2")
                else checkHashes
        checkHashes =
            if null (refusalHashes info)
                then Left (path <> ": refused row " <> rowName <> " names no extracted failure hashes")
                else
                    if any T.null (refusalHashes info)
                        then Left (path <> ": refused row " <> rowName <> " names an empty failure hash")
                        else checkBranch
        checkBranch =
            if refusalBranch info == Nothing && refusalLimit info == Nothing
                then Left (path <> ": refused row " <> rowName <> " states neither a named branch nor its limit")
                else
                    if any emptyJust [refusalBranch info, refusalLimit info]
                        then Left (path <> ": refused row " <> rowName <> " carries an empty branch or limit")
                        else Right r
        emptyJust (Just t) = T.null t
        emptyJust Nothing = False
    checkAccepted p x
        | receiptRow x == "CA04", receiptVenue x == derivationVenue =
            checkCA04Accepted p x
        | receiptRow x == "CA04" =
            Left
                ( p
                    <> ": CA04 venue must be "
                    <> T.unpack derivationVenue
                )
        | receiptVenue x == "node-submit" = checkNodeAccepted p x
        | receiptVenue x == "blueprint-check", receiptRow x == "CS01" =
            checkLocalAccepted p x
        | receiptVenue x == "param-check", receiptRow x == "CS06" =
            checkLocalAccepted p x
        | otherwise =
            Left
                ( p
                    <> ": accepted row "
                    <> T.unpack (receiptRow x)
                    <> " has venue "
                    <> T.unpack (receiptVenue x)
                    <> ", want node-submit or its own local venue"
                )
    checkCA04Accepted p x
        | null (receiptTransactions x) =
            Left
                ( p
                    <> ": CA04 row names no provenance boot transaction"
                )
        | any isNothing [receiptMem x, receiptCpu x, receiptTxSize x] =
            Left
                ( p
                    <> ": CA04 row misses measurements"
                )
        | isJust (receiptRejected x) =
            Left
                ( p
                    <> ": CA04 row must not name a rejected transaction"
                )
        | isJust (receiptRefusal x) =
            Left
                ( p
                    <> ": CA04 row must not carry a refusal"
                )
        | otherwise = Right x
    checkNodeAccepted p x
        | null (receiptTransactions x) =
            Left
                ( p
                    <> ": accepted row "
                    <> T.unpack (receiptRow x)
                    <> " names no transaction"
                )
        | any isNothing [receiptMem x, receiptCpu x, receiptTxSize x] =
            Left
                ( p
                    <> ": accepted row "
                    <> T.unpack (receiptRow x)
                    <> " misses measurements"
                )
        | isJust (receiptRejected x) =
            Left
                ( p
                    <> ": accepted row "
                    <> T.unpack (receiptRow x)
                    <> " must not name a rejected transaction"
                )
        | otherwise = Right x
    checkLocalAccepted p x
        | not (null (receiptTransactions x)) =
            Left
                ( p
                    <> ": accepted row "
                    <> T.unpack (receiptRow x)
                    <> " is local and must name no transaction"
                )
        | receiptMem x /= Just 0 || receiptCpu x /= Just 0 =
            Left
                ( p
                    <> ": accepted row "
                    <> T.unpack (receiptRow x)
                    <> " is local and must record zero units"
                )
        | Nothing <- receiptTxSize x =
            Left
                ( p
                    <> ": accepted row "
                    <> T.unpack (receiptRow x)
                    <> " misses measurements"
                )
        | isJust (receiptRejected x) =
            Left
                ( p
                    <> ": accepted row "
                    <> T.unpack (receiptRow x)
                    <> " must not name a rejected transaction"
                )
        | isJust (receiptRefusal x) =
            Left
                ( p
                    <> ": accepted row "
                    <> T.unpack (receiptRow x)
                    <> " must not carry a refusal"
                )
        | otherwise = Right x
    checkReceipts rs
        | length rows /= length (nub rows) =
            Left "two receipts for one row"
        | otherwise = Right rs
      where
        rows = map receiptRow rs
        nub [] = []
        nub (x : xs) = x : nub (filter (/= x) xs)

{- | The current tree's base commit. 'Nothing' when git cannot say
(no checkout, no git): receipts then match nothing and @list@
prints the declared plan with a warning.
-}
currentBase :: IO (Maybe Text)
currentBase = do
    (code, out, _) <-
        readProcessWithExitCode "git" ["rev-parse", "HEAD"] ""
    case code of
        ExitSuccess ->
            pure (Just (T.strip (T.pack out)))
        _ -> do
            hPutStrLn
                stderr
                "conformance list: git base unknown; \
                \printing the declared plan"
            pure Nothing
