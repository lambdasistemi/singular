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
        , "The registry records keys and processes requests to change them. Registering an active key gives the requested recipient a token identifying that key. Applying several requests together must still create the right token for each key."
        , ""
        , "Read the requirements first, then the registration and batch stories. Each case explains what evidence is accepted or rejected and why. The exact test inputs and formal specification are available in expandable details."
        , ""
        , "## What has been demonstrated"
        , ""
        , "The stories below check whether reports from a registry run contain the required evidence. All of these checks passed on example reports. This does not establish that the transactions were run on a blockchain; this book includes no reports from a live run. Requirements without evidence remain unproven."
        , ""
        , "## Requirements and remaining evidence"
        , ""
        , "The wording and evidence status below come directly from the requirements inventory. 'Uncovered' means the required evidence is missing. 'Bound elsewhere' points to evidence maintained elsewhere. 'Outside the registry's scope' identifies responsibilities that belong to another system. A requirement is marked as executed only when a matching run report establishes that."
        , ""
        ]
        <> concatMap requirement rows
        <> "\n## Registering a key\n\n"
        <> "The example starts with a request to register one key and send its active token to the requested address. The run report describes applying that request and then attempting to register the same key again. A separate successful transaction provides a comparison for the rejected duplicate. Each case below changes one part of that report.\n\n"
        <> renderStory InsertActive.story
        <> "## Allocating tokens across a batch of requests\n\n"
        <> "Two requests register two different keys. Each needs one active token. Creating both tokens for the first key gives the right total but the wrong allocation: the second key receives none. The rejection report must describe that mistake and a successful comparison that creates one token for each key. These cases check the report supporting that claim.\n\n"
        <> renderStory KeyedMint.story
        <> "## Appendix: how this evidence is checked\n\n"
        <> "The supporting tests check that reports are readable and complete, identify the script responsible for a rejection, and preserve the requirements inventory. Other checks make sure a published story describes the report actually tested and quotes the specification accurately. They make no additional registry promise. Tests for recognising the intended registry are compiled but are not yet run by this suite.\n"
  where
    requirement row = "### " <> T.unpack (rowRequirement row) <> "\n\n"
        <> "Expected: " <> T.unpack (rowExpected row) <> ". Evidence: " <> stateName (rowState row) <> ".\n\n"
        <> "Source: " <> T.unpack (rowSource row) <> ".\n\n"
        <> maybe "" (\e -> "Existing evidence: " <> T.unpack e <> "\n\n") (rowEvidence row)
    stateName Uncovered = "uncovered"
    stateName BoundElsewhere = "bound elsewhere"
    stateName OutOfScope = "outside the registry's scope"
