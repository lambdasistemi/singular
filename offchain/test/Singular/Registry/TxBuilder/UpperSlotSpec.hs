{-# LANGUAGE NumericUnderscores #-}

{- | A fold's validity upper bound stays inside the node's horizon.

The provider below answers as the node client does for a development node
of 100 ms slots whose horizon ends, exclusively, at slot 500: a time is
converted only while it is inside the horizon, and rounding up adds one slot
unless the time falls exactly on a slot boundary.
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
    , shouldSatisfy
    )

import Cardano.Slotting.Slot (SlotNo (..))
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.LedgerProvider (Session)
import Singular.Registry.StubSession
import Singular.Registry.SyntheticTime (syntheticTimeWith)
import Singular.Registry.TxBuilder.Internal (trySlots, tryUpperSlots)

-- | The exclusive horizon, and the slot length in milliseconds.
horizon, slotMs :: Integer
horizon = 500
slotMs = 100

-- | A view that converts times as the node client does, up to the horizon.
horizonView :: Session NoWitness IO
horizonView =
    (withTime (pure (syntheticTimeWith 0 (1 / 10) 500)) $ stubSession)

-- | Inside the horizon: strictly below it.
inside :: SlotNo -> Bool
inside (SlotNo s) = fromIntegral s < horizon

spec :: Spec
spec = describe "A fold's validity upper bound and the node's horizon" $ do
    -- 49 950 ms is inside slot 499, the horizon's last slot.
    let lastSlotTime = (horizon - 1) * slotMs + slotMs `div` 2
    it
        "rounding up a time in the horizon's last slot gives the horizon slot itself"
        $ do
            s <- trySlots horizonView [lastSlotTime + 30_000, lastSlotTime]
            s `shouldBe` SlotNo 500
    it "the upper bound for that time stays inside the horizon" $ do
        s <-
            tryUpperSlots horizonView [lastSlotTime + 30_000, lastSlotTime]
        s `shouldBe` SlotNo 499
        s `shouldSatisfy` inside
    it "stays inside the horizon for every time the node converts" $ do
        bounds <-
            mapM
                ( \ms ->
                    tryUpperSlots
                        horizonView
                        [ms + 30_000, ms + 5_000, ms + 2_000, ms]
                )
                [0, 7 .. horizon * slotMs - 1]
        bounds `shouldSatisfy` all inside
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
