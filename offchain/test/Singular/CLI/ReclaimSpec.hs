{- |
Module      : Singular.CLI.ReclaimSpec
Description : Admission of the owner's pending request in the ledger's window
License     : Apache-2.0
-}
module Singular.CLI.ReclaimSpec (spec) where

import Data.Either (isRight)
import Data.List (isInfixOf)
import Test.Hspec
import Test.QuickCheck (chooseInteger, forAll, property, (===))

import Cardano.Slotting.Slot (SlotNo (..))
import Singular.CLI.ReclaimRules
import Singular.CLI.RequestWindow
import Singular.Registry.Types (RequestPhase (..), requestPhase)

spec :: Spec
spec = describe "registry reclaim admission" $ do
    let bounds = windowOf 1000 120000 30000
        row start end = Just ("alice" :: String, 1, bounds, start, end)
        at tip = reclaimGate "alice" (row (Just 100) (Just 130)) tip
    it "requires the named request to be pending" $
        reclaimGate ("alice" :: String) Nothing 110 `shouldBe` Left NotPending
    it "requires this command's wallet to own the request" $
        reclaimGate "bob" (row (Just 100) (Just 130)) 110
            `shouldBe` Left NotOwner
    it "admits the opening slot, but excludes the closing slot" $ do
        at 99 `shouldBe` Left (BeforeWindow bounds 99 100)
        at 100 `shouldBe` Right bounds
        at 129 `shouldBe` Right bounds
        at 130 `shouldBe` Left (WindowClosed bounds 130 130)
    it "agrees with the library's phase for arbitrary converted windows" $
        property $
            forAll (chooseInteger (1, 1000000)) $ \start ->
                forAll (chooseInteger (1, 1000)) $ \width ->
                    forAll (chooseInteger (0, start + width + 100)) $ \tip ->
                        let end = start + width
                            actual = reclaimGate "alice" (row (Just start) (Just end)) tip
                            expected =
                                requestPhase
                                    (SlotNo (fromInteger start))
                                    (SlotNo (fromInteger end))
                                    (SlotNo (fromInteger tip))
                        in  isRight actual === (expected == PhaseRetract)
    it
        "admits a reached processing deadline when the retract deadline is unconverted"
        $ reclaimGate "alice" (row (Just 100) Nothing) 110
            `shouldBe` Right bounds
    it "admits two converted deadlines with the tip between them" $
        at 110 `shouldBe` Right bounds
    it "refuses an unconverted processing deadline before the window" $ do
        reclaimGate "alice" (row Nothing (Just 130)) 110
            `shouldBe` Left (WindowUnconverted bounds Nothing (Just 130))
        reclaimGate "alice" (row Nothing Nothing) 90000000
            `shouldBe` Left (WindowUnconverted bounds Nothing Nothing)
        renderReclaimRefusal (WindowUnconverted bounds Nothing Nothing)
            `shouldSatisfy` \said ->
                "before the window" `isInfixOf` said
                    && show (processingEnds bounds) `isInfixOf` said
    it "refuses a converted retract deadline that the tip has reached" $
        at 130 `shouldBe` Left (WindowClosed bounds 130 130)
    it
        "still names a proved early or closed window if the other bound is unconverted"
        $ do
            reclaimGate "alice" (row (Just 100) Nothing) 99
                `shouldBe` Left (BeforeWindow bounds 99 100)
            reclaimGate "alice" (row Nothing (Just 130)) 130
                `shouldBe` Left (WindowClosed bounds 130 130)
    it
        "reads the tip rather than a clock or the deadline's numerical time"
        $ reclaimGate
            ("alice" :: String)
            (Just ("alice", 1, windowOf 0 1 1, Just 100, Just 130))
            99
            `shouldBe` Left (BeforeWindow (windowOf 0 1 1) 99 100)
    it "admits only the insertion and terminal-witness edges Lean permits" $
        map
            ( \edge ->
                reclaimGate
                    ("alice" :: String)
                    (Just ("alice", edge, bounds, Just 100, Just 130))
                    110
            )
            [0 .. 6]
            `shouldBe` [ Right bounds
                       , Right bounds
                       , Left (NotRetractable 2)
                       , Left (NotRetractable 3)
                       , Left (NotRetractable 4)
                       , Left (NotRetractable 5)
                       , Right bounds
                       ]
    it "names both bounds and the opening slot when early" $
        renderReclaimRefusal (BeforeWindow bounds 99 100)
            `shouldSatisfy` \said ->
                all
                    (`isInfixOf` said)
                    [ "opens"
                    , show (processingEnds bounds)
                    , show (retractEnds bounds)
                    , "100"
                    ]
    it "names the closing bound and how reject clears a closed request" $
        renderReclaimRefusal (WindowClosed bounds 130 130)
            `shouldSatisfy` \said ->
                all
                    (`isInfixOf` said)
                    ["closed", show (retractEnds bounds), "registry reject"]
    it "requires the built interval to be nonempty and inside the window" $ do
        reclaimValidity 100 (DeadlineSlot 130) (Just 100) (Just 130)
            `shouldBe` True
        reclaimValidity 100 (DeadlineSlot 130) (Just 99) (Just 130)
            `shouldBe` False
        reclaimValidity 100 (DeadlineSlot 130) (Just 100) (Just 131)
            `shouldBe` False
        reclaimValidity 100 (DeadlineSlot 130) (Just 130) (Just 130)
            `shouldBe` False
        reclaimValidity 100 (DeadlineSlot 130) Nothing (Just 130)
            `shouldBe` False
        reclaimValidity 100 (DeadlineSlot 130) (Just 100) Nothing
            `shouldBe` False
    it "places a fallback upper bound in the view before signing" $ do
        reclaimValidity
            100
            (DeadlineTime 130000 (Just 129999))
            (Just 110)
            (Just 120)
            `shouldBe` True
        reclaimValidity
            100
            (DeadlineTime 130000 (Just 130000))
            (Just 110)
            (Just 120)
            `shouldBe` True
        reclaimValidity
            100
            (DeadlineTime 130000 (Just 130001))
            (Just 110)
            (Just 120)
            `shouldBe` False
        reclaimValidity
            100
            (DeadlineTime 130000 Nothing)
            (Just 110)
            (Just 120)
            `shouldBe` False
