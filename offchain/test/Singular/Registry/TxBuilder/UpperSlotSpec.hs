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

import Singular.Registry.Provider (Provider (..), SlotNo (..))
import Singular.Registry.TxBuilder.Internal (trySlots, tryUpperSlots)

-- | The exclusive horizon, and the slot length in milliseconds.
horizon, slotMs :: Integer
horizon = 500
slotMs = 100

-- | A provider that converts times as the node client does, up to the horizon.
horizonProvider :: Provider IO
horizonProvider =
    Provider
        { queryUTxOs = \_ -> fail "unused"
        , queryProtocolParams = fail "unused"
        , evaluateTx = \_ -> fail "unused"
        , posixMsToSlot = floorSlot
        , posixMsCeilSlot = \ms -> do
            SlotNo s <- floorSlot ms
            pure (SlotNo (if ms `mod` slotMs == 0 then s else s + 1))
        }
  where
    floorSlot ms
        | ms `div` slotMs < horizon =
            pure (SlotNo (fromIntegral (ms `div` slotMs)))
        | otherwise = throwIO (userError "PastHorizon")

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
            s <- trySlots horizonProvider [lastSlotTime + 30_000, lastSlotTime]
            s `shouldBe` SlotNo 500
    it "the upper bound for that time stays inside the horizon" $ do
        s <-
            tryUpperSlots horizonProvider [lastSlotTime + 30_000, lastSlotTime]
        s `shouldBe` SlotNo 499
        s `shouldSatisfy` inside
    it "stays inside the horizon for every time the node converts" $ do
        bounds <-
            mapM
                ( \ms ->
                    tryUpperSlots
                        horizonProvider
                        [ms + 30_000, ms + 5_000, ms + 2_000, ms]
                )
                [0, 7 .. horizon * slotMs - 1]
        bounds `shouldSatisfy` all inside
    cancellationSpec

-- | A provider whose every conversion first counts itself, then is cancelled.
cancelledProvider :: IORef Int -> Provider IO
cancelledProvider calls =
    horizonProvider
        { posixMsToSlot = \_ -> do
            modifyIORef' calls (+ 1)
            throwIO ThreadKilled
        }

-- | A cancellation escapes the fallback, and no later conversion is tried.
cancellationSpec :: Spec
cancellationSpec =
    it "lets a cancellation escape instead of trying the next time" $ do
        calls <- newIORef 0
        r <- try (tryUpperSlots (cancelledProvider calls) [0, 1_000, 2_000])
        case r of
            Left ThreadKilled -> pure ()
            other ->
                expectationFailure
                    ("the cancellation did not escape: " <> show (void other))
        readIORef calls >>= (`shouldBe` 1)
