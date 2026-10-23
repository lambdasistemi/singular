{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.PageSpec
Description : The registry page renders one JSON value
License     : Apache-2.0

The page is a pure value from explicit inputs: its JSON rendering carries
the facts in a fixed order with no clock, tip or session, and a missing,
unreadable or malformed version is refused by name.
-}
module Singular.Registry.PageSpec (spec) where

import Control.Monad (forM_)
import Data.Aeson (Value (..), (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BL
import Data.Either (isLeft)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Test.Hspec

import Singular.Registry.Page
    ( PageInputs (..)
    , PageRefusal (..)
    , ReleaseInfo (..)
    , ReleaseLinks (..)
    , describeRegistry
    , parseVersionLabel
    , releaseLinks
    , renderPageJson
    , renderPageRefusal
    )

spec :: Spec
spec = describe "Singular.Registry.Page" $ do
    it "renders identical bytes for identical inputs" $ do
        let page = describeRegistry sampleInputs
        renderPageJson page
            `shouldBe` renderPageJson (describeRegistry sampleInputs)
    it "orders pending requests canonically" $ do
        let forwards = sampleInputs{pagePendingRequests = [entryA, entryB]}
            backwards = sampleInputs{pagePendingRequests = [entryB, entryA]}
        renderPageJson (describeRegistry forwards)
            `shouldBe` renderPageJson (describeRegistry backwards)
    it "links the claimed version" $ do
        let links = releaseLinks sampleRelease
        linkRelease links `shouldSatisfy` T.isInfixOf "v0.10.1"
        linkDocs links `shouldSatisfy` T.isInfixOf "0.10.1"
    it "states the four provenance limits" $ do
        let rendered =
                [ TE.decodeUtf8
                    ( BL.toStrict
                        (Aeson.encode (renderPageJson (describeRegistry sampleInputs)))
                    )
                ]
        forM_ rendered $ \page ->
            forM_
                [ "from create to the live state output"
                , "Koios"
                , "unverified"
                , "archive's own claim"
                , "unsigned"
                ]
                $ \statement -> page `shouldSatisfy` T.isInfixOf statement
    it "never words anything as verified" $ do
        let rendered =
                [ TE.decodeUtf8
                    ( BL.toStrict
                        (Aeson.encode (renderPageJson (describeRegistry sampleInputs)))
                    )
                ]
        forM_ rendered $ \page ->
            scrubVerified page `shouldSatisfy` (not . T.isInfixOf "verified")
    it "parses a version label or refuses it by name" $ do
        parseVersionLabel "0.10.1" `shouldBe` Right "0.10.1"
        parseVersionLabel "" `shouldSatisfy` isLeft
        parseVersionLabel "not a version" `shouldSatisfy` isLeft
        renderPageRefusal VersionMissing
            `shouldSatisfy` T.isInfixOf "version-missing"
        renderPageRefusal (VersionMalformed "not a version")
            `shouldSatisfy` T.isInfixOf "version-malformed"
        renderPageRefusal (VersionUnreadable "denied")
            `shouldSatisfy` T.isInfixOf "version-unreadable"

-- | A rendered page with every allowed wording of verification removed.
scrubVerified :: Text -> Text
scrubVerified = T.replace "unverified" "" . T.replace "not verified" ""

sampleRelease :: ReleaseInfo
sampleRelease =
    ReleaseInfo
        { releaseVersion = "0.10.1"
        , releaseBlueprintTitle = "singular-test"
        , releaseBlueprintSha = T.replicate 64 "0"
        }

sampleInputs :: PageInputs
sampleInputs =
    PageInputs
        { pageStateToken = T.replicate 56 "a" <> "." <> T.replicate 64 "b"
        , pageAddress = Just "singular_devnet1address"
        , pageFingerprint = "asset1fingerprint"
        , pageStateOutput = T.replicate 64 "c" <> "#0"
        , pageStateScript = T.replicate 56 "d"
        , pageApplicationScript = T.replicate 56 "e"
        , pageApplicationPin = "not-checked-against-any-blueprint"
        , pageActiveScript = T.replicate 56 "f"
        , pageRelease = sampleRelease
        , pageProcessTime = 600000
        , pageRetractTime = 300000
        , pageTip = 1000000
        , pageMaxKeyBytes = 32
        , pageRoot = T.replicate 64 "2"
        , pageActiveKeys = 1
        , pageTerminalKeys = 1
        , pageFoldsSinceCreate = 2
        , pageCreateTransaction = T.replicate 64 "3"
        , pageLastFold = Just (T.replicate 64 "4")
        , pagePendingRequests = [entryA, entryB]
        }

entryA :: Value
entryA =
    pendingEntry (T.replicate 64 "a" <> "#0") $
        Aeson.object
            [ "lovelace" .= (5000000 :: Integer)
            , "assets"
                .= [ Aeson.object
                        [ "policy" .= T.replicate 56 "2"
                        , "name" .= ("6161" :: Text)
                        , "quantity" .= (1 :: Integer)
                        ]
                   ]
            ]

entryB :: Value
entryB =
    pendingEntry (T.replicate 64 "b" <> "#0") $
        Aeson.object
            ["lovelace" .= (2000000 :: Integer), "assets" .= ([] :: [Value])]

pendingEntry :: Text -> Value -> Value
pendingEntry ref locked =
    Aeson.object
        [ "request" .= ref
        , "owner" .= T.replicate 56 "3"
        , "key" .= ("6161" :: Text)
        , "edge" .= ("insertActive" :: Text)
        , "submittedAt" .= (1700000000000 :: Integer)
        , "locked" .= locked
        ]
