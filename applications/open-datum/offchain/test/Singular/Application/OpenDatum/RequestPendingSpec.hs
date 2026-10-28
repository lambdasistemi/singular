{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Singular.Application.OpenDatum.RequestPendingSpec
Description : A pending registration returned by time: reclaim and cleanup
License     : Apache-2.0

As the holder of a refund address I take everything back from a registration
nobody folded, inside my window. After the window anyone returns the deposit
to the refund address and keeps the rest. The pending registrations here are
made by hand from the hand-written encodings, so these rows hold whatever the
booking builder does; a last group books with the builder and returns what it
booked.
-}
module Singular.Application.OpenDatum.RequestPendingSpec
    ( spec
    ) where

import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.Maybe (fromMaybe, listToMaybe)
import Lens.Micro ((&), (.~))
import PlutusCore.Data qualified as PLC
import Test.Hspec

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx.Out (addrTxOutL, coinTxOutL)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value (MultiAsset (..), PolicyID (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Application.OpenDatum.RequestWorld
    ( Pending (..)
    , Purpose (..)
    , Scenario (..)
    , addOutputs
    , applyTransaction
    , approvalOf
    , baseAddress
    , bookWithScript
    , chainSession
    , defaultPending
    , everyScriptAccepts
    , expectBuilt
    , feeOf
    , firstBooking
    , inputsOf
    , judge
    , keyAddress
    , keyHashOf
    , lookupOutput
    , mapOutput
    , mintedOf
    , newScenario
    , outputRef
    , outputsAt
    , paidTo
    , paymentKeyOf
    , pendingFixture
    , refusedBy
    , registryUnderTest
    , removeOutputs
    , scriptAddress
    , setTip
    , signersOf
    , slotMs
    , soundnessProblems
    , txInOf
    , validatorAddress
    , validityOf
    , valueAda
    , withMint
    , withSigners
    , withValidity
    )
import Singular.Application.OpenDatum.Requests.Booking (Booking (..))
import Singular.Application.OpenDatum.Requests.Pending
    ( buildCleanup
    , buildReclaim
    )
import Singular.Application.OpenDatum.Requests.Refusal
    ( Operation (..)
    , Refusal (..)
    )
import Singular.Application.OpenDatum.Requests.Script (RequestScript)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.LedgerProvider (Session)

-- | Pending registrations that differ in what they hold and where they return it.
pendings :: [(String, Pending)]
pendings =
    [
        ( "a short key, a refund address of a key and a tip"
        , (defaultPending registryUnderTest)
            { pendingRefund = baseAddress 0x41 0x42
            }
        )
    ,
        ( "a long key, a refund address that stakes and no tip"
        , (defaultPending registryUnderTest)
            { pendingKey = BS.replicate 70 0x61
            , pendingController = keyHashOf 0x12
            , pendingRefund = baseAddress 0x41 0x24
            , pendingPayload = PLC.List [PLC.I 1]
            , pendingDeposit = 7_500_000
            , pendingValue = 7_500_000
            }
        )
    ]

-- | A pending registration whose refund address is a script.
scriptRefund :: Pending
scriptRefund =
    (defaultPending registryUnderTest)
        { pendingKey = ""
        , pendingRefund = scriptAddress 0x25 0x26
        , pendingDeposit = 3_000_000
        , pendingValue = 5_500_000
        }

-- | A pending registration whose refund address is another party's key.
anotherKeyRefund :: Pending
anotherKeyRefund =
    (defaultPending registryUnderTest)
        { pendingKey = "another key"
        , pendingRefund = keyAddress 0x22
        }

-- | The slots on which the phases of the pending registrations change.
processingEnd, reclaimEnd :: SlotNo
processingEnd = SlotNo 10_660
reclaimEnd = SlotNo 11_260

-- | A tip before the reclaim window, inside it, and after it.
beforeWindow, insideWindow, afterWindow :: SlotNo
beforeWindow = SlotNo 10_100
insideWindow = SlotNo 10_700
afterWindow = SlotNo 11_300

-- | The pending registrations a cleanup returns: whoever the refund address is.
cleanable :: [(String, Pending)]
cleanable =
    pendings
        <> [ ("a refund address of another key", anotherKeyRefund)
           , ("a refund address that is a script", scriptRefund)
           ]

-- | A scenario at a tip that holds the pending registration.
withPending :: Pending -> SlotNo -> (Scenario -> TxIn -> IO a) -> IO a
withPending held tip k = do
    sc <- newScenario tip
    let (ref, out) = pendingFixture (scHash sc) held
    addOutputs (scChain sc) [(ref, out)]
    k sc ref

type Builder =
    Session NoWitness IO
    -> RequestScript
    -> TxIn
    -> Addr
    -> IO (Either Refusal ConwayTx)

build :: Builder -> Scenario -> TxIn -> IO (Either Refusal ConwayTx)
build builder sc ref =
    builder (chainSession (scChain sc)) (scScript sc) ref (scPayer sc)

-- | The slots a transaction declares as its validity interval.
declared :: ConwayTx -> (SlotNo, SlotNo)
declared tx = case validityOf tx of
    (Just lower, Just upper) -> (lower, upper)
    _ -> error "the transaction declares no finite validity interval"

-- | The index of the output that pays the refund address.
refundOutput :: Pending -> ConwayTx -> Int
refundOutput p tx =
    fromMaybe
        (error "nothing is paid to the refund address")
        (listToMaybe (outputsAt (pendingRefund p) tx))

-- | Things made wrong in a returning transaction, one at a time.
type Mutation = Pending -> ConwayTx -> ConwayTx

lowerOf :: ConwayTx -> Maybe SlotNo
lowerOf = fst . validityOf

upperOf :: ConwayTx -> Maybe SlotNo
upperOf = snd . validityOf

sharedMutations :: [(String, Mutation)]
sharedMutations =
    [
        ( "the return goes to another address"
        , \p tx -> mapOutput (refundOutput p tx) (addrTxOutL .~ keyAddress 0x66) tx
        )
    , ("the approval is not burned", \_ -> withMint (MultiAsset mempty))
    ,
        ( "the transaction has no end"
        , \_ tx -> withValidity (lowerOf tx) Nothing tx
        )
    ]

reclaimMutations :: [(String, Mutation)]
reclaimMutations =
    [ ("the refund address does not sign", \_ -> withSigners [])
    ,
        ( "the refund address is paid one lovelace less than the request"
        , \p -> payRefundTotal (pendingValue p - 1) p
        )
    ,
        ( "the transaction lasts one slot past the window"
        , \_ tx -> withValidity (lowerOf tx) (Just (succ' reclaimEnd)) tx
        )
    ,
        ( "the transaction starts one slot before the window"
        , \_ tx -> withValidity (Just (pred' processingEnd)) (upperOf tx) tx
        )
    ]
        <> sharedMutations

cleanupMutations :: [(String, Mutation)]
cleanupMutations =
    [
        ( "the return is one lovelace short of the deposit"
        , \p tx ->
            mapOutput
                (refundOutput p tx)
                (\o -> o & coinTxOutL .~ Coin (valueAda o - 1))
                tx
        )
    ,
        ( "the transaction starts one slot before the window ends"
        , \_ tx -> withValidity (Just (pred' reclaimEnd)) (upperOf tx) tx
        )
    ]
        <> sharedMutations

-- | Pay the refund address this much in all: in its first output, and nothing in the others.
payRefundTotal :: Integer -> Pending -> ConwayTx -> ConwayTx
payRefundTotal total p tx =
    foldl
        ( \built (n, ix) ->
            mapOutput ix (setCoin (if n == (0 :: Int) then total else 0)) built
        )
        tx
        (zip [0 ..] (outputsAt (pendingRefund p) tx))
  where
    setCoin c o = o & coinTxOutL .~ Coin c

succ', pred' :: SlotNo -> SlotNo
succ' (SlotNo s) = SlotNo (s + 1)
pred' (SlotNo s) = SlotNo (s - 1)

-- | A mutated transaction is refused where the original was accepted.
refusesWhen :: Builder -> Pending -> SlotNo -> Mutation -> Expectation
refusesWhen builder p tip mutate = withPending p tip $ \sc ref -> do
    tx <- expectBuilt =<< build builder sc ref
    accepted <- judge (scChain sc) tx
    accepted `shouldSatisfy` everyScriptAccepts
    refused <- judge (scChain sc) (mutate p tx)
    refused `shouldSatisfy` refusedBy

spec :: Spec
spec = do
    forM_ pendings $ \(label, p) ->
        describe ("reclaiming a pending registration with " <> label) $ do
            let (_, processDeadline, reclaimDeadline) = pendingTimes p
            it "is accepted by the compiled validator inside the reclaim window" $
                withPending p insideWindow $ \sc ref -> do
                    tx <- expectBuilt =<< build buildReclaim sc ref
                    verdicts <- judge (scChain sc) tx
                    map fst verdicts `shouldBe` [Mint, Spend]
                    verdicts `shouldSatisfy` everyScriptAccepts

            it
                "spends the registration and pays the whole request value to the refund address"
                $ withPending p insideWindow
                $ \sc ref -> do
                    tx <- expectBuilt =<< build buildReclaim sc ref
                    inputsOf tx `shouldSatisfy` elem ref
                    paidTo (pendingRefund p) tx `shouldSatisfy` (>= pendingValue p)

            it "burns the approval the registration holds" $
                withPending p insideWindow $ \sc ref -> do
                    tx <- expectBuilt =<< build buildReclaim sc ref
                    mintedOf tx
                        `shouldBe` [(PolicyID (scHash sc), approvalOf (scHash sc) p, -1)]

            it "is signed by the refund address" $
                withPending p insideWindow $ \sc ref -> do
                    tx <- expectBuilt =<< build buildReclaim sc ref
                    key <-
                        maybe
                            (fail "the refund address is not a key")
                            pure
                            (paymentKeyOf (pendingRefund p))
                    signersOf tx `shouldSatisfy` elem key

            it "is valid only inside the reclaim window and at the tip" $
                withPending p insideWindow $ \sc ref -> do
                    tx <- expectBuilt =<< build buildReclaim sc ref
                    let (lower, upper) = declared tx
                    slotMs lower `shouldSatisfy` (>= processDeadline)
                    slotMs upper `shouldSatisfy` (<= reclaimDeadline)
                    lower `shouldSatisfy` (<= insideWindow)
                    upper `shouldSatisfy` (> insideWindow)

            it "is a transaction the ledger can balance" $
                withPending p insideWindow $ \sc ref -> do
                    tx <- expectBuilt =<< build buildReclaim sc ref
                    soundnessProblems (scChain sc) tx `shouldReturn` []

            describe "the validator refuses it again" $
                forM_ reclaimMutations $ \(name, mutate) ->
                    it ("when " <> name) $
                        refusesWhen buildReclaim p insideWindow mutate

    describe "a reclaim the validator would refuse is declined by name" $ do
        let (_, plain) = headOr pendings
        it "before the reclaim window opens" $
            withPending plain beforeWindow $ \sc ref ->
                build buildReclaim sc ref `shouldReturn` Left (WindowNotOpen Reclaim)
        it "after the reclaim window has closed" $
            withPending plain afterWindow $ \sc ref ->
                build buildReclaim sc ref `shouldReturn` Left (WindowClosed Reclaim)
        it "when the refund address is a script, which cannot sign" $
            withPending scriptRefund insideWindow $ \sc ref ->
                build buildReclaim sc ref `shouldReturn` Left RefundAddressIsScript
        it "when the payer is not the refund address" $
            withPending anotherKeyRefund insideWindow $ \sc ref ->
                build buildReclaim sc ref `shouldReturn` Left PayerIsNotRefundAddress
        it "when the output is not on the chain" $ do
            sc <- newScenario insideWindow
            build buildReclaim sc (txInOf '9' 0)
                `shouldReturn` Left (PendingNotFound (txInOf '9' 0))
        it "when the output is not a pending registration" $
            withPending plain insideWindow $ \sc _ -> do
                build buildReclaim sc (scFunding sc)
                    `shouldReturn` Left (NotAPendingRegistration (scFunding sc))
                build buildReclaim sc (scRecord sc)
                    `shouldReturn` Left (NotAPendingRegistration (scRecord sc))
        it "when the payer has no ADA-only output" $
            withPending plain insideWindow $ \sc ref -> do
                removeOutputs (scChain sc) [scFunding sc, txInOf '4' 0]
                build buildReclaim sc ref `shouldReturn` Left PayerHasNoFunding

    forM_ cleanable $ \(label, p) ->
        describe ("cleaning up a pending registration with " <> label) $ do
            let (_, _, reclaimDeadline) = pendingTimes p
            it "is accepted by the compiled validator after the window" $
                withPending p afterWindow $ \sc ref -> do
                    tx <- expectBuilt =<< build buildCleanup sc ref
                    verdicts <- judge (scChain sc) tx
                    map fst verdicts `shouldBe` [Mint, Spend]
                    verdicts `shouldSatisfy` everyScriptAccepts

            it "pays the deposit to the refund address and the rest to the caller" $
                withPending p afterWindow $ \sc ref -> do
                    tx <- expectBuilt =<< build buildCleanup sc ref
                    spent <-
                        mapM
                            (fmap (maybe 0 valueAda) . lookupOutput (scChain sc))
                            (inputsOf tx)
                    inputsOf tx `shouldSatisfy` elem ref
                    outputsAt (pendingRefund p) tx `shouldSatisfy` ((== 1) . length)
                    paidTo (pendingRefund p) tx `shouldBe` pendingDeposit p
                    paidTo (scPayer sc) tx
                        `shouldBe` sum spent - pendingDeposit p - feeOf tx

            it "burns the approval the registration holds" $
                withPending p afterWindow $ \sc ref -> do
                    tx <- expectBuilt =<< build buildCleanup sc ref
                    mintedOf tx
                        `shouldBe` [(PolicyID (scHash sc), approvalOf (scHash sc) p, -1)]

            it "needs no signature of the refund address or of the controller" $
                withPending p afterWindow $ \sc ref -> do
                    tx <- expectBuilt =<< build buildCleanup sc ref
                    signersOf tx `shouldBe` []

            it "is valid only from the end of the window and at the tip" $
                withPending p afterWindow $ \sc ref -> do
                    tx <- expectBuilt =<< build buildCleanup sc ref
                    let (lower, upper) = declared tx
                    slotMs lower `shouldSatisfy` (>= reclaimDeadline)
                    lower `shouldSatisfy` (<= afterWindow)
                    upper `shouldSatisfy` (> afterWindow)

            it "is a transaction the ledger can balance" $
                withPending p afterWindow $ \sc ref -> do
                    tx <- expectBuilt =<< build buildCleanup sc ref
                    soundnessProblems (scChain sc) tx `shouldReturn` []

            describe "the validator refuses it again" $
                forM_ cleanupMutations $ \(name, mutate) ->
                    it ("when " <> name) $
                        refusesWhen buildCleanup p afterWindow mutate

    describe "a cleanup the validator would refuse is declined by name" $ do
        let (_, plain) = headOr pendings
        it "while the registration can still be reclaimed" $
            withPending plain insideWindow $ \sc ref ->
                build buildCleanup sc ref `shouldReturn` Left (WindowNotOpen Cleanup)
        it "when the output is not on the chain" $ do
            sc <- newScenario afterWindow
            build buildCleanup sc (txInOf '9' 0)
                `shouldReturn` Left (PendingNotFound (txInOf '9' 0))
        it "when the output is not a pending registration" $
            withPending plain afterWindow $ \sc _ ->
                build buildCleanup sc (scFunding sc)
                    `shouldReturn` Left (NotAPendingRegistration (scFunding sc))
        it "when the payer has no ADA-only output" $
            withPending plain afterWindow $ \sc ref -> do
                removeOutputs (scChain sc) [scFunding sc, txInOf '4' 0]
                build buildCleanup sc ref `shouldReturn` Left PayerHasNoFunding

    describe "a registration the booking builder booked" $ do
        it "is reclaimed by the refund address inside its window" $ do
            sc <- newScenario (SlotNo 10_000)
            let refund = baseAddress 0x41 0x42
            booking <-
                expectBuilt
                    =<< bookWithScript
                        sc
                        (scScript sc)
                        firstBooking{bookRefund = refund}
            applyTransaction (scChain sc) booking
            ref <- requestOf sc booking
            setTip (scChain sc) insideWindow
            tx <- expectBuilt =<< build buildReclaim sc ref
            verdicts <- judge (scChain sc) tx
            verdicts `shouldSatisfy` everyScriptAccepts
            paidTo refund tx `shouldSatisfy` (>= 6_000_000)
        it
            "is cleaned up by anyone after its window, the deposit going to the refund address"
            $ do
                sc <- newScenario (SlotNo 10_000)
                booking <-
                    expectBuilt =<< bookWithScript sc (scScript sc) firstBooking
                applyTransaction (scChain sc) booking
                ref <- requestOf sc booking
                setTip (scChain sc) afterWindow
                tx <- expectBuilt =<< build buildCleanup sc ref
                verdicts <- judge (scChain sc) tx
                verdicts `shouldSatisfy` everyScriptAccepts
                paidTo (keyAddress 0x22) tx `shouldBe` 5_000_000
  where
    headOr = \case
        (x : _) -> x
        [] -> error "no pending registrations"
    requestOf sc booking = case outputsAt (validatorAddress sc) booking of
        (ix : _) -> pure (outputRef booking ix)
        [] -> fail "the booking pays nothing to the validator's address"
