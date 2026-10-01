{-# LANGUAGE LambdaCase #-}

{- | The extent of a run's refusals: every refusal of the replay index is class
A by an executed model reason or listed in the committed table, each once,
with an accepting control for each refusing script role. Each way a run can
fall short is its own case against a complete fixture run.
-}
module Conformance.Support.Extent (spec) where

import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

import Conformance.Extent
import Conformance.Receipt
    ( Outcome (..)
    , Receipt (..)
    , RefusalInfo (..)
    , Verdict (..)
    )

spec :: Spec
spec = describe "the extent of a run's refusals" $ do
    describe "the committed table" $ do
        it "reads each listed row's class from the discovered table only" $
            committedClasses document
                `shouldBe` Right
                    ( Map.fromList
                        [ ("CG10", ClassC)
                        , ("CG11", ClassD)
                        , ("CS04", ClassC)
                        , ("CG05", ClassB)
                        ]
                    )
        it "refuses a table that gives a row a class it cannot have" $
            committedClasses (document <> "| CG99 | made up | x | y | A |\n")
                `shouldSatisfy` either (const True) (const False)
        it "refuses a document without the discovered table" $
            committedClasses "# Refusal extent\n\nNo table.\n"
                `shouldSatisfy` either (const True) (const False)
    describe "a run's index against its receipts" $ do
        it
            "accepts a run whose every refusal is accounted for, and counts them"
            $ do
                extentProblems table completeIndex completeReceipts `shouldBe` []
                extentCount table completeIndex
                    `shouldBe` ExtentCount 2 (Map.fromList [(ClassC, 1)])
        it "refuses a run with no refusal at all" $
            extentProblems table [controlEntry] []
                `shouldSatisfy` mentions "no refusal"
        it "refuses a refusal the index names twice" $
            extentProblems
                table
                (completeIndex <> [driverEntry "tx-a" "key-exists" "agrees"])
                completeReceipts
                `shouldSatisfy` mentions "tx-a"
        it "refuses a refusal a receipt records that the index does not name" $
            extentProblems
                table
                (filter (not . isEntry "tx-c") completeIndex)
                completeReceipts
                `shouldSatisfy` mentions "tx-c"
        it "refuses a refusal with an executed model reason relabelled B" $
            extentProblems
                table
                (relabel "tx-a" "B" completeIndex)
                completeReceipts
                `shouldSatisfy` mentions "tx-a"
        it "refuses a class-A refusal whose reason differs from the replay's" $
            extentProblems
                table
                (replaceEntry (driverEntry "tx-a" "key-exists" "differs") completeIndex)
                completeReceipts
                `shouldSatisfy` mentions "tx-a"
        it "refuses an uncompared class-A refusal that names no cause" $
            extentProblems
                table
                ( replaceEntry
                    (withClasses [] (driverEntry "tx-a" "key-exists" "uncompared"))
                    completeIndex
                )
                completeReceipts
                `shouldSatisfy` mentions "tx-a"
        it "accepts an uncompared class-A refusal with its cause" $
            extentProblems
                table
                ( replaceEntry
                    ( withClasses
                        [object ["unobserved" .= ("no-user-trace" :: Text)]]
                        (driverEntry "tx-a" "key-exists" "uncompared")
                    )
                    completeIndex
                )
                completeReceipts
                `shouldBe` []
        it "refuses a step's model reason the index did not record" $
            extentProblems
                table
                (replaceEntry (attributionEntry "CG21" "tx-a") completeIndex)
                completeReceipts
                `shouldSatisfy` mentions "tx-a"
        it "refuses a refusal without a model reason labelled A" $
            extentProblems
                table
                (relabel "tx-c" "A" completeIndex)
                completeReceipts
                `shouldSatisfy` mentions "tx-c"
        it "refuses an attribution refusal the table does not list" $
            extentProblems
                table
                (completeIndex <> [attributionEntry "CG77" "tx-x"])
                completeReceipts
                `shouldSatisfy` mentions "CG77"
        it "refuses a refusing script role without an accepting control" $
            extentProblems
                table
                (filter (not . isControl) completeIndex)
                completeReceipts
                `shouldSatisfy` mentions "state.state"
  where
    mentions needle = any (needle `T.isInfixOf`)

table :: Map.Map Text ExtentClass
table = Map.fromList [("CG10", ClassC), ("CS04", ClassC)]

-- | The extent document's shape: a leads table first, then the discovered one.
document :: Text
document =
    T.unlines
        [ "# Refusal extent against the model"
        , ""
        , "## Leads"
        , ""
        , "| Row | Refusal | Lean | Consumer | Class (lead) |"
        , "|---|---|---|---|---|"
        , "| CG07 | retraction outside phase 2 | `not-phase2` | driver | A |"
        , ""
        , "## Discovered table (T028)"
        , ""
        , "| Row | Refusal | Traced reason | Lean | Class |"
        , "|---|---|---|---|---|"
        , "| CG05 | insert on a present key | `key-exists` | `key-exists` | B until then |"
        , "| CG11 | empty fold | `empty-fold` | held | D (existing) |"
        , "| CG10 | stale root | `key-exists` | not an input | C |"
        , "| CS04 | wrong index | `no-user-trace` | below the model | C |"
        , ""
        , "Gaps stay in the denominator."
        ]

-- | Two class-A refusals of a story, one CG10 attribution, a control.
completeIndex :: [Value]
completeIndex =
    [ driverEntry "tx-a" "key-exists" "agrees"
    , driverEntry "tx-b" "deposit-returned" "agrees"
    , attributionEntry "CG10" "tx-c"
    , controlEntry
    ]

completeReceipts :: [Receipt]
completeReceipts =
    [ storyReceipt
        "CG21"
        [ refusedStep "tx-a" "key-exists"
        , refusedStep "tx-b" "deposit-returned"
        ]
    , attributionReceipt "CG10" "tx-c"
    ]

refusalEntry :: Text -> Text -> Value -> Text -> Value -> Value
refusalEntry row txid model extent comparison =
    object
        [ "kind" .= ("refusal" :: Text)
        , "rejectedTxId" .= txid
        , "row" .= row
        , "role" .= ("state.state" :: Text)
        , "classes" .= [object ["admitted" .= ("key-exists" :: Text)]]
        , "extentClass" .= extent
        , "modelReason" .= model
        , "comparison" .= comparison
        ]

driverEntry :: Text -> Text -> Text -> Value
driverEntry txid reason comparison =
    refusalEntry "CG21" txid (String reason) "A" (String comparison)

attributionEntry :: Text -> Text -> Value
attributionEntry row txid = refusalEntry row txid Null "unclassified" Null

controlEntry :: Value
controlEntry =
    object
        [ "kind" .= ("accepting-control" :: Text)
        , "controls"
            .= [ object
                    [ "role" .= ("state.state" :: Text)
                    , "deployed" .= object ["outcome" .= ("succeeded" :: Text)]
                    , "traced" .= object ["outcome" .= ("succeeded" :: Text)]
                    ]
               ]
        ]

isEntry :: Text -> Value -> Bool
isEntry txid entry = rejectedOf entry == Just txid

isControl :: Value -> Bool
isControl entry = textField "kind" entry == Just "accepting-control"

rejectedOf :: Value -> Maybe Text
rejectedOf = textField "rejectedTxId"

textField :: Key.Key -> Value -> Maybe Text
textField name = \case
    Object o | Just (String t) <- KM.lookup name o -> Just t
    _ -> Nothing

setKey :: Key.Key -> Value -> Value -> Value
setKey name value = \case
    Object o -> Object (KM.insert name value o)
    other -> other

replaceEntry :: Value -> [Value] -> [Value]
replaceEntry new = map (\e -> if rejectedOf e == rejectedOf new then new else e)

relabel :: Text -> Text -> [Value] -> [Value]
relabel txid extent =
    map
        ( \e ->
            if isEntry txid e then setKey "extentClass" (String extent) e else e
        )

withClasses :: [Value] -> Value -> Value
withClasses classes = setKey "classes" (toJSON classes)

storyReceipt :: Text -> [Value] -> Receipt
storyReceipt row steps =
    baseReceipt
        { receiptRow = row
        , receiptOutcome = Accepted
        , receiptTransactions = ["tx-landed"]
        , receiptSteps = Just steps
        }

attributionReceipt :: Text -> Text -> Receipt
attributionReceipt row txid =
    baseReceipt
        { receiptRow = row
        , receiptOutcome = Refused
        , receiptRejected = Just txid
        , receiptRefusal =
            Just
                RefusalInfo
                    { refusalScript = "state"
                    , refusalReason = "phase-2"
                    , refusalPhase = "phase-2"
                    , refusalHashes = ["abcdef"]
                    , refusalBranch = Nothing
                    , refusalReplay = Nothing
                    , refusalLimit = Just "no branch"
                    }
        }

refusedStep :: Text -> Text -> Value
refusedStep txid reason =
    object
        [ "model"
            .= object ["outcome" .= ("refused" :: Text), "reason" .= reason]
        , "chain" .= object ["outcome" .= ("refused" :: Text), "txid" .= txid]
        ]

baseReceipt :: Receipt
baseReceipt =
    Receipt
        { receiptRow = ""
        , receiptOutcome = Accepted
        , receiptVerdict = AgreesWithModel
        , receiptTransactions = []
        , receiptRefusal = Nothing
        , receiptMem = Nothing
        , receiptCpu = Nothing
        , receiptTxSize = Nothing
        , receiptBase = "base"
        , receiptNode = "node"
        , receiptBlueprint = "blueprint"
        , receiptVenue = "node-submit"
        , receiptRejected = Nothing
        , receiptDirty = False
        , receiptPartial = Nothing
        , receiptDerivation = Nothing
        , receiptSteps = Nothing
        , receiptReplayCorrespondence = Nothing
        }
