{-# LANGUAGE NumericUnderscores #-}

{- | Upper bounds round down over the pinned final era, including beyond
its captured horizon. NOTE030 opens that era; it does not change the caller's
candidate windows, rounding rules, or cancellation behavior.
-}
module Singular.Registry.TxBuilder.UpperSlotSpec (spec) where

import Control.Exception (AsyncException (ThreadKilled), throwIO, try)
import Control.Monad (void)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    )

import Cardano.Slotting.Slot (SlotNo (..))
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.LedgerProvider (Session)
import Singular.Registry.StubSession
import Singular.Registry.SyntheticTime (syntheticTimeWith)
import Singular.Registry.TxBuilder.Internal (trySlots, tryUpperSlots)

-- | The captured exclusive horizon, and the pinned slot length in milliseconds.
horizon, slotMs :: Integer
horizon = 500
slotMs = 100

-- | Raw synthetic finite history; the common interpreter opens its final era.
horizonView :: Session NoWitness IO
horizonView =
    (withTime (pure (syntheticTimeWith 0 (1 / 10) 500)) $ stubSession)

spec :: Spec
spec = describe "A fold's validity upper bound in the pinned final era" $ do
    -- 49 950 ms is inside slot 499, the horizon's last slot.
    let lastSlotTime = (horizon - 1) * slotMs + slotMs `div` 2
    it
        "rounds up the first candidate beyond the old horizon without shortening the window"
        $ do
            s <- trySlots horizonView [lastSlotTime + 30_000, lastSlotTime]
            s `shouldBe` SlotNo 800
    it "rounds the same upper-bound candidate down beyond the old horizon" $ do
        s <-
            tryUpperSlots horizonView [lastSlotTime + 30_000, lastSlotTime]
        s `shouldBe` SlotNo 799
    it
        "preserves the first candidate's window and floor for every sampled time"
        $ do
            bounds <-
                mapM
                    ( \ms ->
                        tryUpperSlots
                            horizonView
                            [ms + 30_000, ms + 5_000, ms + 2_000, ms]
                    )
                    [0, 7 .. horizon * slotMs - 1]
            bounds
                `shouldBe` [ SlotNo (fromInteger ((ms + 30_000) `div` slotMs))
                           | ms <- [0, 7 .. horizon * slotMs - 1]
                           ]
    cancellationSpec

-- | A view whose every conversion first counts itself, then is cancelled.
cancelledView :: IORef Int -> Session NoWitness IO
cancelledView calls =
    withTime
        ( do
            modifyIORef' calls (+ 1)
            throwIO ThreadKilled
        )
        horizonView

-- | A cancellation escapes the fallback, and no later conversion is tried.
cancellationSpec :: Spec
cancellationSpec =
    it "lets a cancellation escape instead of trying the next time" $ do
        calls <- newIORef 0
        r <- try (tryUpperSlots (cancelledView calls) [0, 1_000, 2_000])
        case r of
            Left ThreadKilled -> pure ()
            other ->
                expectationFailure
                    ("the cancellation did not escape: " <> show (void other))
        readIORef calls >>= (`shouldBe` 1)
