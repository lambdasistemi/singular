-- | Publish the executed story and the unchanged requirement inventory.
module Conformance.Story.Book (renderBook) where

import Data.Text qualified as T
import Conformance.Rows (Row (..), RowState (..), loadRows)
import Conformance.Edge.Register qualified as InsertActive
import Conformance.Fold.KeyedMint qualified as KeyedMint
import Conformance.Story.Render (renderStory)
import Paths_conformance (getDataFileName)

-- | Call after the suite succeeds. No test fixture counts as a chain receipt.
renderBook :: IO String
renderBook = do
    path <- getDataFileName "rows.json"
    result <- loadRows path
    rows <- either fail pure result
    pure $ unlines
        [ "# The registry's promises"
        , ""
        , "A registry commits a map of keys to a root. Requests ask it to change a key; a fold applies those requests. Active tokens witness active registrations."
        , ""
        , "Read the requirements first, then the active-registration and batch stories. Each case states what is accepted or refused, why, and the exact observation it changes."
        , ""
        , "## What has been demonstrated"
        , ""
        , "The stories below passed against the receipt loader. They check the evidence a run must supply; they do not execute new chain transactions or turn uncovered requirements into demonstrated behavior. This book includes no live run receipts."
        , ""
        , "## Requirements and remaining evidence"
        , ""
        , "These requirements and their planned states come directly from rows.json. Only a matching run receipt can establish execution. Bound-elsewhere points to existing evidence; uncovered remains uncovered."
        , ""
        ]
        <> concatMap requirement rows
        <> "\n## Insert active registrations\n\n```text\n"
        <> renderStory InsertActive.story
        <> "```\n\n## Batch minting at distinct keys\n\n```text\n"
        <> renderStory KeyedMint.story
        <> "```\n\n## Appendix: how this evidence is checked\n\n"
        <> "The Support modules check receipt parsing, refusal attribution, inventory and observation completeness. Story modules check the language and its two interpreters. They make no additional registry promise. Authentication checks remain compiled but unwired, tracked separately.\n"
  where
    requirement row = "### " <> T.unpack (rowRequirement row) <> "\n\n"
        <> "Expected: " <> T.unpack (rowExpected row) <> ". Evidence: " <> stateName (rowState row) <> ".\n\n"
        <> "Source: " <> T.unpack (rowSource row) <> ".\n\n"
        <> maybe "" (\e -> "Existing evidence: " <> T.unpack e <> "\n\n") (rowEvidence row)
    stateName Uncovered = "uncovered"
    stateName BoundElsewhere = "bound elsewhere"
    stateName OutOfScope = "outside the registry's scope"
