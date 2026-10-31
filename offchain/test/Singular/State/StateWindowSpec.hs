{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Singular.State.StateWindowSpec
Description : The window every builder takes for a transaction built now
License     : Apache-2.0

As a builder I take the window of a transaction from one place: it starts at
the tip and ends a span of time later, read through the session's own time
conversion. A span too short to hold an interval leaves no window, and a span
that reaches past the end of the known time is cut there.
-}
module Singular.State.StateWindowSpec
    ( spec
    ) where

import Test.Hspec

import Cardano.Slotting.Slot (SlotNo (..))

import Singular.State.Assemble (usualSpan, windowFromTip)
import Singular.State.StateWorld

spec :: Spec
spec = describe "the window of a transaction built now" $ do
    it "is an hour from the tip when no other span is asked for" $ do
        usualSpan `shouldBe` 3_600_000

    it
        "starts at the tip and ends where the session's own conversion puts the span"
        $ do
            world <- newWorld []
            withSession world $ \session -> do
                (now, later) <- hourPastTip session
                windowFromTip session usualSpan `shouldReturn` Just (now, later)

    it "holds the span when it is a minute of one-second slots" $ do
        world <- newWorld []
        withSession world $ \session -> do
            (now, _) <- hourPastTip session
            windowFromTip session 60_000
                `shouldReturn` Just (now, SlotNo (unSlotNo now + 60))

    it
        "is nothing when the span is under the network's minimum validity window"
        $ do
            world <- newWorld []
            withSession world (`windowFromTip` 5_000)
                `shouldReturn` Nothing

    it "is cut where the known time ends when the span reaches past it" $ do
        world <- newWorldOver shortTime []
        setSlot world 19_000
        withSession world $ \session -> do
            window <- windowFromTip session usualSpan
            fmap fst window `shouldBe` Just (SlotNo 19_000)
            fmap snd window
                `shouldSatisfy` maybe False (<= SlotNo 20_000)
