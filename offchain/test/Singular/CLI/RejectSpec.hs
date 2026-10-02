{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.RejectSpec
Description : When a reject may be built, and the refunds it must carry
License     : Apache-2.0

A reject takes every pending request of the registry, so the owner of a
request that may still be folded or retracted is protected only by the
decision made before it is built. These rows fix that decision, and the
check that each rejected request's owner gets the whole refund in the
output designated for it. Every expected phase comes from the library's
own 'requestPhase' or from arithmetic on the inputs, never from a value
typed beside the code under test.
-}
module Singular.CLI.RejectSpec (spec) where

import Data.Either (isLeft)
import Data.List (isInfixOf)
import Data.Text qualified as T
import Test.Hspec
import Test.QuickCheck
    ( Gen
    , chooseInteger
    , elements
    , forAll
    , listOf1
    , property
    , vectorOf
    , (===)
    , (==>)
    )

import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo (..))

import Singular.CLI.RejectRules
import Singular.CLI.RequestWindow
import Singular.Registry.Deployment (parseOutRef, renderOutRef)
import Singular.Registry.Types
    ( RequestPhase (..)
    , requestPhase
    )

spec :: Spec
spec = describe "registry reject" $ do
    windows
    gate
    refunds

-- | A request numbered by its distinct transaction output.
request :: Int -> TxIn
request n =
    either error id $
        parseOutRef (T.pack (replicate 62 'a' <> hex2 n <> "#0"))
  where
    hex2 k = [digit (k `div` 16), digit (k `mod` 16)]
    digit d = "0123456789abcdef" !! (d `mod` 16)

{- | The deadline a request's retract window ends at, in a view's slots,
and a tip slot, with the request's bounds: what the gate reads.
-}
genSlots :: Gen (Integer, Integer)
genSlots = do
    deadline <- chooseInteger (1_000_000, 90_000_000)
    tip <- chooseInteger (deadline - 500, deadline + 500)
    pure (deadline, tip)

-- ---------------------------------------------------------
-- The windows
-- ---------------------------------------------------------

windows :: Spec
windows = describe "a request's windows" $ do
    it
        "end at the submission plus the processing time, then the retract time"
        $ do
            -- worked by hand: 1_700_000_000_000 + 120_000 + 30_000
            windowOf 1_700_000_000_000 120_000 30_000
                `shouldBe` Bounds 1_700_000_120_000 1_700_000_150_000
    it "end at sums of what the datums hold, for any submission and times" $
        property $
            forAll (chooseInteger (0, 4_000_000_000_000)) $ \s ->
                forAll (chooseInteger (1, 600_000)) $ \p ->
                    forAll (chooseInteger (1, 600_000)) $ \r ->
                        windowOf s p r === Bounds (s + p) (s + p + r)

-- ---------------------------------------------------------
-- Whether a reject is built
-- ---------------------------------------------------------

-- | A request booked at some time; the gate reads its bounds, never a clock.
bounds :: Bounds
bounds = windowOf 1_700_000_000_000 120_000 30_000

gate :: Spec
gate = describe "the decision to build a reject" $ do
    it "refuses when nothing is pending, by name" $ do
        rejectGate 50_000 [] `shouldBe` Left NothingToReject
        renderRejectRefusal NothingToReject
            `shouldSatisfy` isInfixOf "nothing is pending"
    it
        "builds only once the view's tip is at or past each retract deadline's slot, as the library's own phase reads it"
        $ property
        $ forAll genSlots
        $ \(deadline, tip) ->
            let admitted =
                    either
                        (const False)
                        (const True)
                        (rejectGate tip [(request 1, bounds, Just deadline)])
                oracle =
                    requestPhase
                        (SlotNo (fromInteger deadline))
                        (SlotNo (fromInteger deadline))
                        (SlotNo (fromInteger tip))
            in  admitted === (oracle == PhaseReject)
    it "admits the deadline's own slot and refuses the slot before it" $ do
        let at tip = rejectGate tip [(request 1, bounds, Just 70_000)]
        at 69_999
            `shouldBe` Left
                ( WindowsOpen
                    [OpenRequest (request 1) bounds (BeforeDeadline 69_999 70_000)]
                )
        at 70_000 `shouldBe` Right [(request 1, bounds)]
        at 70_001 `shouldBe` Right [(request 1, bounds)]
    it
        "reads no clock: a tip short of the deadline's slot refuses whatever time the bounds say has passed"
        $ do
            -- the requester's counter-story: ledger slot 149_000 against a retract
            -- deadline at slot 150_000 stays open, whatever any other clock reads
            let long_ago = windowOf 1_000 1 1
            rejectGate 149_000 [(request 1, long_ago, Just 150_000)]
                `shouldBe` Left
                    ( WindowsOpen
                        [OpenRequest (request 1) long_ago (BeforeDeadline 149_000 150_000)]
                    )
    it
        "takes a deadline the view cannot place in a slot as still open, by name, never by inference"
        $ do
            let refusal = rejectGate 90_000_000 [(request 1, bounds, Nothing)]
            refusal
                `shouldBe` Left
                    (WindowsOpen [OpenRequest (request 1) bounds DeadlineUnconverted])
            either renderRejectRefusal (const "") refusal
                `shouldSatisfy` \said ->
                    all
                        (`isInfixOf` said)
                        [ T.unpack (renderOutRef (request 1))
                        , "cannot place"
                        , show (retractEnds bounds)
                        ]
    it
        "takes every pending request once each is past its deadline's slot (several requests)"
        $ property
        $ forAll (chooseInteger (2, 6))
        $ \n ->
            forAll
                (vectorOf (fromInteger n) (chooseInteger (1_000_000, 50_000_000)))
                $ \slots ->
                    let tip = maximum slots
                        booked = [(request i, bounds, Just s) | (i, s) <- zip [1 ..] slots]
                    in  fmap (map fst) (rejectGate tip booked)
                            === Right (map (\(r, _, _) -> r) booked)
    it
        "builds nothing while any request is inside its window, and names exactly those (several requests)"
        $ property
        $ forAll (listOf1 genSlots)
        $ \slots ->
            length slots > 1 ==>
                forAll (chooseInteger (1_000_000, 90_000_000)) $ \tip ->
                    let booked =
                            [ (request i, bounds, if d `mod` 7 == 0 then Nothing else Just d)
                            | (i, (d, _)) <- zip [1 ..] slots
                            ]
                        inside =
                            [ r
                            | (r, _, d) <- booked
                            , maybe True (tip <) d
                            ]
                    in  case rejectGate tip booked of
                            Right taken -> (null inside, map fst taken) === (True, [r | (r, _, _) <- booked])
                            Left (WindowsOpen open) -> map openRequest open === inside
                            Left NothingToReject -> property False
    it
        "names each request still open, when its retract window closes, its slot and the tip"
        $ do
            let young = windowOf 1_700_000_000_000 120_000 30_000
                refusal =
                    rejectGate
                        99_000
                        [(request 1, young, Just 100_000), (request 2, young, Just 90_000)]
            case refusal of
                Left r@(WindowsOpen open) -> do
                    map openRequest open `shouldBe` [request 1]
                    let said = renderRejectRefusal r
                    mapM_
                        (\needle -> said `shouldSatisfy` isInfixOf needle)
                        [ T.unpack (renderOutRef (request 1))
                        , show (retractEnds young)
                        , "100000"
                        , "99000"
                        ]
                    said
                        `shouldNotSatisfy` isInfixOf (T.unpack (renderOutRef (request 2)))
                other ->
                    expectationFailure ("expected the open windows, got " <> show other)

-- ---------------------------------------------------------
-- What a reject refunds
-- ---------------------------------------------------------

refunds :: Spec
refunds = describe "the refund each rejected request's owner is owed" $ do
    it "is the whole owed amount in the output designated for it" $
        shape
            [("alice", 5_000_000), ("bob", 7_000_000)]
            [("alice", 5_000_000), ("bob", 7_000_000)]
            `shouldBe` Right [5_000_000, 7_000_000]
    it
        "may be topped up past the owed amount, and reports what the output pays"
        $ shape [("alice", 5_000_000)] [("alice", 5_400_000)]
            `shouldBe` Right [5_400_000]
    it
        "is refused when the owed amount is split across two outputs to its owner (the chain's reading)"
        $ do
            -- #361: the model sums the owner's outputs; the chain wants the designated one whole.
            shape [("alice", 5_000_000)] [("alice", 4_999_999), ("alice", 1)]
                `shouldBe` Left (ShortRefund 0 5_000_000 4_999_999)
    it "is refused when the designated output pays another recipient" $
        shape
            [("alice", 5_000_000), ("bob", 7_000_000)]
            [("alice", 5_000_000), ("carol", 7_000_000)]
            `shouldBe` Left (WrongRecipient 1)
    it "is refused when an owed refund has no output" $
        shape
            [("alice", 5_000_000), ("bob", 7_000_000)]
            [("alice", 5_000_000)]
            `shouldBe` Left (TooFewOutputs 2 1)
    it
        "names the request index, the owed amount and the amount paid when short"
        $ renderRefundMismatch (ShortRefund 1 7_000_000 6_999_999)
            `shouldSatisfy` \said -> all (`isInfixOf` said) ["7000000", "6999999"]
    it
        "refuses any single shortfall among several requests and admits none missing"
        $ property
        $ forAll (chooseInteger (2, 6))
        $ \n ->
            forAll
                (vectorOf (fromInteger n) (chooseInteger (2_000_000, 50_000_000)))
                $ \owed ->
                    forAll (elements [0 .. fromInteger n - 1]) $ \short ->
                        let owners = [T.pack ("owner" <> show i) | i <- [1 .. n]]
                            expected = zip owners owed
                            exact = expected
                            lowered =
                                [ if i == short then (o, a - 1) else (o, a)
                                | (i, (o, a)) <- zip [0 :: Int ..] expected
                                ]
                        in  (shape expected exact, isLeft (shape expected lowered))
                                === (Right owed, True)

-- | The check, at the owners' names.
shape
    :: [(T.Text, Integer)]
    -> [(T.Text, Integer)]
    -> Either RefundMismatch [Integer]
shape = refundShape
