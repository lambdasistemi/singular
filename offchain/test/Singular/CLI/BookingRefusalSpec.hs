{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.BookingRefusalSpec
Description : S6.1 RED — the early booking refusal decides the Lean table
License     : Apache-2.0

The oracle is Lean @transition@ (@lean\/Singular\/Model.lean@: the two
admitted edges and their before-leaves — @insertActive@ from @unknown@,
@updateTerminal@ from @active@ — under the M1 admission that refuses
every other edge): each row's expected value is that table's answer for
its (verb, found leaf), never a value read from a builder's output. A
payload update needs the key live exactly as a termination does, so it
decides like one. The key is an arbitrary label: only the decision and
the reason it carries are compared.
-}
module Singular.CLI.BookingRefusalSpec (spec) where

import Data.Aeson (toJSON)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Test.Hspec

import Singular.CLI.Booking
    ( BookingRefusal (..)
    , BookingVerb (..)
    , bookingEdgeName
    , bookingRefusal
    , refusalFields
    , refusalReason
    , requiredLeaf
    )
import Singular.CLI.Proof (Leaf (..), leafName)
import Singular.CLI.Registry (hexT)

key :: ByteString
key = "Alice"

-- | The decision the Lean table gives for its verb and found leaf.
decides :: BookingVerb -> Leaf -> Maybe (Leaf, Leaf)
decides verb found = case bookingRefusal verb key found of
    Nothing -> Nothing
    Just r -> Just (brFound r, brRequired r)

spec :: Spec
spec = describe "the early booking refusal" $ do
    describe "an insertion (insertActive, needs unknown)" $ do
        it "books an unknown key" $
            decides BookInsert Unknown `shouldBe` Nothing
        it "refuses an active key, needing unknown" $
            decides BookInsert Active `shouldBe` Just (Active, Unknown)
        it "refuses a terminal key, needing unknown" $
            decides BookInsert Terminal `shouldBe` Just (Terminal, Unknown)
        it "refuses an absent key, needing unknown" $
            decides BookInsert Absent `shouldBe` Just (Absent, Unknown)
        it "names a taken key as already registered, labelled client policy" $
            case bookingRefusal BookInsert key Active of
                Just r ->
                    refusalReason r
                        `shouldBe` "Alice is already registered (client policy)"
                Nothing -> expectationFailure "an active key books"
    describe "a termination (updateTerminal, needs active)" $ do
        it "books an active key" $
            decides BookTerminate Active `shouldBe` Nothing
        it "refuses an unknown key, needing active" $
            decides BookTerminate Unknown `shouldBe` Just (Unknown, Active)
        it "refuses a terminal key, needing active" $
            decides BookTerminate Terminal `shouldBe` Just (Terminal, Active)
        it "refuses an absent key, needing active" $
            decides BookTerminate Absent `shouldBe` Just (Absent, Active)
        it "names an unknown key as not registered, labelled client policy" $
            case bookingRefusal BookTerminate key Unknown of
                Just r ->
                    refusalReason r
                        `shouldBe` "Alice is not registered (client policy)"
                Nothing -> expectationFailure "an unknown key books"
    describe "a payload update (needs the key live)" $ do
        it "updates an active key" $
            decides BookUpdate Active `shouldBe` Nothing
        it "refuses an unknown key, needing active" $
            decides BookUpdate Unknown `shouldBe` Just (Unknown, Active)
        it "refuses a terminal key, needing active" $
            decides BookUpdate Terminal `shouldBe` Just (Terminal, Active)
        it "refuses an absent key, needing active" $
            decides BookUpdate Absent `shouldBe` Just (Absent, Active)
    describe "the refusal's structured fields" $ do
        -- The field names are the receipt contract; the values come
        -- from the producer's own vocabulary over the Lean table's
        -- leaves, never typed twice.
        let fields verb found = case bookingRefusal verb key found of
                Just r -> pure (refusalFields r)
                Nothing ->
                    expectationFailure "the decided refusal books" >> pure []
            at = lookup
        it "names the insert edge, the leaves and the client label" $ do
            fs <- fields BookInsert Active
            at "edge" fs `shouldBe` Just (toJSON (bookingEdgeName BookInsert))
            at "leafFound" fs `shouldBe` Just (toJSON (leafName Active))
            at "leafRequired" fs
                `shouldBe` Just (toJSON (leafName (requiredLeaf BookInsert)))
            at "policy" fs `shouldBe` Just (toJSON ("client" :: Text))
            at "key" fs `shouldBe` Just (toJSON (hexT key))
        it "names the terminate edge, the leaves and the client label" $ do
            fs <- fields BookTerminate Unknown
            at "edge" fs `shouldBe` Just (toJSON (bookingEdgeName BookTerminate))
            at "leafFound" fs `shouldBe` Just (toJSON (leafName Unknown))
            at "leafRequired" fs
                `shouldBe` Just (toJSON (leafName (requiredLeaf BookTerminate)))
            at "policy" fs `shouldBe` Just (toJSON ("client" :: Text))
        it "names the update edge, the leaves and the client label" $ do
            fs <- fields BookUpdate Terminal
            at "edge" fs `shouldBe` Just (toJSON (bookingEdgeName BookUpdate))
            at "leafFound" fs `shouldBe` Just (toJSON (leafName Terminal))
            at "leafRequired" fs
                `shouldBe` Just (toJSON (leafName (requiredLeaf BookUpdate)))
            at "policy" fs `shouldBe` Just (toJSON ("client" :: Text))
