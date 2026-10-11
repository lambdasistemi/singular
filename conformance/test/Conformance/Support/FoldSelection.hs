{-# LANGUAGE LambdaCase #-}

{- |
Module      : Conformance.Support.FoldSelection
Description : What the selection settles is what the model accepts (#518)
License     : Apache-2.0

Pull request 1 of #518 judges every pending request alone and settles one
per fold. This spec proves that what the selection settles is what the
model accepts: the conformance unit suite asks the model's batch question
about the selected batch and requires acceptance, and its negative control
shows the question refusing a same-key batch.

For a registry state and a pending list, it runs 'selectFold', turns the
settled list into the model's batch of requests, and asks the model's
'foldBatch' question through the driver transport the conformance package
already uses. Acceptance is required exactly when the settled list is
non-empty; an empty settled list expects the model's refusal 'empty-fold'.
The effect comparison of state, mint and paid with what the built fold
produces belongs to the hosted batch row
(batch-instructions-asked-of-the-model), not to this unit run: no effect
table and no literal list of payments remains in this spec.
-}
module Conformance.Support.FoldSelection (spec) where

import Conformance.Lean.Oracle (expectedObservation)
import Control.Monad (when)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Bits (shiftR, xor, (.&.))
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (nub, sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word64, Word8)
import System.Environment (lookupEnv)
import Test.Hspec (Spec, describe, it, runIO, shouldBe, shouldSatisfy)
import Test.QuickCheck (Gen, choose, elements, generate, vectorOf)

import Singular.Registry.FoldSelection
    ( AppVerdict (..)
    , ApprovalCheck (..)
    , EdgeKind (..)
    , Leaf (..)
    , LiveFacts
    , PendingRequest (..)
    , SelectedRequest (..)
    , Selection (..)
    , selectFold
    )

-- ---------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------

-- | A variable the package wires, or a failure naming it.
wired :: String -> IO FilePath
wired name =
    lookupEnv name
        >>= maybe
            (error (name <> " is not wired; the transport has nothing to ask"))
            pure

-- ---------------------------------------------------------
-- Model identities (inputs only)
-- ---------------------------------------------------------

-- | The pinned policies the driver corpus uses.
applicationPolicy :: Int
applicationPolicy = 7

activePolicy :: Int
activePolicy = 8

-- | The model's deposit for a booked request, as the corpus spells it.
depositOf :: SelectedRequest -> Int
depositOf _ = 55

-- | The output a delivered token is routed to, derived from the key.
outputOf :: SelectedRequest -> Int
outputOf sel = 500 + selKey sel

-- | The owner's model identity, derived from the owner's text.
ownerNatOf :: SelectedRequest -> Int
ownerNatOf sel =
    1000
        + T.foldl'
            (\acc c -> (acc * 33 + fromEnum c) `mod` 9000)
            5381
            (selOwner sel)

{- | The model's edge spelling for a settled edge. Excluded edges never
settle, so 'Nothing' never reaches the batch question.
-}
edgeSpellingOf :: EdgeKind -> Maybe Text
edgeSpellingOf EdgeInsertActive = Just "insertActive"
edgeSpellingOf EdgeUpdateTerminal = Just "updateTerminal"
edgeSpellingOf (EdgeOther _) = Nothing

-- ---------------------------------------------------------
-- Model commitment function (inputs only)
-- ---------------------------------------------------------

-- | FNV-1a over a byte list, as the model commits.
fnv1a :: [Word8] -> Word64
fnv1a =
    foldl
        (\h b -> (h `xor` fromIntegral b) * 16777619)
        14695981039346656037

-- | Big-endian bytes of a word, as the model commits.
u64bytes :: Word64 -> [Word8]
u64bytes n =
    [ fromIntegral ((n `shiftR` s) .&. 0xFF)
    | s <- [56, 48, 40, 32, 24, 16, 8, 0]
    ]

-- | The leaf byte the model commits with.
leafByteOf :: Text -> Word8
leafByteOf "absent" = 0x00
leafByteOf "active" = 0x01
leafByteOf "terminal" = 0x02
leafByteOf _ = 0xFF

-- | The model's root over the sorted pairs, as numbers for JSON.
rootNumbersOf :: [(Int, Text)] -> [Int]
rootNumbersOf pairs =
    let sorted = sort pairs
        keyByte k = fromIntegral (k `mod` 256) :: Word8
        bytes =
            concatMap
                ( \(k, leaf) -> u64bytes (fnv1a [keyByte k]) ++ [keyByte k, leafByteOf leaf]
                )
                sorted
    in  map fromIntegral (u64bytes (fnv1a bytes))

-- ---------------------------------------------------------
-- Registry state as the model reads it (inputs only)
-- ---------------------------------------------------------

-- | The model's trie pairs for facts, omitting unknown keys.
triePairsOf :: LiveFacts -> [(Int, Text)]
triePairsOf facts =
    [ (k, leafSpelling leaf)
    | (k, (leaf, _)) <- Map.toList facts
    , leaf /= LeafUnknown
    ]
  where
    leafSpelling LeafUnknown = "unknown"
    leafSpelling LeafAbsent = "absent"
    leafSpelling LeafActive = "active"
    leafSpelling LeafTerminal = "terminal"

-- | The held output for an active key with its token live.
heldOutputOf :: Int -> Int
heldOutputOf k = 500 + k

{- | The start state for facts: trie, held for live active tokens, custody
for absent keys so the premise holds.
-}
startJsonOf :: LiveFacts -> Value
startJsonOf facts =
    let triePairs = triePairsOf facts
        rootNumbers = rootNumbersOf triePairs
        trieJson =
            [ object ["key" .= k, "leaf" .= leaf]
            | (k, leaf) <- triePairs
            ]
        heldJson =
            [ object
                [ "key" .= k
                , "kind" .= ("active" :: Text)
                , "output" .= heldOutputOf k
                , "datum" .= Null
                ]
            | (k, (LeafActive, True)) <- Map.toList facts
            ]
        custodyJson =
            [ object
                ["key" .= k, "refundAddress" .= (0 :: Int), "value" .= (55 :: Int)]
            | (k, (LeafAbsent, _)) <- Map.toList facts
            ]
        configJson =
            object
                [ "root" .= rootNumbers
                , "maxFee" .= (0 :: Int)
                , "processTime" .= (0 :: Int)
                , "retractTime" .= (0 :: Int)
                , "applicationPolicy" .= applicationPolicy
                , "activePolicy" .= activePolicy
                , "absentPolicy" .= (9 :: Int)
                , "terminalPolicy" .= (10 :: Int)
                ]
    in  object
            [ "config" .= configJson
            , "trie" .= trieJson
            , "custody" .= custodyJson
            , "held" .= heldJson
            ]

-- ---------------------------------------------------------
-- Selected batch as the model's batch
-- ---------------------------------------------------------

{- | One settled request as the model's request, asking for the claim an
honest folder makes and for the approval this very request carries.
-}
requestJsonOf :: SelectedRequest -> Value
requestJsonOf sel = case edgeSpellingOf (selEdge sel) of
    Just edge ->
        object
            [ "edge" .= edge
            , "key" .= selKey sel
            , "owner" .= ownerNatOf sel
            , "refundAddress" .= (0 :: Int)
            , "deposit" .= depositOf sel
            , "output" .= outputOf sel
            , "approval" .= ("canonical" :: Text)
            , "applicationPolicy" .= applicationPolicy
            , "claimed" .= ("canonical" :: Text)
            ]
    Nothing -> Null

-- | The conversion from the settled list to the model's batch, in order.
toModelBatch :: [SelectedRequest] -> [Value]
toModelBatch = map requestJsonOf

-- | The batch question about the selected batch.
questionJsonOf :: LiveFacts -> [SelectedRequest] -> Value
questionJsonOf facts settled =
    object
        [ "id" .= ("fold-selection-agreement" :: Text)
        , "theorem" .= ("Singular.Statements.fold_batch_cons" :: Text)
        , "statementSha256"
            .= ( "9e8c6a06d60361ae94b24f50f014c7830bfdd5d22aa8b7a62a8ca9230f689153"
                    :: Text
               )
        , "question" .= ("foldBatch" :: Text)
        , "start" .= startJsonOf facts
        , "setup" .= ([] :: [Value])
        , "requests" .= toModelBatch settled
        ]

-- ---------------------------------------------------------
-- Reading the model's answer (no effect tables)
-- ---------------------------------------------------------

field :: Key.Key -> Value -> Maybe Value
field name (Object fields) = KM.lookup name fields
field _ _ = Nothing

-- | Require acceptance of a non-empty selected batch.
requireAccepted :: Value -> IO ()
requireAccepted answer = do
    field "outcome" answer `shouldBe` Just (String "accepted")
    field "reason" answer `shouldBe` Just Null

{- | Check a refusal with the first refusing step's reason. 'Right' only for
the refused reason; an accepting answer reports failure.
-}
checkRefused :: Text -> Value -> Either String ()
checkRefused expected answer = case (field "outcome" answer, field "reason" answer) of
    (Just (String "refused"), Just (String got)) ->
        if got == expected
            then Right ()
            else Left ("refused for another reason: " <> T.unpack got)
    (Just (String "accepted"), _) ->
        Left "the model accepted a batch it must refuse"
    _ -> Left "the model's answer is neither accepted nor refused"

-- ---------------------------------------------------------
-- The spec's four-request example
-- ---------------------------------------------------------

nowMs :: Integer
nowMs = 1000000

marginMs :: Integer
marginMs = 30000

farDeadline :: Integer
farDeadline = nowMs + 1000000

nearDeadline :: Integer
nearDeadline = nowMs + 10000

mkInsert :: Int -> Int -> Text -> Integer -> PendingRequest
mkInsert ref key owner deadline =
    PendingRequest
        { prRef = ref
        , prKey = key
        , prOwner = owner
        , prEdge = EdgeInsertActive
        , prDeadline = deadline
        , prDecodeOk = True
        , prApproval = ApprovalOk
        , prApp = AppReady
        }

mkTerminate :: Int -> Int -> Text -> Integer -> PendingRequest
mkTerminate ref key owner deadline =
    PendingRequest
        { prRef = ref
        , prKey = key
        , prOwner = owner
        , prEdge = EdgeUpdateTerminal
        , prDeadline = deadline
        , prDecodeOk = True
        , prApproval = ApprovalOk
        , prApp = AppReady
        }

exampleFacts :: LiveFacts
exampleFacts =
    Map.fromList
        [ (7, (LeafUnknown, False))
        , (9, (LeafActive, True))
        , (11, (LeafUnknown, False))
        ]

r1 :: PendingRequest
r1 = mkInsert 1 7 "Alice" farDeadline

r2 :: PendingRequest
r2 = mkTerminate 2 9 "Bob" farDeadline

r3 :: PendingRequest
r3 = mkInsert 3 7 "Carol" farDeadline

r4 :: PendingRequest
r4 = mkInsert 4 11 "Dana" nearDeadline

examplePending :: [PendingRequest]
examplePending = [r1, r2, r3, r4]

-- ---------------------------------------------------------
-- Generators
-- ---------------------------------------------------------

{- | One fact key: unknown or active with its token live, so the start
premise holds.
-}
genFactEntry :: Gen (Int, (Leaf, Bool))
genFactEntry = do
    key <- choose (20, 40)
    active <- elements [True, False]
    pure
        ( key
        , if active then (LeafActive, True) else (LeafUnknown, False)
        )

genFacts :: Gen LiveFacts
genFacts = Map.fromList <$> vectorOf 3 genFactEntry

-- | A pending insertion or termination on a fact key.
genPendingOn :: [(Int, (Leaf, Bool))] -> Int -> Gen PendingRequest
genPendingOn factList ref = do
    (key, _) <- elements factList
    edge <- elements [EdgeInsertActive, EdgeUpdateTerminal]
    let owner = T.pack ("owner-" <> show key)
    pure
        PendingRequest
            { prRef = ref
            , prKey = key
            , prOwner = owner
            , prEdge = edge
            , prDeadline = farDeadline
            , prDecodeOk = True
            , prApproval = ApprovalOk
            , prApp = AppReady
            }

spec :: Spec
spec = describe "What the selection settles is what the model accepts" $ do
    evaluator <- runIO (wired "CONFORMANCE_MODEL_EVALUATOR")
    describe "selection-agrees-with-the-model-batch" $ do
        it "accepts the four-request selection at bounds 1, 2 and 9" $ do
            mapM_
                ( \bound -> do
                    let settled =
                            selectionSettled
                                (selectFold bound nowMs marginMs exampleFacts examplePending)
                    answer <-
                        either error pure
                            =<< expectedObservation evaluator [] (questionJsonOf exampleFacts settled)
                    requireAccepted answer
                )
                [1, 2, 9]
        it
            "accepts non-empty generated selections and refuses empty ones with empty-fold"
            $ do
                sawNonEmpty <- newIORef False
                sawMulti <- newIORef False
                factsList <- mapM (const (generate genFacts)) [1 .. 8 :: Int]
                mapM_
                    ( \facts ->
                        mapM_
                            ( \bound -> do
                                refs <-
                                    mapM (const (generate (choose (1, 100 :: Int)))) [1 .. 3 :: Int]
                                pending <- mapM (generate . genPendingOn (Map.toList facts)) refs
                                let settled =
                                        selectionSettled
                                            (selectFold bound nowMs marginMs facts pending)
                                answer <-
                                    either error pure
                                        =<< expectedObservation evaluator [] (questionJsonOf facts settled)
                                if null settled
                                    then checkRefused "empty-fold" answer `shouldBe` Right ()
                                    else do
                                        requireAccepted answer
                                        writeIORef sawNonEmpty True
                                        let keys = nub (map selKey settled)
                                        when (length settled >= 2 && length keys >= 2) $
                                            writeIORef sawMulti True
                            )
                            [1, 2, 9]
                    )
                    factsList
                readIORef sawNonEmpty >>= (`shouldBe` True)
                readIORef sawMulti >>= (`shouldBe` True)
        it "asks more than one key and request, with both admitted edges" $ do
            let settled =
                    selectionSettled
                        (selectFold 9 nowMs marginMs exampleFacts examplePending)
                keys = nub (map selKey settled)
                edges = nub (map selEdge settled)
            length settled `shouldSatisfy` (>= 2)
            length keys `shouldSatisfy` (>= 2)
            edges
                `shouldSatisfy` (\es -> EdgeInsertActive `elem` es && EdgeUpdateTerminal `elem` es)
    describe "same-key-batch-is-refused-by-the-model" $ do
        it
            "refuses two inserts on one key with the first refusing step's reason"
            $ do
                let first = mkInsert 201 7 "Alice" farDeadline
                    second = mkInsert 202 7 "Carol" farDeadline
                    facts = Map.fromList [(7, (LeafUnknown, False))]
                    sel = selectFold 9 nowMs marginMs facts [first, second]
                length (selectionSettled sel) `shouldBe` 1
                let pair =
                        [ requestJsonOf
                            (SelectedRequest 201 7 "Alice" EdgeInsertActive farDeadline)
                        , requestJsonOf
                            (SelectedRequest 202 7 "Carol" EdgeInsertActive farDeadline)
                        ]
                    question =
                        object
                            [ "id" .= ("fold-selection-same-key-control" :: Text)
                            , "theorem" .= ("Singular.Statements.fold_batch_cons" :: Text)
                            , "statementSha256"
                                .= ( "9e8c6a06d60361ae94b24f50f014c7830bfdd5d22aa8b7a62a8ca9230f689153"
                                        :: Text
                                   )
                            , "question" .= ("foldBatch" :: Text)
                            , "start" .= startJsonOf facts
                            , "setup" .= ([] :: [Value])
                            , "requests" .= pair
                            ]
                answer <-
                    either error pure =<< expectedObservation evaluator [] question
                checkRefused "key-exists" answer `shouldBe` Right ()
        it
            "shows the control able to fail: the same check against an accepting answer reports failure"
            $ do
                let accepted =
                        object
                            [ "outcome" .= ("accepted" :: Text)
                            , "reason" .= Null
                            ]
                checkRefused "key-exists" accepted `shouldSatisfy` \case
                    Left _ -> True
                    Right _ -> False
