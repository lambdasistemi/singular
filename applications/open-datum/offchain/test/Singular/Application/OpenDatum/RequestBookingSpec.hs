{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Singular.Application.OpenDatum.RequestBookingSpec
Description : A booking the compiled request validator accepts
License     : Apache-2.0

As a booker I ask for the registration of a key and get a transaction that
puts my request at the validator's address under an approval token that commits
what I asked for. The compiled validator judges it: it accepts the transaction,
and refuses it again when any one fact of it is made wrong.
-}
module Singular.Application.OpenDatum.RequestBookingSpec
    ( spec
    ) where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Maybe (listToMaybe)
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC
import Test.Hspec

import Cardano.Ledger.Api.Tx.Out (addrTxOutL, coinTxOutL, valueTxOutL)
import Cardano.Ledger.BaseTypes (Inject (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value (AssetName, PolicyID (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Application.OpenDatum.RequestWorld
    ( Purpose (..)
    , Scenario (..)
    , addOutputs
    , adjustRegistrationField
    , approvalNameFor
    , assetsOf
    , baseAddress
    , bookWithScript
    , bookingOf
    , chainSession
    , configurationOutput
    , configuredParameters
    , everyScriptAccepts
    , expectBuilt
    , firstBooking
    , inlineDatum
    , inputsOf
    , judge
    , keyAddress
    , keyHashOf
    , mapOutput
    , mintedOf
    , newScenario
    , newScenarioWith
    , oracleAddress
    , oracleLive
    , oracleRegistration
    , outputsOf
    , referencesOf
    , refusedBy
    , removeOutputs
    , scriptAddress
    , signersOf
    , slotMs
    , soundnessProblems
    , txInOf
    , validatorAddress
    , validityOf
    , valueAda
    , withDatum
    , withReferences
    , withSigners
    )
import Singular.Application.OpenDatum.Requests.Booking
    ( Booking (..)
    , buildBookRegistration
    )
import Singular.Application.OpenDatum.Requests.Refusal (Refusal (..))
import Singular.Registry.Ledger (ConwayEra, TxOut)

-- | The bookings the rows are made of: they differ in every field the booker chooses.
bookings :: [(String, Booking)]
bookings =
    [
        ( "a short key, a tip and a refund address of a key"
        , firstBooking
        )
    ,
        ( "a long key, no tip and a refund address that stakes"
        , bookingOf
            (BS.replicate 70 0x61)
            (PLC.List [PLC.I 1, PLC.B "payload"])
            7_500_000
            0
            (baseAddress 0x23 0x24)
        )
    ,
        ( "an empty key, a large tip and a refund address that is a script"
        , bookingOf
            ""
            (PLC.Constr 3 [])
            3_000_000
            2_500_000
            (scriptAddress 0x25 0x26)
        )
    ]

-- | The payer of every booking: their key is the controller.
controllerKey :: ByteString
controllerKey = keyHashOf 0x41

-- | The tip slot the bookings are built at.
tipSlot :: SlotNo
tipSlot = SlotNo 10_000

-- | Book in a fresh scenario and hand over the transaction.
withBooking :: Booking -> (Scenario -> ConwayTx -> IO a) -> IO a
withBooking b k = do
    sc <- newScenario tipSlot
    tx <- expectBuilt =<< book sc b
    k sc tx

book :: Scenario -> Booking -> IO (Either Refusal ConwayTx)
book sc = bookWithScript sc (scScript sc)

-- | The request: the output at the validator's address, with its index.
requestOutput :: Scenario -> ConwayTx -> Maybe (Int, TxOut ConwayEra)
requestOutput sc tx =
    listToMaybe
        [ (i, o)
        | (i, o) <- zip [0 ..] (outputsOf tx)
        , o ^. addrTxOutL == validatorAddress sc
        ]

-- | The validity interval of a transaction in milliseconds.
windowMs :: ConwayTx -> (Integer, Integer)
windowMs tx = case validityOf tx of
    (Just lower, Just upper) -> (slotMs lower, slotMs upper)
    _ -> error "the booking declares no finite validity interval"

-- | What the booking commits, derived from what was asked and the declared interval.
expectedDatum :: Scenario -> Booking -> ConwayTx -> PLC.Data
expectedDatum sc b tx =
    oracleRegistration
        (bookRegistry b)
        (bookKey b)
        controllerKey
        (bookRefund b)
        (validatorAddress sc)
        (initialDatum b)
        (deposit b)
        (upper, upper + 600_000, upper + 1_200_000)
  where
    (_, upper) = windowMs tx

initialDatum :: Booking -> PLC.Data
initialDatum b =
    oracleLive
        (bookRegistry b)
        (bookKey b)
        controllerKey
        (deposit b)
        (bookPayload b)

deposit :: Booking -> Integer
deposit b = let Coin d = bookDeposit b in d

tipOf :: Booking -> Integer
tipOf b = let Coin t = bookTip b in t

expectedApproval :: Scenario -> Booking -> AssetName
expectedApproval sc b =
    approvalNameFor
        (bookRegistry b)
        (bookKey b)
        (validatorAddress sc)
        (initialDatum b)
        (deposit b)

-- | A fact of a booking made wrong, by the index of the request output.
type Mutation = Scenario -> Booking -> Int -> ConwayTx -> ConwayTx

mutations :: [(String, Mutation)]
mutations =
    [
        ( "the deposit the request commits is one lovelace more"
        , field 6 plusOne
        )
    , ("the booking time is a millisecond later", field 7 plusOne)
    , ("the processing deadline is a millisecond later", field 8 plusOne)
    , ("the reclaim end is a millisecond earlier", field 9 minusOne)
    ,
        ( "the controller is another key"
        , field 2 (const (PLC.B (keyHashOf 0x99)))
        )
    , ("the key is another key", field 1 (const (PLC.B "another key")))
    ,
        ( "the holding is at the address of a key"
        , field 4 (const (oracleAddress (keyAddress 0x55)))
        )
    , ("the initial datum is not a live holding", field 5 (const (PLC.I 0)))
    ,
        ( "the request holds less than the deposit"
        , \_ b i -> mapOutput i (\o -> o & coinTxOutL .~ Coin (deposit b - 1))
        )
    ,
        ( "the request holds no approval"
        , \_ _ i -> mapOutput i dropTokens
        )
    , ("the payer does not sign", \_ _ _ -> withSigners [])
    , ("the configuration record is not read", \_ _ _ -> withReferences [])
    ]
  where
    field n change _ _ i = mapOutput i (withField n change)
    withField n change o = case inlineDatum o of
        Just d -> withDatum (adjustRegistrationField n change d) o
        Nothing -> o
    plusOne = \case
        PLC.I n -> PLC.I (n + 1)
        other -> other
    minusOne = \case
        PLC.I n -> PLC.I (n - 1)
        other -> other
    dropTokens o = o & valueTxOutL .~ inject (Coin (valueAda o))

spec :: Spec
spec = do
    forM_ bookings $ \(label, b) ->
        describe ("booking with " <> label) $ do
            it "is accepted by the compiled validator" $
                withBooking b $ \sc tx -> do
                    verdicts <- judge (scChain sc) tx
                    map fst verdicts `shouldBe` [Mint]
                    verdicts `shouldSatisfy` everyScriptAccepts

            it
                "puts the request at the validator's address holding its approval and at least the deposit and the tip"
                $ withBooking b
                $ \sc tx -> do
                    (_, out) <-
                        maybe (fail "no request output") pure (requestOutput sc tx)
                    assetsOf out
                        `shouldBe` [(PolicyID (scHash sc), expectedApproval sc b, 1)]
                    valueAda out `shouldSatisfy` (>= deposit b + tipOf b)

            it "carries the ten booked fields" $
                withBooking b $ \sc tx -> do
                    (_, out) <-
                        maybe (fail "no request output") pure (requestOutput sc tx)
                    inlineDatum out `shouldBe` Just (expectedDatum sc b tx)

            it "mints one approval, named from the change it commits" $
                withBooking b $ \sc tx ->
                    mintedOf tx
                        `shouldBe` [(PolicyID (scHash sc), expectedApproval sc b, 1)]

            it "reads the clock from the configuration record by reference" $
                withBooking b $ \sc tx -> do
                    referencesOf tx `shouldBe` [scRecord sc]
                    inputsOf tx `shouldSatisfy` notElem (scRecord sc)
                    let (lower, upper) = windowMs tx
                    lower `shouldSatisfy` (<= slotMs tipSlot)
                    upper `shouldSatisfy` (> slotMs tipSlot)
                    (upper - lower) `shouldSatisfy` (<= 60_000)

            it "is a transaction the ledger can balance" $
                withBooking b $ \sc tx ->
                    soundnessProblems (scChain sc) tx `shouldReturn` []

            it
                "is signed by the payer, who funds it with the largest ADA-only output"
                $ withBooking b
                $ \sc tx -> do
                    signersOf tx `shouldBe` [controllerKey]
                    inputsOf tx `shouldSatisfy` elem (scFunding sc)
                    inputsOf tx `shouldSatisfy` notElem (txInOf '4' 0)

            describe "the validator refuses it again" $
                forM_ mutations $ \(name, mutate) ->
                    it ("when " <> name) $
                        withBooking b $ \sc tx -> do
                            accepted <- judge (scChain sc) tx
                            accepted `shouldSatisfy` everyScriptAccepts
                            (i, _) <- maybe (fail "no request output") pure (requestOutput sc tx)
                            refused <- judge (scChain sc) (mutate sc b i tx)
                            refused `shouldSatisfy` refusedBy

    describe "a booking the validator would refuse is declined by name" $ do
        let first = firstBooking
        it "when the registry has no configuration record" $ do
            sc <- newScenario tipSlot
            removeOutputs (scChain sc) [scRecord sc]
            book sc first `shouldReturn` Left NoConfiguration
        it "when the registry has several configuration records" $ do
            sc <- newScenario tipSlot
            addOutputs
                (scChain sc)
                [
                    ( txInOf '6' 0
                    , configurationOutput (scHash sc) (scRegistry sc) configuredParameters
                    )
                ]
            book sc first `shouldReturn` Left (AmbiguousConfiguration 2)
        it "when the payer has no ADA-only output" $ do
            sc <- newScenario tipSlot
            removeOutputs (scChain sc) [scFunding sc, txInOf '4' 0]
            book sc first `shouldReturn` Left PayerHasNoFunding
        it "when the payer is a script" $ do
            sc <- newScenario tipSlot
            buildBookRegistration
                (chainSession (scChain sc))
                (scScript sc)
                first
                (scriptAddress 0x41 0x42)
                `shouldReturn` Left PayerIsNotAKey
        it "when the deposit is below what the holding it commits must hold" $ do
            sc <- newScenario tipSlot
            result <- book sc first{bookDeposit = Coin 100_000}
            case result of
                Left (DepositBelowHolding given minimum') -> do
                    given `shouldBe` Coin 100_000
                    minimum' `shouldSatisfy` (> given)
                other ->
                    expectationFailure
                        ("expected the deposit refusal, got " <> show other)
        it "when the booking width holds no whole slot" $ do
            sc <-
                newScenarioWith [2_000_000, 1_000_000, 600_000, 600_000, 500] tipSlot
            result <- book sc first
            case result of
                Left (BookingWidthTooNarrow width) -> width `shouldBe` 500
                other ->
                    expectationFailure ("expected the width refusal, got " <> show other)
