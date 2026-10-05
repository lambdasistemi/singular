{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.FoldSpec
Description : What decides a fold, and the envelope a booking leaves for it
License     : Apache-2.0

A fold is signed by a wallet that did not book the request, possibly
long after the booking. These rows fix the decisions it makes before it
builds anything — which request, which edge, how much of the processing
window is left — and the store that carries an insertion's envelope from
the booking to the fold. Every expected value is derived here from the
inputs by arithmetic, or produced by the code that hashes the envelope,
never typed.
-}
module Singular.CLI.FoldSpec (spec) where

import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Functor.Identity (Identity (..))
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text qualified as T
import Data.Word (Word64)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Test.QuickCheck
    ( Gen
    , chooseInteger
    , elements
    , forAll
    , property
    , (===)
    , (==>)
    )

import Cardano.Ledger.Api.Tx.Out (mkBasicTxOut)
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    )
import Cardano.Ledger.TxIn (TxIn)
import PlutusCore.Data qualified as PLC

import Singular.Application.OpenDatum.Envelope
    ( Control (..)
    , Envelope (..)
    , StateAsset (..)
    , envelopeHash
    , envelopeToJson
    , envelopeVersion
    )
import Singular.CLI.FoldRules
import Singular.CLI.Preimage
import Singular.Registry.Deployment (parseOutRef, renderOutRef)
import Singular.Registry.SessionIO (outputsAt)
import Singular.Registry.StubSession
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , policyIdFromPin
    )
import Singular.Registry.Types
    ( edgeDeleteAbsent
    , edgeDeleteActive
    , edgeInsertAbsent
    , edgeInsertActive
    , edgeName
    , edgeUpdateActive
    , edgeUpdateTerminal
    , edgeWitnessTerminal
    )

spec :: Spec
spec = describe "registry fold" $ do
    window
    postBuild
    postBuildDecisions
    boundTimes
    target
    kinds
    funding
    preimages

-- ---------------------------------------------------------
-- The processing window
-- ---------------------------------------------------------

window :: Spec
window = describe "the processing window" $ do
    it
        "keeps a margin no shorter than the library's longest fallback bound"
        $ do
            -- the library's fallback bounds are now plus 30, 5 and 2 seconds
            libraryFallbackMs `shouldBe` 30_000
            foldMarginMs `shouldSatisfy` (>= libraryFallbackMs)
    it
        "states a request's deadline as its submission plus the processing time"
        $ do
            -- worked by hand: 1_700_000_000_000 + 120_000
            requestDeadline 1_700_000_000_000 120_000 `shouldBe` 1_700_000_120_000
    it "adds the two for any submission and processing time" $
        property $
            forAll (chooseInteger (0, 4_000_000_000_000)) $ \s ->
                forAll (chooseInteger (1, 10_000_000)) $ \p ->
                    requestDeadline s p === s + p
    it
        "is open exactly while more than the margin remains before the deadline"
        $ property
        $ forAll (chooseInteger (0, 4_000_000_000_000))
        $ \now ->
            forAll (chooseInteger (-100_000, 400_000)) $ \ahead ->
                forAll (chooseInteger (0, 60_000)) $ \margin ->
                    foldWindow margin now (now + ahead)
                        === if ahead > margin then FoldOpen ahead else FoldClosed ahead
    it
        "is closed whenever the deadline is not ahead of now, wherever either lies"
        $ property
        $ forAll (chooseInteger (-4_000_000_000_000, 4_000_000_000_000))
        $ \deadline ->
            forAll (chooseInteger (0, 4_000_000_000_000)) $ \behind ->
                forAll (chooseInteger (0, 60_000)) $ \margin ->
                    -- a deadline before the chain's origin, or a now past the deadline
                    foldWindow margin (deadline + behind) deadline
                        === FoldClosed (negate behind)
    it
        "answers the same at the extremes of a 64-bit clock, never wrapping"
        $ do
            let top = toInteger (maxBound :: Word64)
            foldWindow foldMarginMs top 0 `shouldBe` FoldClosed (negate top)
            foldWindow foldMarginMs 0 (negate top)
                `shouldBe` FoldClosed (negate top)
            foldWindow foldMarginMs (negate top) top `shouldBe` FoldOpen (2 * top)
    it
        "closes at the margin itself and stays open one millisecond before it"
        $ do
            let deadline = 1_700_000_120_000
                margin = foldMarginMs
                at now = foldWindow margin now deadline
            at (deadline - margin) `shouldBe` FoldClosed margin
            at (deadline - margin - 1) `shouldBe` FoldOpen (margin + 1)
    it "is closed past the deadline, naming how far past" $
        foldWindow foldMarginMs 1_700_000_130_000 1_700_000_120_000
            `shouldBe` FoldClosed (-10_000)
    it "never reopens as time advances" $
        property $
            forAll (chooseInteger (0, 1_000_000)) $ \t1 ->
                forAll (chooseInteger (0, 1_000_000)) $ \gap ->
                    let t2 = t1 + gap
                        open t = case foldWindow foldMarginMs t 600_000 of
                            FoldOpen _ -> True
                            FoldClosed _ -> False
                    in  not (open t2) || open t1

-- ---------------------------------------------------------
-- The built fold, before it is signed
-- ---------------------------------------------------------

postBuild :: Spec
postBuild = describe "the built fold's validity bound" $ do
    let deadline = 1_700_000_120_000
        early = deadline - 2 * foldMarginMs
    it "admits a bound at the deadline's slot, equality included" $
        postBuildCheck early deadline (Just 5_000) (Just 5_000) Nothing
            `shouldBe` PostBuildAdmitted BoundByDeadlineSlot
    it "refuses a bound one slot past the deadline's slot, naming both" $
        postBuildCheck early deadline (Just 5_000) (Just 5_001) Nothing
            `shouldBe` PostBuildRefused (BoundBeyondDeadlineSlot 5_001 5_000)
    it
        "admits a bound exactly when it is at or before the slot, over every slot and offset"
        $ property
        $ forAll (chooseInteger (-5, 1_000_000))
        $ \s ->
            forAll (chooseInteger (-3, 3)) $ \off ->
                postBuildCheck early deadline (Just s) (Just (s + off)) Nothing
                    === if off <= 0
                        then PostBuildAdmitted BoundByDeadlineSlot
                        else PostBuildRefused (BoundBeyondDeadlineSlot (s + off) s)
    it
        "compares in time when the deadline has no slot: at the deadline admitted, one millisecond after refused"
        $ do
            postBuildCheck early deadline Nothing (Just 7) (Just deadline)
                `shouldBe` PostBuildAdmitted BoundByTime
            postBuildCheck early deadline Nothing (Just 7) (Just (deadline + 1))
                `shouldBe` PostBuildRefused (BoundAfterDeadline (deadline + 1))
            postBuildCheck early deadline Nothing (Just 7) (Just (deadline - 1))
                `shouldBe` PostBuildAdmitted BoundByTime
    it
        "refuses a bound that cannot be converted to a time, never estimating one"
        $ postBuildCheck early deadline Nothing (Just 7) Nothing
            `shouldBe` PostBuildRefused BoundUnconvertible
    it "refuses a fold with no upper bound" $ do
        postBuildCheck early deadline (Just 5_000) Nothing Nothing
            `shouldBe` PostBuildRefused NoUpperBound
        postBuildCheck early deadline Nothing Nothing Nothing
            `shouldBe` PostBuildRefused NoUpperBound
    it
        "refuses a fold whose preparation ran into the margin, whatever its bound says"
        $
        -- the failure witness: the clock moved on between the guard and the build
        property
        $ forAll (chooseInteger (0, 4 * foldMarginMs))
        $ \held ->
            let now = early + foldMarginMs + held
                verdict = postBuildCheck now deadline (Just 5_000) (Just 5_000) Nothing
            in  if now + foldMarginMs >= deadline
                    then verdict === PostBuildRefused ClockWithinMargin
                    else verdict === PostBuildAdmitted BoundByDeadlineSlot
    it "finds the time a slot begins when the view places every probe" $
        property $
            forAll (elements [100, 1_000]) $ \len ->
                forAll (chooseInteger (10, 100_000)) $ \u ->
                    forAll (chooseInteger (1, 5_000)) $ \behind ->
                        forAll (chooseInteger (0, 3_000)) $ \ahead ->
                            let slotOf ms
                                    | ms < 0 || ms >= 10_000_000 * len = Identity Nothing
                                    | otherwise = Identity (Just (ms `div` len))
                                start = u * len
                                -- the bracket precondition: the low end is placed, before the slot
                                lo = max 0 (start - behind)
                            in  lo < start ==>
                                    ( runIdentity (boundStartMs slotOf lo (start + ahead) u)
                                        === Just start
                                    )
    it "finds nothing from a bracket whose low end the view cannot place" $ do
        -- slots of 100 ms; a negative time is not placed by this view
        let slotOf ms
                | ms < 0 = Identity Nothing
                | otherwise = Identity (Just (ms `div` 100))
        runIdentity (boundStartMs slotOf (-5_000) 9_000 50) `shouldBe` Nothing
        runIdentity (boundStartMs slotOf 1_000 9_000 50) `shouldBe` Just 5_000
    it "never reads a probe the view could not place as an answer" $ do
        -- the end points place slots 0 and 4; every time between them is unplaced
        let slotOf ms
                | ms == 0 = Identity (Just 0)
                | ms == 8 = Identity (Just 4)
                | otherwise = Identity Nothing
        runIdentity (boundStartMs slotOf 0 8 3) `shouldBe` Nothing
    it
        "returns a time only when the view placed it at the slot and the time before it short of it"
        $ property
        $ forAll (chooseInteger (2, 9))
        $ \k ->
            forAll (chooseInteger (0, 8)) $ \r ->
                forAll (chooseInteger (10, 5_000)) $ \u ->
                    forAll (chooseInteger (0, 400)) $ \loStep ->
                        -- a converter that fails at arbitrary interior times
                        let conv ms
                                | ms < 0 = Nothing
                                | ms `mod` k == r `mod` k && ms /= lo && ms /= hi = Nothing
                                | otherwise = Just (ms `div` 10)
                            lo = max 0 (u * 10 - loStep - 1)
                            hi = u * 10 + 50
                            confirmed t = case (conv t, conv (t - 1)) of
                                (Just a, Just b) -> a >= u && b < u
                                _ -> False
                        in  maybe
                                True
                                confirmed
                                (runIdentity (boundStartMs (Identity . conv) lo hi u))
                                === True
    it
        "finds nothing when the view does not place the ends around the slot"
        $ do
            let slotOf ms = Identity (Just (ms `div` 100))
            runIdentity (boundStartMs slotOf 1_000 9_000 50) `shouldBe` Just 5_000
            runIdentity (boundStartMs slotOf 9_000 9_500 50) `shouldBe` Nothing
            runIdentity (boundStartMs slotOf 1_000 4_000 50) `shouldBe` Nothing
            runIdentity (boundStartMs (const (Identity Nothing)) 1_000 4_000 50)
                `shouldBe` Nothing

-- ---------------------------------------------------------
-- Which request
-- ---------------------------------------------------------

request :: Char -> TxIn
request c = either error id (parseOutRef (T.pack (replicate 64 c <> "#0")))

target :: Spec
target = describe "the request a fold takes" $ do
    let a = request 'a'
        b = request 'b'
        c = request 'c'
    it "is the one pending request, named or not" $ do
        foldTarget Nothing [a] `shouldBe` Right a
        foldTarget (Just a) [a] `shouldBe` Right a
    it
        "refuses a fold with nothing pending, even one that names a request"
        $ do
            foldTarget Nothing [] `shouldBe` Left NothingPending
            foldTarget (Just a) [] `shouldBe` Left NothingPending
    it "refuses a named request that is not the one pending" $
        foldTarget (Just b) [a] `shouldBe` Left (NotPending b)
    it "refuses more than one pending request, naming every one" $ do
        foldTarget Nothing [a, b, c]
            `shouldBe` Left (SeveralPending [a, b, c])
        foldTarget (Just a) [a, b] `shouldBe` Left (SeveralPending [a, b])
    it "words each refusal with what it names" $ do
        renderTargetRefusal NothingPending
            `shouldSatisfy` isInfixOf "nothing is pending"
        renderTargetRefusal (NotPending b)
            `shouldSatisfy` isInfixOf (T.unpack (renderOutRef b))
        forM_ [a, b, c] $ \r ->
            renderTargetRefusal (SeveralPending [a, b, c])
                `shouldSatisfy` isInfixOf (T.unpack (renderOutRef r))

-- ---------------------------------------------------------
-- Which edge
-- ---------------------------------------------------------

kinds :: Spec
kinds = describe "the edges a fold takes" $ do
    it "folds an insertion to Active and a termination" $ do
        foldKind edgeInsertActive `shouldBe` Right FoldInsertion
        foldKind edgeUpdateTerminal `shouldBe` Right FoldTermination
    it "refuses every other edge, naming it"
        $ forM_
            [ edgeInsertAbsent
            , edgeUpdateActive
            , edgeDeleteAbsent
            , edgeDeleteActive
            , edgeWitnessTerminal
            , 7
            , 42
            ]
        $ \e -> case foldKind e of
            Left why -> why `shouldSatisfy` isInfixOf (edgeName e)
            Right k -> expectationFailure ("edge " <> show e <> " folded as " <> show k)

-- ---------------------------------------------------------
-- The envelope a booking leaves
-- ---------------------------------------------------------

envelopeWith :: PLC.Data -> Envelope
envelopeWith payload =
    Envelope
        { envControl =
            Control
                { ctlVersion = envelopeVersion
                , ctlRegistry = StateAsset (BS.replicate 28 0x11) "registry"
                , ctlActivePolicy = BS.replicate 28 0x22
                , ctlKey = "key"
                , ctlController = BS.replicate 28 0x33
                , ctlDeposit = 2_000_000
                }
        , envPayload = payload
        }

genPayload :: Gen PLC.Data
genPayload = PLC.I <$> chooseInteger (-1_000_000, 1_000_000)

preimages :: Spec
preimages = describe "the envelope a booking leaves for its fold" $ do
    it "accepts the envelope the request's hash names" $
        property $
            forAll genPayload $ \p ->
                let e = envelopeWith (PLC.I 0) `withPayload` p
                in  verifyPreimage (envelopeHash e) e === Right e
    it "refuses any other envelope, naming both hashes" $
        property $
            forAll genPayload $ \p ->
                forAll genPayload $ \q ->
                    let want = envelopeWith p
                        got = envelopeWith q
                    in  (p /= q) ==>
                            ( verifyPreimage (envelopeHash want) got
                                === Left (PreimageMismatch (envelopeHash want) (envelopeHash got))
                            )
    it
        "keeps each envelope under its own hash, inside the registry directory"
        $ withSystemTempDirectory "preimage"
        $ \dir -> do
            let e1 = envelopeWith (PLC.I 1)
                e2 = envelopeWith (PLC.I 2)
            storePreimage dir e1
            storePreimage dir e2
            loadPreimage dir (envelopeHash e1) `shouldReturn` Right e1
            loadPreimage dir (envelopeHash e2) `shouldReturn` Right e2
            preimagePath dir (envelopeHash e1)
                `shouldNotBe` preimagePath dir (envelopeHash e2)
            takeDirectory (preimagePath dir (envelopeHash e1))
                `shouldSatisfy` isInfixOf dir
    it "refuses an envelope nothing was stored for" $
        withSystemTempDirectory "preimage" $ \dir -> do
            let e = envelopeWith (PLC.I 1)
            loadPreimage dir (envelopeHash e)
                `shouldReturn` Left (PreimageMissing (envelopeHash e))
    it "refuses a stored file that is not the envelope its name says" $
        withSystemTempDirectory "preimage" $ \dir -> do
            let e1 = envelopeWith (PLC.I 1)
                e2 = envelopeWith (PLC.I 2)
            storePreimage dir e1
            -- another envelope's document under e1's name
            writeEnvelope (preimagePath dir (envelopeHash e1)) e2
            loadPreimage dir (envelopeHash e1)
                `shouldReturn` Left (PreimageMismatch (envelopeHash e1) (envelopeHash e2))
    it "refuses a stored file that is not an envelope at all" $
        withSystemTempDirectory "preimage" $ \dir -> do
            let e = envelopeWith (PLC.I 1)
                path = preimagePath dir (envelopeHash e)
            createDirectoryIfMissing True (takeDirectory path)
            BS.writeFile path "not json"
            loadPreimage dir (envelopeHash e) >>= \case
                Left (PreimageUnreadable h _) -> h `shouldBe` envelopeHash e
                other ->
                    expectationFailure
                        ("expected an unreadable preimage, got " <> show other)
    it "words each refusal with what it names" $ do
        let e = envelopeWith (PLC.I 1)
            h = envelopeHash e
        renderPreimageRefusal (PreimageMissing h)
            `shouldSatisfy` isInfixOf "no envelope"
        renderPreimageRefusal
            (PreimageMismatch h (envelopeHash (envelopeWith (PLC.I 2))))
            `shouldSatisfy` isInfixOf "another envelope"
  where
    withPayload e p = e{envPayload = p}
    writeEnvelope path e = do
        createDirectoryIfMissing True (takeDirectory path)
        Aeson.encodeFile path (envelopeToJson e)

-- ---------------------------------------------------------
-- Which funding
-- ---------------------------------------------------------

funding :: Spec
funding = describe "the funding a fold is built from" $ do
    let wallet = addrFromKeyHashBytes Testnet (BS.replicate 28 0x5a)
        other = addrFromKeyHashBytes Testnet (BS.replicate 28 0x6b)
        coin n = mkBasicTxOut wallet (MaryValue (Coin n) mempty)
        withToken =
            mkBasicTxOut
                wallet
                ( MaryValue
                    (Coin 90_000_000)
                    ( MultiAsset
                        ( Map.singleton
                            (policyIdFromPin (SBS.toShort (BS.replicate 28 0x44)))
                            (Map.singleton (AssetName "token") 1)
                        )
                    )
                )
        ref c = either error id (parseOutRef (T.pack (replicate 64 c <> "#0")))
        small = ref 'a'
        large = ref 'b'
        tokened = ref 'c'
        theirs = ref 'd'
        serving =
            ( withAddressOutputs
                ( \a ->
                    pure $
                        if a == wallet
                            then
                                [ (small, coin 5_000_000)
                                , (large, coin 50_000_000)
                                , (tokened, withToken)
                                ]
                            else
                                [(theirs, mkBasicTxOut other (MaryValue (Coin 7_000_000) mempty))]
                )
                $ stubSession
            )
        readWallet v = map fst <$> outputsAt v wallet
    it "is the wallet's own view when no funding is named" $ do
        Right v <- fundedView Nothing wallet serving
        readWallet v `shouldReturn` [small, large, tokened]
    it
        "shows the wallet only the output the caller named, and other addresses untouched"
        $ do
            Right v <- fundedView (Just small) wallet serving
            readWallet v `shouldReturn` [small]
            map fst <$> outputsAt v other `shouldReturn` [theirs]
    it "refuses an output that is not an ada-only output of the wallet" $ do
        forM_ [tokened, theirs, ref 'e'] $ \chosen ->
            fundedView (Just chosen) wallet serving >>= \case
                Left why -> why `shouldSatisfy` isInfixOf "not an ada-only output"
                Right _ -> expectationFailure ("accepted " <> show chosen)

-- ---------------------------------------------------------
-- The start time of a fold's bound, inside the node's horizon
-- ---------------------------------------------------------

boundTimes :: Spec
boundTimes = describe "the start time of a built fold's bound" $ do
    -- A view that places a time only up to its horizon, in slots of 100 ms.
    let viewAt horizon ms
            | ms < 0 || ms > horizon = Identity Nothing
            | otherwise = Identity (Just (ms `div` 100))
        startOf slot = slot * 100
    it
        "is found when the library bounded the fold inside a horizon that ends before the clock's reach"
        $ property
        $ forAll (chooseInteger (1_000_000, 9_000_000))
        $ \libraryClock ->
            forAll (elements [libraryFallbackMs, 5_000, 2_000]) $ \width ->
                forAll (chooseInteger (1, 20_000)) $ \elapsed ->
                    forAll (chooseInteger (0, 5_000)) $ \spare ->
                        -- the library converted libraryClock + width; the host clock has
                        -- since moved on by `elapsed`, and the horizon ends `spare` past
                        -- the later of the two, so the clock's own reach (+ 30 s) is past it
                        let now = libraryClock + elapsed
                            horizon = max (libraryClock + width) now + spare
                            bound = (libraryClock + width) `div` 100
                        in  runIdentity (boundStartTime (viewAt horizon) now bound)
                                === Just (startOf bound)
    it
        "is still refused when no time the view places is at or after the bound's slot"
        $ property
        $ forAll (chooseInteger (1_000_000, 9_000_000))
        $ \now ->
            forAll (chooseInteger (1, 400)) $ \beyond ->
                -- the horizon ends before the bound's slot begins
                let horizon = now + 5_000
                    bound = horizon `div` 100 + beyond
                in  runIdentity (boundStartTime (viewAt horizon) now bound) === Nothing
    it "is found as before when the horizon is far" $
        property $
            forAll (chooseInteger (1_000_000, 9_000_000)) $ \now ->
                forAll (chooseInteger (1, libraryFallbackMs)) $ \width ->
                    let bound = (now + width) `div` 100
                    in  runIdentity (boundStartTime (viewAt (now + 600_000)) now bound)
                            === Just (startOf bound)
    it
        "searches only times the view places, whatever it fails to place inside the range"
        $ property
        $ forAll (chooseInteger (2, 9))
        $ \k ->
            forAll (chooseInteger (100, 5_000)) $ \hi ->
                -- a converter that places times up to hi - 1 except at arbitrary interior ones
                let conv ms
                        | ms < 0 || ms >= hi = Nothing
                        | ms /= 0 && ms `mod` k == 1 = Nothing
                        | otherwise = Just (ms `div` 10)
                    probed = runIdentity (placedEdge (Identity . conv) 0 (hi + 10))
                in  maybe True (\t -> t >= 0 && t <= hi + 10 && isJust (conv t)) probed
                        === True

-- ---------------------------------------------------------
-- The decision on a built fold, before it is signed
-- ---------------------------------------------------------

{- | The post-build witness: the one decision the fold takes over a built
body's upper bound, driven with a controlled clock and a controlled
converter. The development network cannot reach it end to end: near a
window's end the library's own fallback times lie past the node's
horizon, so no fold is built there to be judged.
-}
postBuildDecisions :: Spec
postBuildDecisions = describe
    "the decision on a built fold's bound, over a clock and a converter"
    $ do
        let deadline = 1_700_000_120_000
            early = deadline - 2 * foldMarginMs
            -- slots of 100 ms, placed up to a horizon
            viewAt horizon ms
                | ms < 0 || ms > horizon = Identity Nothing
                | otherwise = Identity (Just (ms `div` 100))
            decide horizon now deadlineSlot upper =
                runIdentity
                    (postBuildDecision (viewAt horizon) now deadline deadlineSlot upper)
            farHorizon = deadline + 600_000
        it
            "admits a bound whose start the view places at or before the deadline"
            $ do
                let bound = (early + libraryFallbackMs) `div` 100
                decide farHorizon early Nothing (Just bound)
                    `shouldBe` (PostBuildAdmitted BoundByTime, Just (bound * 100))
        it
            "admits at the deadline's own slot when the view converts the deadline"
            $ decide farHorizon early (Just 5_000) (Just 5_000)
                `shouldBe` (PostBuildAdmitted BoundByDeadlineSlot, Nothing)
        it
            "refuses a bound that begins after the deadline, which no time the search can confirm reaches"
            $ do
                let bound = (deadline + 1_000) `div` 100
                fst (decide farHorizon early Nothing (Just bound))
                    `shouldSatisfy` \case PostBuildRefused _ -> True; _ -> False
        it "refuses a bound the view cannot place, never estimating a time" $
            decide (-1) early Nothing (Just 12_345)
                `shouldBe` (PostBuildRefused BoundUnconvertible, Nothing)
        it "refuses a fold with no upper bound" $
            fst (decide farHorizon early Nothing Nothing)
                `shouldBe` PostBuildRefused NoUpperBound
        it
            "refuses, whatever the bound says, when the clock after the build is within the margin"
            $ fst
                (decide farHorizon (deadline - foldMarginMs) (Just 5_000) (Just 5_000))
                `shouldBe` PostBuildRefused ClockWithinMargin
        it
            "admits a bound only when its start is placed at or before the deadline"
            $ property
            $ forAll
                (chooseInteger (early `div` 100 - 50, deadline `div` 100 + 200))
            $ \bound ->
                forAll (chooseInteger (early, deadline + 20_000)) $ \horizon ->
                    case decide horizon early Nothing (Just bound) of
                        (PostBuildAdmitted _, Just start) ->
                            (start <= deadline, start == bound * 100) === (True, True)
                        (PostBuildAdmitted _, Nothing) -> property False
                        (PostBuildRefused _, _) -> property True
