{-# LANGUAGE LambdaCase #-}

{- |
Module      : Conformance.EvidencePage
Description : The published evidence page, computed from receipts
License     : Apache-2.0

The conformance evidence page is a function of four inputs and nothing
else: the requirement inventory (@rows.json@), the application model
revision (@conformance/model-revision@), and one snapshot of run output
for one stated code revision — the conformance run receipts and the
backend contract suite's per-adapter results, copied from the CI runs
that produced them.

No state is typed into the page. A requirement reads executed or
partial only through 'effectiveState', from a receipt whose base is the
snapshot's stated base; every other requirement is listed by its
requirement text under the plan @rows.json@ declares. A snapshot whose
receipts or results name another base, were recorded on a dirty tree,
name an unknown requirement, or report a contract case list that is not
the same for every adapter is refused rather than rendered.

The documentation check renders the page again from the committed
inputs and compares it byte for byte with the committed page and its
speech companion; any difference fails the check.
-}
module Conformance.EvidencePage
    ( -- * Snapshot
      Snapshot (..)
    , Source (..)
    , ContractResult (..)
    , ContractEvidence (..)
    , ContractOutcome (..)
    , loadSnapshot

      -- * Rendering
    , RenderedPage (..)
    , renderEvidencePage

      -- * The command
    , runEvidencePage
    ) where

import Conformance.Edge.Permanent qualified as Permanent
import Control.Monad (unless)
import Data.Aeson
    ( FromJSON (..)
    , Value (..)
    , eitherDecode
    , eitherDecodeStrict
    , encode
    , object
    , withObject
    , withText
    , (.:)
    , (.:?)
    , (.=)
    )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BSL
import Data.Char (isAlphaNum)
import Data.List (nub, sort, sortOn)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory
    ( doesDirectoryExist
    , doesFileExist
    , listDirectory
    )
import System.Exit (exitFailure)
import System.FilePath (takeExtension, (</>))
import System.IO (hPutStrLn, stderr)

import Conformance.Receipt
    ( Receipt (..)
    , Verdict (..)
    , loadReceipts
    , unmetReading
    , unmetRuling
    )
import Conformance.Rows
    ( Row (..)
    , RowState (..)
    , ShownState (..)
    , effectiveState
    , loadRows
    )
import Data.Maybe (isNothing)

-- | Where the snapshot's files were copied from: one CI run's artifact.
data Source = Source
    { sourceWorkflow :: !Text
    , sourceRun :: !Text
    , sourceArtifact :: !Text
    }
    deriving stock (Show, Eq)

instance FromJSON Source where
    parseJSON = withObject "Source" $ \o ->
        Source <$> o .: "workflow" <*> o .: "run" <*> o .: "artifact"

-- | The evidence class of one contract-suite run. There is no public chain.
data ContractEvidence = ContractTestAdapter | ContractDevNet
    deriving stock (Show, Eq, Ord)

instance FromJSON ContractEvidence where
    parseJSON = withText "ContractEvidence" $ \case
        "test-adapter" -> pure ContractTestAdapter
        "devnet" -> pure ContractDevNet
        other ->
            fail
                ( "evidence class "
                    <> T.unpack other
                    <> " is not one the contract suite runs: \
                       \test-adapter or devnet"
                )

-- | One contract case's result on one adapter.
data ContractOutcome
    = ContractPassed
    | ContractFailed !Text
    | ContractNotSupported !Text
    deriving stock (Show, Eq)

-- | One line of the contract suite's results file.
data ContractResult = ContractResult
    { crBase :: !Text
    , crDirty :: !Bool
    , crAdapter :: !Text
    , crEvidence :: !ContractEvidence
    , crCase :: !Text
    , crKind :: !Text
    , crRequirement :: !Text
    , crOutcome :: !ContractOutcome
    }
    deriving stock (Show, Eq)

instance FromJSON ContractResult where
    parseJSON = withObject "ContractResult" $ \o -> do
        outcome <- o .: "outcome"
        reason <- o .:? "reason"
        result <- case (outcome :: Text, reason) of
            ("passed", Nothing) -> pure ContractPassed
            ("failed", Just r) -> pure (ContractFailed r)
            ("not-supported", Just r) -> pure (ContractNotSupported r)
            ("passed", Just _) -> fail "a passed case carries no reason"
            (_, Nothing) -> fail ("a " <> T.unpack outcome <> " case names its reason")
            _ -> fail ("unknown contract outcome: " <> T.unpack outcome)
        ContractResult
            <$> o .: "base"
            <*> o .: "dirty"
            <*> o .: "adapter"
            <*> o .: "evidence"
            <*> o .: "case"
            <*> o .: "kind"
            <*> o .: "requirement"
            <*> pure result

-- | Everything one snapshot directory holds.
data Snapshot = Snapshot
    { snapBase :: !Text
    -- ^ The code revision every receipt and result must name
    , snapSources :: ![Source]
    , snapReceipts :: ![Receipt]
    , snapReceiptFiles :: ![FilePath]
    , snapContract :: ![ContractResult]
    , snapContractFiles :: ![FilePath]
    }
    deriving stock (Show, Eq)

data Manifest = Manifest Text [Source]

instance FromJSON Manifest where
    parseJSON = withObject "Snapshot" $ \o ->
        Manifest <$> o .: "base" <*> o .: "sources"

{- | Read a snapshot directory: @snapshot.json@ (the stated base and the
CI runs the files were copied from), @receipts/@ (the conformance run's
receipt artifact, as downloaded) and @contract/@ (the contract suite's
results files, one JSON object per line).
-}
loadSnapshot :: FilePath -> IO (Either String Snapshot)
loadSnapshot dir = do
    manifest <- eitherDecode <$> BSL.readFile (dir </> "snapshot.json")
    receipts <- loadReceipts (dir </> "receipts")
    receiptFiles <- listed (dir </> "receipts")
    contractFiles <-
        filter ((== ".jsonl") . takeExtension)
            <$> listed (dir </> "contract")
    contract <-
        mapM (readResults . ((dir </> "contract") </>)) contractFiles
    pure $ do
        Manifest base sources <-
            either (Left . ("snapshot.json: " <>)) Right manifest
        rs <- receipts
        cs <- concat <$> sequence contract
        pure
            Snapshot
                { snapBase = base
                , snapSources = sources
                , snapReceipts = rs
                , snapReceiptFiles = receiptFiles
                , snapContract = cs
                , snapContractFiles = contractFiles
                }
  where
    listed d = do
        exists <- doesDirectoryExist d
        if exists then sort <$> listDirectory d else pure []
    readResults path = do
        content <- BS.readFile path
        pure
            . traverse (decodeLine path)
            . zip [1 :: Int ..]
            . filter (not . BS.null)
            $ BS8.lines content
    decodeLine path (n, line) =
        either
            (\e -> Left (path <> ":" <> show n <> ": " <> e))
            Right
            (eitherDecodeStrict line)

-- | The page and its speech companion, as the site publishes them.
data RenderedPage = RenderedPage
    { renderedPage :: !Text
    , renderedSpeech :: !BSL.ByteString
    -- ^ Without its source stamp; the caller stamps it with the page hash
    }

{- | Render the evidence page, or refuse the snapshot naming why. The
first argument is the application model revision.
-}
renderEvidencePage
    :: Text -> [Row] -> Snapshot -> Either String RenderedPage
renderEvidencePage model rows snap = do
    validateSnapshot rows snap
    pure (layout model rows snap)

validateSnapshot :: [Row] -> Snapshot -> Either String ()
validateSnapshot rows snap = do
    whenL (T.null (snapBase snap)) "the snapshot states no base"
    whenL
        (null (snapReceipts snap))
        "the snapshot holds no conformance receipt"
    whenL
        (null (snapContract snap))
        "the snapshot holds no contract result"
    mapM_ receiptBound (snapReceipts snap)
    mapM_ resultBound (snapContract snap)
    mapM_ unmetStated (snapReceipts snap)
    sameCases
  where
    base = snapBase snap
    known = map rowId rows
    -- An unmet row is published only with the ruling that keeps it unmet.
    unmetStated r =
        whenL
            ( receiptVerdict r == UnmetByRuling
                && isNothing (unmetRuling (receiptRow r))
            )
            ( "the receipt for "
                <> T.unpack (receiptRow r)
                <> " is unmet by a ruling no reader surface states"
            )
    receiptBound r = do
        whenL
            (receiptRow r `notElem` known)
            ("a receipt names unknown requirement " <> T.unpack (receiptRow r))
        whenL
            (receiptBase r /= base)
            ( "the receipt for "
                <> T.unpack (receiptRow r)
                <> " names base "
                <> T.unpack (receiptBase r)
                <> ", not the stated base "
                <> T.unpack base
            )
        whenL
            (receiptDirty r)
            ( "the receipt for "
                <> T.unpack (receiptRow r)
                <> " was recorded on a dirty tree"
            )
    resultBound c = do
        whenL
            (crBase c /= base)
            ( "the contract result for "
                <> T.unpack (crAdapter c)
                <> " / "
                <> T.unpack (crCase c)
                <> " names base "
                <> T.unpack (crBase c)
                <> ", not the stated base "
                <> T.unpack base
            )
        whenL
            (crDirty c)
            ( "the contract result for "
                <> T.unpack (crAdapter c)
                <> " / "
                <> T.unpack (crCase c)
                <> " was recorded on a dirty tree"
            )
    sameCases = do
        let byAdapter = adapterCases (snapContract snap)
            caseLists = map (map crCase . snd) byAdapter
        mapM_
            ( \(a, cs) ->
                whenL
                    (length (nub (map crCase cs)) /= length cs)
                    ("adapter " <> T.unpack a <> " reports a contract case twice")
            )
            byAdapter
        case caseLists of
            first : rest ->
                whenL
                    (any ((/= sort first) . sort) rest)
                    "the adapters do not report the same contract case list"
            [] -> pure ()

whenL :: Bool -> String -> Either String ()
whenL True e = Left e
whenL False _ = Right ()

-- | Results grouped by adapter, adapters in first-reported order.
adapterCases :: [ContractResult] -> [(Text, [ContractResult])]
adapterCases cs =
    [ (a, [c | c <- cs, crAdapter c == a])
    | a <- nub (map crAdapter cs)
    ]

-- * Layout

data Section = Section
    { secLevel :: Int
    , secTitle :: Text
    , secBody :: [Text]
    , secSpeech :: [Text]
    }

layout :: Text -> [Row] -> Snapshot -> RenderedPage
layout model rows snap =
    RenderedPage
        { renderedPage = T.unlines (preamble <> concatMap sectionText sections)
        , renderedSpeech =
            encode . object $
                [ Key.fromText (slug (secTitle s))
                    .= map segment (secSpeech s)
                | s <- sections
                ]
        }
  where
    base = snapBase snap
    shown =
        [ (r, effectiveState base (snapReceipts snap) r)
        | r <- sortOn rowId rows
        ]
    inState p = [r | (r, s) <- shown, p s]
    executed = inState (== ShownExecuted)
    partial = inState (== ShownPartial)
    recorded = [(r, v) | (r, ShownRecorded v) <- shown]
    planned st = inState (== ShownPlanned st)
    uncovered = planned Uncovered
    elsewhere = planned BoundElsewhere
    outOfScope = planned OutOfScope
    adapters = adapterCases (snapContract snap)
    count = T.pack . show . length

    preamble =
        [ "# Conformance evidence"
        , ""
        , "As an integrator deciding whether to build on Singular, I read which of the \
          \consumer requirements a run of one named code revision demonstrated, which \
          \it did not, and how every backend adapter answered the shared contract — \
          \and I can check that nothing on this page was typed by hand."
        , ""
        , "This page is generated by `conformance evidence-page` from the requirement \
          \inventory `conformance/rows.json`, the application model revision in \
          \`conformance/model-revision`, and the receipts and contract results the CI \
          \runs named in the appendix produced for the code revision below. The \
          \documentation check regenerates it from those committed files and fails on \
          \any difference."
        , ""
        , "The runs below are a historical snapshot of the broader registry law at \
          \their recorded code revision. They certify that revision only. To assess \
          \current two-edge coverage, read `conformance list` with receipts from the \
          \current revision. A separate supported retirement story cannot certify \
          \the original successful Absent, deletion or reincarnation requirements."
        , ""
        ]

    sections =
        [ Section
            2
            "Permanent registration and termination"
            [ "This bounded story targets the new permanent contract. Its evidence state is computed with the inventory below; historical broader receipts do not execute it. Exported script evaluation and the packaged ordinary CLI journey remain separate boundaries. The new release abandons earlier deployed registries; protected rejection follows this carve before the first milestone can close."
            , ""
            , T.pack Permanent.description
            ]
            [ "A new permanent registry supports registration and permanent termination only. The story compares both allowed operations and refusals of all five excluded operations, including a mixed batch. Its current live conformance evidence state is read from receipts, never assigned from component tests."
            ]
        , Section
            2
            "What this evidence is bound to"
            [ "| | |"
            , "| --- | --- |"
            , "| Code revision the runs checked out | `" <> base <> "` |"
            , "| Application model revision | `" <> model <> "` |"
            , "| Requirements in the inventory | "
                <> count rows
                <> " ("
                <> count outOfScope
                <> " out of scope) |"
            , "| Demonstrated by a run | " <> count executed <> " |"
            , "| Partly demonstrated by a run | " <> count partial <> " |"
            , "| Run, result not a pass | " <> count recorded <> " |"
            , "| Bound to evidence elsewhere | " <> count elsewhere <> " |"
            , "| Uncovered | " <> count uncovered <> " |"
            , "| Backend adapters in the contract runs | " <> count adapters <> " |"
            , ""
            , "```mermaid"
            , "flowchart LR"
            , "    inventory[\"requirement inventory\"] -->|plan per requirement| render[\"evidence-page renderer\"]"
            , "    receipts[\"conformance run receipts\"] -->|executed or partial, same revision only| render"
            , "    contract[\"contract suite results\"] -->|per adapter and case| render"
            , "    model[\"model revision\"] -->|named| render"
            , "    render -->|writes| page[\"this page\"]"
            , "    render -->|recomputes| check[\"documentation check\"]"
            , "    page -->|compared byte for byte| check"
            , "```"
            ]
            [ "The runs behind this page checked out code revision "
                <> T.take 12 base
                <> ", and the application model revision is "
                <> T.take 12 model
                <> "."
            , count rows
                <> " requirements are in the inventory. "
                <> count executed
                <> " were demonstrated by a run, "
                <> count partial
                <> " partly, "
                <> count recorded
                <> " ran without a pass, "
                <> count elsewhere
                <> " are bound to evidence elsewhere, "
                <> count uncovered
                <> " are uncovered and "
                <> count outOfScope
                <> " are out of scope."
            , "The diagram shows the page computed from the inventory, the receipts, \
              \the contract results and the model revision, and the documentation check \
              \recomputing it and comparing."
            ]
        , Section
            2
            "Requirements a run demonstrated"
            ( requirementTable
                ( [(r, "demonstrated") | r <- executed]
                    <> [(r, "partly demonstrated") | r <- partial]
                )
            )
            [ count executed
                <> " requirements were demonstrated and "
                <> count partial
                <> " partly demonstrated by a receipt for this code revision. Each row \
                   \gives the requirement and the outcome it expects."
            ]
        , Section
            2
            "Requirements a run did not pass"
            (requirementTable [(r, verdictText (rowId r) v) | (r, v) <- recorded])
            [ count recorded
                <> " requirements ran on this code revision with a result that is not a \
                   \pass. They are listed with the reason the run recorded."
            ]
        , Section
            2
            "Requirements not demonstrated"
            [ "Every requirement without a receipt for this code revision is listed with \
              \the plan the inventory declares for it."
            ]
            [ "Every requirement without a receipt for this code revision is listed \
              \below, under the plan the inventory declares."
            ]
        , Section
            3
            "Uncovered"
            (requirementTable [(r, "uncovered") | r <- uncovered])
            [count uncovered <> " requirements have no evidence yet."]
        , Section
            3
            "Bound to evidence elsewhere"
            ( requirementTable
                [ (r, maybe "bound elsewhere" ("bound elsewhere: " <>) (rowEvidence r))
                | r <- elsewhere
                ]
            )
            [ count elsewhere
                <> " requirements are evidenced by another suite, named in each row."
            ]
        , Section
            3
            "Out of scope"
            (requirementTable [(r, "out of scope") | r <- outOfScope])
            [ count outOfScope
                <> " requirements belong to the consumer, are recorded here and never \
                   \claimed."
            ]
        , Section
            2
            "Backend contract across adapters"
            ( [ "One case list runs against every adapter. A case an adapter cannot \
                \exercise is reported for it as not supported, with the reason; it is \
                \never counted as passed."
              , ""
              , "| Adapter | Evidence class | Passed | Failed | Not supported |"
              , "| --- | --- | --- | --- | --- |"
              ]
                <> [ "| "
                        <> a
                        <> " | "
                        <> evidenceText cs
                        <> " | "
                        <> outcomes isPassed cs
                        <> " | "
                        <> outcomes isFailed cs
                        <> " | "
                        <> outcomes isNotSupported cs
                        <> " |"
                   | (a, cs) <- adapters
                   ]
            )
            [ count adapters
                <> " adapters ran the contract suite. The table counts, per adapter, \
                   \the cases passed, failed and not supported."
            ]
        ]
            <> [ Section
                    3
                    (a <> " adapter")
                    ( [ "Evidence class: " <> evidenceText cs <> "."
                      , ""
                      , "| Contract case | Kind | Result |"
                      , "| --- | --- | --- |"
                      ]
                        <> [ "| "
                                <> cell (crRequirement c)
                                <> " | "
                                <> crKind c
                                <> " | "
                                <> cell (outcomeText (crOutcome c))
                                <> " |"
                           | c <- cs
                           ]
                    )
                    [ "The "
                        <> a
                        <> " adapter, evidence class "
                        <> evidenceText cs
                        <> ": "
                        <> outcomes isPassed cs
                        <> " cases passed, "
                        <> outcomes isFailed cs
                        <> " failed and "
                        <> outcomes isNotSupported cs
                        <> " are not supported."
                    ]
               | (a, cs) <- adapters
               ]
            <> [ Section
                    2
                    "Appendix: how this page was produced"
                    ( [ "This appendix is harness evidence: where the files behind this \
                        \page came from. It says nothing more about the product."
                      , ""
                      , "| Workflow | Run | Artifact |"
                      , "| --- | --- | --- |"
                      ]
                        <> [ "| "
                                <> sourceWorkflow s
                                <> " | "
                                <> sourceRun s
                                <> " | "
                                <> sourceArtifact s
                                <> " |"
                           | s <- snapSources snap
                           ]
                        <> [ ""
                           , "The committed snapshot is `conformance/evidence/page/`: "
                                <> count (snapReceiptFiles snap)
                                <> " files of the receipt artifacts under `receipts/`, of which "
                                <> count (snapReceipts snap)
                                <> " are receipts, and "
                                <> count (snapContractFiles snap)
                                <> " contract results files under `contract/` holding "
                                <> count (snapContract snap)
                                <> " results."
                           , ""
                           , "Regenerate the page with `nix run ./conformance#conformance -- \
                             \evidence-page --write`; check it with the same command without \
                             \`--write`."
                           ]
                    )
                    [ "This appendix names the CI runs and artifacts the snapshot was \
                      \copied from, and how many receipts and contract results it holds."
                    ]
               ]

    requirementTable entries =
        if null entries
            then ["None."]
            else
                [ "| Name | Requirement | Expected outcome | State |"
                , "| --- | --- | --- | --- |"
                ]
                    <> [ "| "
                            <> rowId r
                            <> " | "
                            <> cell (rowRequirement r)
                            <> " | "
                            <> cell (rowExpected r)
                            <> " | "
                            <> cell st
                            <> " |"
                       | (r, st) <- entries
                       ]

    evidenceText cs =
        T.intercalate ", " . nub $ map (contractEvidenceName . crEvidence) cs
    outcomes p = count . filter (p . crOutcome)

segment :: Text -> Value
segment t = object ["text" .= t, "pause" .= (400 :: Int)]

sectionText :: Section -> [Text]
sectionText s =
    [T.replicate (secLevel s) "#" <> " " <> secTitle s, ""]
        <> secBody s
        <> [""]

cell :: Text -> Text
cell = T.replace "|" "\\|" . T.replace "\n" " "

contractEvidenceName :: ContractEvidence -> Text
contractEvidenceName ContractTestAdapter = "test-adapter"
contractEvidenceName ContractDevNet = "devnet"

outcomeText :: ContractOutcome -> Text
outcomeText = \case
    ContractPassed -> "passed"
    ContractFailed r -> "failed: " <> r
    ContractNotSupported r -> "not supported: " <> r

isPassed, isFailed, isNotSupported :: ContractOutcome -> Bool
isPassed ContractPassed = True
isPassed _ = False
isFailed ContractFailed{} = True
isFailed _ = False
isNotSupported ContractNotSupported{} = True
isNotSupported _ = False

verdictText :: Text -> Verdict -> Text
verdictText row = \case
    AgreesWithModel -> "agrees with the model"
    HeldQ002 ->
        "held: the chain sided with Singular's model against the consumer's \
        \theorem, pending a ruling"
    DivergesFromLean -> "diverges: the chain contradicts Singular's model"
    ResolvedByRuling -> "resolved by a ruling: retained as history, not a pass"
    UnmetByRuling -> maybe "unmet by a ruling" unmetReading (unmetRuling row)
    Partial -> "partial"

-- | python-markdown's table-of-contents id, as MkDocs renders it.
slug :: Text -> Text
slug =
    T.dropAround (== '-')
        . T.intercalate "-"
        . T.words
        . T.filter (\c -> c == '-' || c == ' ' || c == '_' || isWordChar c)
        . T.toLower
        . T.strip
  where
    isWordChar c = isAlphaNum c || c == '_'

-- * The command

{- | Render the published evidence page from the repository at @root@:
@conformance/rows.json@, @conformance/model-revision@ and the snapshot
@conformance/evidence/page@. With @write@ the page and its (unstamped)
speech companion are written. Otherwise the committed page must equal
the rendering byte for byte and the committed speech must carry exactly
the rendered sections, or the command exits non-zero naming the
disagreement.
-}
runEvidencePage :: FilePath -> Bool -> IO ()
runEvidencePage root write = do
    rows <-
        loadRows (root </> "conformance/rows.json") >>= either refuse pure
    model <-
        T.strip <$> TIO.readFile (root </> "conformance/model-revision")
    snap <-
        loadSnapshot (root </> "conformance/evidence/page")
            >>= either refuse pure
    page <- either refuse pure (renderEvidencePage model rows snap)
    if write
        then do
            TIO.writeFile pagePath (renderedPage page)
            BSL.writeFile speechPath (renderedSpeech page)
            putStrLn ("wrote " <> pagePath <> " and " <> speechPath)
        else do
            exists <- doesFileExist pagePath
            unless exists (refuse (pagePath <> " is missing"))
            committed <- TIO.readFile pagePath
            case firstDifference (T.lines (renderedPage page)) (T.lines committed) of
                Just (n, want, got) ->
                    refuse
                        ( pagePath
                            <> " disagrees with the receipts it is computed from at line "
                            <> show n
                            <> ": rendered "
                            <> show want
                            <> ", published "
                            <> show got
                        )
                Nothing
                    | committed /= renderedPage page ->
                        refuse (pagePath <> " differs from its rendering in line endings")
                    | otherwise -> pure ()
            speech <- eitherDecode <$> BSL.readFile speechPath
            case (speech, eitherDecode (renderedSpeech page)) of
                (Right (Object o), Right (Object r))
                    | KeyMap.filterWithKey (\k _ -> not (T.isPrefixOf "_" (Key.toText k))) o
                        == r ->
                        putStrLn
                            ( pagePath
                                <> " equals its rendering from the receipts of "
                                <> T.unpack (snapBase snap)
                            )
                _ ->
                    refuse
                        (speechPath <> " disagrees with the rendered page's sections")
  where
    pagePath = root </> "docs/conformance-evidence.md"
    speechPath = root </> "docs/conformance-evidence.speech.json"

refuse :: String -> IO a
refuse msg = do
    hPutStrLn stderr ("conformance evidence-page: FAILED: " <> msg)
    exitFailure

-- | The first line (1-based) where two texts differ, with both sides.
firstDifference :: [Text] -> [Text] -> Maybe (Int, Text, Text)
firstDifference want got =
    case [ (n, w, g)
         | (n, w, g) <-
            zip3
                [1 ..]
                (pad want)
                (pad got)
         , w /= g
         ] of
        (n, w, g) : _ -> Just (n, w, g)
        [] -> Nothing
  where
    width = max (length want) (length got)
    pad xs = take width (xs <> repeat "<end of page>")
