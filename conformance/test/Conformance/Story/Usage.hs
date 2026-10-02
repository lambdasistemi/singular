{-# LANGUAGE GADTs #-}

-- | The live chapters render their submitted model edge requests.
module Conformance.Story.Usage (spec) where

import Conformance.Book (renderBook)
import Conformance.Edge.EarlyReject qualified as EarlyReject
import Conformance.Edge.Exit qualified as Exit
import Conformance.Edge.Occupied qualified as Occupied
import Conformance.Edge.Register qualified as Register
import Conformance.Edge.Retire qualified as Retire
import Conformance.Edge.RetractionWindow qualified as RetractionWindow
import Conformance.Edge.Sequence qualified as Sequence
import Conformance.Story.Live qualified as Live
import Conformance.Story.Specification qualified as Specification
import Control.Monad.Operational (ProgramViewT (Return, (:>>=)), view)
import Data.Either (isLeft)
import Data.Foldable (forM_)
import Data.List
    ( inits
    , isInfixOf
    , isPrefixOf
    , isSuffixOf
    , nub
    , tails
    )
import Test.Hspec (Spec, it, shouldBe, shouldSatisfy)

spec :: Spec
spec = do
    it
        "Every reject placement validates, renders its book reading and names a window from its opening"
        $ forM_ [minBound .. maxBound :: Live.Placement]
        $ \placement -> forM_ [Nothing, Just Live.ShortByOne, Just Live.OtherAddress] $ \alteration -> do
            let program = placedReject placement alteration
                rendered = Live.renderLive program
                (opens, closes) = Live.placementWindow placement 1_000 10_000 20_000
            Live.validateLive program `shouldBe` Right ()
            rendered `shouldSatisfy` isInfixOf (Live.placementReading placement)
            opens `shouldSatisfy` (>= 1_000)
            closes `shouldSatisfy` maybe True (> opens)
    it
        "Every reject placement is told apart in the book and in the run log"
        $ do
            let placements = [minBound .. maxBound :: Live.Placement]
            length (nub (map Live.placementReading placements))
                `shouldBe` length placements
            length (nub (map Live.placementName placements))
                `shouldBe` length placements
            length
                ( nub
                    (map (\p -> Live.placementWindow p 1_000 10_000 20_000) placements)
                )
                `shouldBe` length placements
    it
        "A fold batch and a reject batch in every window validate and render every request they name, in order"
        $ forM_ [minBound .. maxBound :: Live.Placement]
        $ \placement -> forM_ [[], batchOf ["first"], batchOf ["first", "second", "third"]] $ \requests -> do
            let program = batches placement requests
                rendered = Live.renderLive program
                named =
                    [ "**insertActive** for **" <> Live.requestKey request <> "**"
                    | request <- requests
                    ]
            Live.validateLive program `shouldBe` Right ()
            occurrences "in one transaction" rendered `shouldBe` 2
            occurrences
                "ask the executable registry model the same batch"
                rendered
                `shouldBe` 2
            rendered `shouldSatisfy` isInfixOf (Live.placementReading placement)
            forM_ named $ \phrase -> occurrences phrase rendered `shouldBe` 2
            orderOf named rendered `shouldSatisfy` ascending
            if null requests
                then occurrences "no request in **registry**" rendered `shouldBe` 2
                else occurrences "no request" rendered `shouldBe` 0
    it
        "Story validation refuses a batch placed inside another request's step"
        $ do
            let request = Live.EdgeRequest Live.InsertActive "inside" "holder"
                inside = do
                    step <- Live.submit "registry" request
                    _ <- Live.foldBatch "registry" (batchOf ["first", "second"])
                    observation <- Live.observe step
                    _ <- Live.compareWithModel step observation
                    pure ()
            Live.validateLive
                (batches Live.InProcessingWindow (batchOf ["a", "b"]))
                `shouldBe` Right ()
            Live.validateLive inside `shouldSatisfy` isLeft
    it
        "Story validation refuses a reject that names no window before anything runs"
        $ do
            Live.validateLive unplacedSubmit `shouldSatisfy` isLeft
            Live.validateLive unplacedTamper `shouldSatisfy` isLeft
    it
        "The early rejection chapter rejects three times in each window and compares all six"
        $ do
            let program =
                    EarlyReject.story (Live.Context "early rejection" "holder wallet")
                rendered = Live.renderLive program
            Live.validateLive program `shouldBe` Right ()
            occurrences "Compare **" rendered `shouldBe` 6
            occurrences (Live.placementReading Live.InProcessingWindow) rendered
                `shouldBe` 3
            occurrences (Live.placementReading Live.InRetractionWindow) rendered
                `shouldBe` 3
            occurrences (Live.placementReading Live.AfterTheWindows) rendered
                `shouldBe` 0
            renderBook [] [] `shouldSatisfy` isInfixOf rendered
    it "The exit chapter places its rejects after the windows" $ do
        let rendered =
                Live.renderLive
                    ( Exit.story
                        (Live.Context "rejection" "holder wallet")
                        (Live.Context "retraction" "holder wallet")
                    )
        occurrences (Live.placementReading Live.AfterTheWindows) rendered
            `shouldBe` 3
        rendered `shouldSatisfy` (not . isInfixOf "no longer be folded")
    it
        "The finite window story compares all three retractions and refuses a dropped comparison"
        $ do
            let program =
                    RetractionWindow.story
                        (Live.Context "retraction window" "owner wallet")
                rendered = Live.renderLive program
            Live.validateLive program `shouldBe` Right ()
            occurrences "Compare **" rendered `shouldBe` 3
            rendered `shouldSatisfy` isInfixOf "before phase 2"
            rendered `shouldSatisfy` isInfixOf "after phase 2"
            Live.validateLive (dropFirstCompare program) `shouldSatisfy` isLeft
    it
        "The registration chapter pays its delivery elsewhere and one lovelace short beside its untampered control, then folds two registrations minting both at the first key"
        $ do
            let rendered =
                    Live.renderLive (Register.story (Live.Context "registry" "recipient"))
            rendered
                `shouldSatisfy` isInfixOf "payment it owes sent to another address"
            rendered
                `shouldSatisfy` isInfixOf "payment it owes one lovelace short"
            rendered `shouldSatisfy` isInfixOf "untampered is its control"
            occurrences "in one transaction" rendered `shouldBe` 1
            occurrences
                "Fold, in one transaction with every token the transaction mints moved onto the first request's key, **insertActive** for **minted-a**, **insertActive** for **minted-b**"
                rendered
                `shouldBe` 1
    it
        "The book names the extra required signer only where the registration story submits it"
        $ do
            let phrase = "required signer the model does not require"
                story =
                    Live.renderLive
                        (Register.story (Live.Context "registration" "recipient wallet"))
            occurrences phrase story `shouldSatisfy` (>= 1)
            occurrences phrase (renderBook [] [])
                `shouldBe` occurrences phrase story
    it
        "The book names each admission refusal and its signed control only where the exit story submits it"
        $ do
            let story =
                    Live.renderLive
                        ( Exit.story
                            (Live.Context "rejection" "holder wallet")
                            (Live.Context "retraction" "holder wallet")
                        )
            forM_
                [ "without requiring its owner's signature"
                , "Retract the **updateTerminal** for **pending-update**"
                , "Retract the **insertActive** for **retracted** in **retraction** as its owner, using the holder wallet."
                ]
                $ \phrase -> do
                    occurrences phrase story `shouldSatisfy` (>= 1)
                    occurrences phrase (renderBook [] [])
                        `shouldBe` occurrences phrase story
    it
        "The book states retraction admission and preserves its open-interval and observation limits"
        $ do
            let book = renderBook [] []
            book
                `shouldSatisfy` isInfixOf "The model admits a retraction only when"
            book
                `shouldSatisfy` isInfixOf "Open validity intervals remain a named gap"
            book
                `shouldSatisfy` isInfixOf "The model represents only finite validity bounds"
            book
                `shouldSatisfy` (not . isInfixOf "checked against the compiled Aiken suite")
            book
                `shouldSatisfy` (not . isInfixOf "Retraction admission is not modelled")
            book
                `shouldSatisfy` (not . isInfixOf "no run establishes those two refusals")
    it
        "The book states how refusal reasons are observed and keeps, by row, every refusal not observed or not compared"
        $ do
            let book = renderBook [] []
            forM_
                [ "Refusal reasons come from traced re-evaluation."
                , "The deployed validators are compiled without traces"
                , "evaluated again on the arguments the ledger built for it: once with the deployed bytes, and once with a build of the same source, compiler and parameters that keeps only the validators' own traces"
                , "The receipt names both script hashes"
                , "Three have no counterpart in the model, so their model comparison is unmet"
                , "CS04, a fold redeemer at a wrong constructor index"
                , "so their live refusal reason is not observed (lambdasistemi/singular#347)"
                , "CG10, a fold whose proof was built against a root the registry has since superseded"
                , "so nothing compares with the chain's reason (lambdasistemi/singular#346)"
                , "CG12, a fold carrying an action beyond its requests, and one missing an action: the model takes no action list (lambdasistemi/singular#345)"
                , "CG11, an empty fold, with the fold batch over no request"
                , "CG19, two rejects whose refunds are crossed and two whose first refund is short, with the reject batch judged on the refunds the transaction pays"
                , "CG09's control, a reject refunding its owner one lovelace short, with the reject batch of that one request"
                , "that requirement stays unmet by ruling"
                , "Whether CG11, CG12 and CG19 meet the consuming project's requirements remains unresolved; the three rows stay held."
                ]
                $ \phrase -> book `shouldSatisfy` isInfixOf phrase
            book
                `shouldSatisfy` ( not
                                    . isInfixOf
                                        "Live refusal reason not observed: the deployed validators are compiled without traces"
                                )
            book
                `shouldSatisfy` (not . isInfixOf "every refusal reason is observed")
            book `shouldSatisfy` (not . isInfixOf "agrees with the model")
            book `shouldSatisfy` (not . isInfixOf "driver has no batch question")
            book `shouldSatisfy` (not . isInfixOf "not rendered here")
            book
                `shouldSatisfy` ( not
                                    . isInfixOf
                                        "not compared while the recorded consumer-model conflict holds them"
                                )
    it
        "The book's public limits use no internal class letter or question, and name only public issues"
        $ do
            let limits =
                    [ line
                    | line <- lines (renderBook [] [])
                    , any
                        (`isPrefixOf` line)
                        ["Refusal reasons come from", "Refusals outside these chapters"]
                    ]
            length limits `shouldBe` 2
            forM_ ["(class", "Q-002", "#320", "R9"] $ \token ->
                filter (token `isInfixOf`) limits `shouldBe` []
            -- An issue is named only as a public repository issue.
            forM_ limits $ \line ->
                [prefix | (prefix, '#' : _) <- zip (inits line) (tails line)]
                    `shouldSatisfy` all ("lambdasistemi/singular" `isSuffixOf`)
    it
        "The retirement chapter describes registration and retirement as model edge requests"
        $ do
            let rendered =
                    Live.renderLive
                        ( Retire.story
                            (Live.Context "retirement" "holder")
                            (Live.Context "comparison" "holder")
                        )
            rendered `shouldSatisfy` isInfixOf "Submit **insertActive**"
            rendered `shouldSatisfy` isInfixOf "Submit **updateTerminal**"
            rendered `shouldSatisfy` isInfixOf "Submit **insertAbsent**"
    it
        "The retirement chapter pays a deletion's deposit back elsewhere and one lovelace short beside the untampered deletion"
        $ do
            let rendered =
                    Live.renderLive
                        ( Retire.story
                            (Live.Context "retirement" "holder")
                            (Live.Context "comparison" "holder")
                        )
            rendered
                `shouldSatisfy` isInfixOf
                    "Submit **deleteActive** for **deleted** in **retirement** with the payment it owes one lovelace short"
            rendered
                `shouldSatisfy` isInfixOf
                    "Submit **deleteActive** for **deleted** in **retirement** with the payment it owes sent to another address"
            rendered
                `shouldSatisfy` isInfixOf
                    "Submit **deleteActive** for **deleted** in **retirement**, using the holder."
    it
        "The occupied-key story books its key active through accepted requests, then inserts it again, comparing each"
        $ do
            let program =
                    Occupied.story (Live.Context "occupied insert" "holder wallet")
                rendered = Live.renderLive program
                submitted edge =
                    "Submit **" <> edge <> "** for **occupied** in **occupied insert**"
            Live.validateLive program `shouldBe` Right ()
            occurrences "Compare **" rendered `shouldBe` 3
            filter ("- Submit **" `isPrefixOf`) (lines rendered)
                `shouldBe` [ "- " <> submitted edge <> ", using the holder wallet."
                           | edge <- ["insertAbsent", "updateActive", "insertAbsent"]
                           ]
            Live.validateLive (dropFirstCompare program) `shouldSatisfy` isLeft
    it "accepts the complete unnamed sequence before submitting" $ do
        let original :: Live.Story String String String String String ()
            original = Sequence.story (Live.Context "sequence" "holder")
        Live.validateLive original `shouldSatisfy` (== Right ())
    it "accepts both complete chapters before submitting" $ do
        Live.validateLive
            (Register.story (Live.Context "registry" "recipient"))
            `shouldSatisfy` (== Right ())
        Live.validateLive
            ( Retire.story
                (Live.Context "retirement" "holder")
                (Live.Context "comparison" "holder")
            )
            `shouldSatisfy` (== Right ())
    it
        "refuses the real unnamed sequence with one Compare removed before submitting"
        $ do
            let original :: Live.Story String String String String String ()
                original = Sequence.story (Live.Context "sequence" "holder")
            Live.validateLive (dropFirstCompare original) `shouldSatisfy` isLeft

occurrences :: String -> String -> Int
occurrences needle = length . filter (needle `isPrefixOf`) . tails

-- | Mutation of the actual sequence program: remove exactly its first Compare.
dropFirstCompare
    :: Live.Story String String String String String ()
    -> Live.Story String String String String String ()
dropFirstCompare = go False
  where
    go
        :: Bool
        -> Live.Story String String String String String a
        -> Live.Story String String String String String a
    go removed program = case view program of
        Return result -> pure result
        Specification.Action instruction :>>= next -> case instruction of
            Live.Compare _ _ | not removed -> go True (next "dropped")
            _ -> Specification.action instruction >>= go removed . next
        Specification.Theorem _ _ :>>= _ -> error "unnamed sequence unexpectedly gained a theorem wrapper"

-- | Requests for these keys, each an active registration.
batchOf :: [String] -> [Live.EdgeRequest String]
batchOf keys = [Live.EdgeRequest Live.InsertActive key "holder" | key <- keys]

-- | A fold of these requests, then a reject of them in the given window.
batches
    :: Live.Placement
    -> [Live.EdgeRequest String]
    -> Live.Story String String String String String ()
batches placement requests = do
    _ <- Live.foldBatch "registry" requests
    _ <- Live.rejectBatchWithin placement "registry" requests
    pure ()

-- | Where each phrase first appears in the text.
orderOf :: [String] -> String -> [Int]
orderOf phrases text =
    [ length (takeWhile (not . (phrase `isPrefixOf`)) (tails text))
    | phrase <- phrases
    ]

ascending :: [Int] -> Bool
ascending positions = and (zipWith (<) positions (drop 1 positions))

-- | One reject in the given window, observed and compared.
placedReject
    :: Live.Placement
    -> Maybe Live.Tamper
    -> Live.Story String String String String String ()
placedReject placement alteration = do
    let request = Live.EdgeRequest Live.InsertActive "placed" "holder"
    step <- case alteration of
        Nothing -> Live.rejectWithin placement "registry" request
        Just tampered -> Live.tamperRejectWithin tampered placement "registry" request
    observation <- Live.observe step
    _ <- Live.compareWithModel step observation
    pure ()

-- | A reject submitted without a placement, which validation must refuse.
unplacedSubmit :: Live.Story String String String String String ()
unplacedSubmit = do
    let request = Live.EdgeRequest Live.InsertActive "unplaced" "holder"
    step <-
        Specification.action (Live.Submit Live.Reject "registry" request)
    observation <- Live.observe step
    _ <- Live.compareWithModel step observation
    pure ()

-- | A tampered reject without a placement, which validation must refuse.
unplacedTamper :: Live.Story String String String String String ()
unplacedTamper = do
    let request = Live.EdgeRequest Live.InsertActive "unplaced" "holder"
    step <- Live.tamperExit Live.ShortByOne Live.Reject "registry" request
    observation <- Live.observe step
    _ <- Live.compareWithModel step observation
    pure ()
