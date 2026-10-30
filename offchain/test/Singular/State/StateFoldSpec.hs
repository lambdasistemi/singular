{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Singular.State.StateFoldSpec
Description : The fold builder meets the compiled state validator, from public data alone
License     : Apache-2.0

As a folder who is not the booker I hold a wallet and the address of a
registry. From the chain alone I find the registry's state, rebuild its trie
from the history of its state token and fold the pending registrations: their
approvals are burned, their keys proved absent, their tokens minted into the
holdings they committed to with at least their deposits, and what they hold
above the deposit comes to me. The compiled state validator accepts the
transaction, and refuses it again when one fact of it is made wrong.
-}
module Singular.State.StateFoldSpec
    ( spec
    ) where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Word (Word32)
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC
import Test.Hspec

import Cardano.Crypto.DSIGN
    ( Ed25519DSIGN
    , SignKeyDSIGN
    , deriveVerKeyDSIGN
    , genKeyDSIGN
    )
import Cardano.Crypto.Seed (mkSeedFromBytes)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Alonzo.TxWits (Redeemers (..))
import Cardano.Ledger.Api.PParams (ppMaxTxExUnitsL, ppMaxTxSizeL)
import Cardano.Ledger.Api.Tx (addrTxWitsL, witsTxL)
import Cardano.Ledger.Api.Tx.Out
    ( addrTxOutL
    , coinTxOutL
    , datumTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits (rdmrsTxWitsL)
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (eraProtVerHigh)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Keys
    ( KeyHash (..)
    , KeyRole (Guard)
    , VKey (..)
    , hashKey
    )
import Cardano.Ledger.Mary.Value
    ( AssetName
    , MaryValue (..)
    , MultiAsset (..)
    )
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Evidence (value)
import Singular.Registry.Ledger (ConwayEra, TxOut)
import Singular.Registry.LedgerProvider
    ( OutputQuery (..)
    , ReadFailure (..)
    , Session (..)
    )
import Singular.Registry.RawChainFixture
    ( ChainFacts (..)
    , advanceChain
    )
import Singular.Registry.Signing (signTx, signedTx)
import Singular.Registry.Trace (Evaluation (..))
import Singular.Registry.TrieState (RegistryIdentity (..))
import Singular.Registry.TxBuilder.Internal (mkInlineDatum)
import Singular.State.Batch
    ( BatchSelection (..)
    , largestFittingPrefix
    )
import Singular.State.Fold
    ( Application (..)
    , FoldFailure (..)
    , FoldResult (..)
    , Request (..)
    , SkipReason (..)
    , SkippedHolder (..)
    , attemptFold
    , buildFold
    , buildRegistrationFold
    , discoverPending
    , foldedRequests
    , pendingRef
    )
import Singular.State.Preimage
    ( activeTokenName
    , approvalName
    , terminationPreimage
    )
import Singular.State.Records
    ( Change (..)
    , decodeFoldRedeemer
    , foldRedeemer
    , stateDatum
    )
import Singular.State.Refusal (CapacityLimit (..), Refusal (..))
import Singular.State.Script
    ( stateAddress
    , statePolicy
    )
import Singular.State.StateWorld

spec :: Spec
spec = do
    describe "unfoldable public requests" $ do
        forM_ [True, False] $ \expiredFirst -> it
            ( if expiredFirst
                then
                    "lets a current request take the key after an earlier expired one is skipped"
                else
                    "keeps a later expired request's own refusal instead of calling it a duplicate"
            )
            $ do
                rg <- newRegistered
                [expired, current] <-
                    book
                        rg
                        'v'
                        [ (bookedKey "same key" 1)
                            { bkTip = if expiredFirst then 9_000_000 else 1_000_000
                            }
                        , (bookedKey "same key" processingDeadline)
                            { bkTip = if expiredFirst then 1_000_000 else 9_000_000
                            }
                        ]
                control <- expectBuilt =<< foldNow rg [current]
                judge (rgWorld rg) control >>= (`shouldSatisfy` everyScriptAccepts)
                selected <- fitting rg Nothing
                map pendingRef (foldSelected selected) `shouldBe` [current]
                map skippedRef (foldSkipped selected) `shouldBe` [expired]
                show (map skippedReason (foldSkipped selected))
                    `shouldSatisfy` Text.isInfixOf "ProcessingWindowClosed" . Text.pack
                foldLeft selected `shouldBe` 0
        it "skips every request-local refusal beside its foldable control" $ do
            (rg, application, bad, good) <- unfoldablePool
            forM_ bad $ \(_, named, reason, control) -> do
                built <- expectBuilt =<< foldWithApplication rg application [control]
                judge (rgWorld rg) built >>= (`shouldSatisfy` everyScriptAccepts)
                refusal <- foldWithApplication rg application named
                show refusal `shouldSatisfy` Text.isInfixOf reason . Text.pack
                refusal `shouldSatisfy` isLeft
            selected <- withSession (rgWorld rg) $ \session ->
                expectBuilt
                    =<< buildFold
                        session
                        (rgScript rg)
                        application
                        (rgRegistry rg)
                        []
                        (rgFolder rg)
                        (Just 1)
            map pendingRef (foldSelected selected) `shouldSatisfy` \refs -> length refs == 1 && all (`elem` good) refs
            map skippedRef (foldSkipped selected)
                `shouldMatchList` [last named | (_, named, _, _) <- bad]
            forM_ bad $ \(_, named, reason, _) ->
                [ Text.pack (show (skippedReason holder))
                | holder <- foldSkipped selected
                , skippedRef holder == last named
                ]
                    `shouldSatisfy` \reasons -> length reasons == 1 && all (Text.isInfixOf reason) reasons
            foldLeft selected `shouldBe` length good - 1
            length (foldSelected selected)
                + length (foldSkipped selected)
                + foldLeft selected
                `shouldBe` 10
            judge (rgWorld rg) (foldTransaction selected)
                >>= (`shouldSatisfy` everyScriptAccepts)
            whole <- withSession (rgWorld rg) $ \session ->
                expectBuilt
                    =<< buildFold
                        session
                        (rgScript rg)
                        application
                        (rgRegistry rg)
                        []
                        (rgFolder rg)
                        Nothing
            map pendingRef (foldSelected whole) `shouldSatisfy` \refs -> not (null refs) && all (`elem` good) refs
            map skippedRef (foldSkipped whole)
                `shouldMatchList` [last named | (_, named, _, _) <- bad]
            foldLeft whole `shouldBe` length good - length (foldSelected whole)
            judge (rgWorld rg) (foldTransaction whole)
                >>= (`shouldSatisfy` everyScriptAccepts)
        it "retains every skipped request when none can fold" $ do
            (rg, application, bad, _) <- unfoldablePool
            let rejected = [last named | (label, named, _, _) <- bad, label /= "duplicate"]
            -- Retain only these four approval holders, leaving state and payer outputs intact.
            advanceChain (worldChain (rgWorld rg)) $ \facts ->
                facts
                    { csUTxO =
                        Map.filterWithKey
                            (\ref output -> not (hasApprovals output) || ref `elem` rejected)
                            (csUTxO facts)
                    }
            outcome <- withSession (rgWorld rg) $ \session ->
                attemptFold
                    session
                    (rgScript rg)
                    application
                    (rgRegistry rg)
                    []
                    (rgFolder rg)
                    Nothing
            case outcome of
                Left failure -> do
                    foldFailureReason failure `shouldBe` NothingToFold
                    case foldFailureObserved failure of
                        Just (skipped, left) -> do
                            map skippedRef skipped `shouldMatchList` rejected
                            left `shouldBe` 0
                        Nothing -> expectationFailure "complete public request accounting was lost"
                Right result -> expectationFailure (show result)
    describe "submitted batch bytes" $
        forM_ [1, 2, 24] $ \count -> do
            it
                ( "fits the automatic prefix after all "
                    <> show count
                    <> " required witnesses"
                )
                $ do
                    (rg, application, keys, [high, _], limit) <-
                        prepareSubmissionBoundary count
                    tx <- expectBuilt =<< foldWithApplication rg application []
                    ( serializedBytes (signedBy keys tx) <= limit
                        , map fst (foldedRequests tx)
                        )
                        `shouldBe` (True, [high])
                    judge (rgWorld rg) (signedBy keys tx)
                        >>= (`shouldSatisfy` everyScriptAccepts)
            it
                ( "refuses a named batch exceeding bytes with "
                    <> show count
                    <> " required witnesses"
                )
                $ do
                    (rg, application, _, refs, limit) <- prepareSubmissionBoundary count
                    result <- foldWithApplication rg application refs
                    case result of
                        Left (CapacityExceeded (TransactionSize used allowed)) -> do
                            used `shouldSatisfy` (> limit)
                            allowed `shouldBe` limit
                        Left other -> expectationFailure (show other)
                        Right _ -> expectationFailure "the oversized submitted batch was built"
    describe "the largest fitting public batch" $ do
        it "counts the evaluated larger probe as well as the selected batch" $ do
            (rg, [one, two, _], _) <- prepareByteBoundary
            -- Owned by this example and its serial sessions; no worker escapes.
            evaluations <- newIORef []
            let observed session =
                    session
                        { sessionEvaluated = \evaluation -> do
                            modifyIORef' evaluations (<> [evaluation])
                            sessionEvaluated session evaluation
                        }
                run named = withSession (rgWorld rg) $ \session ->
                    expectBuilt
                        =<< buildFold
                            (observed session)
                            (rgScript rg)
                            standInApplication
                            (rgRegistry rg)
                            named
                            (rgFolder rg)
                            Nothing
            _ <- run [one, two]
            control <- readIORef evaluations
            modifyIORef' evaluations (const [])
            selected <- run []
            allProbes <- readIORef evaluations
            length control `shouldSatisfy` (> 0)
            length allProbes `shouldSatisfy` (> length control)
            all
                ( \evaluation ->
                    evalRedeemers evaluation > 0
                        && evalFailed evaluation == 0
                        && evalMemory evaluation > 0
                        && evalSteps evaluation > 0
                )
                allProbes
                `shouldBe` True
            length (foldSelected selected) `shouldBe` 2

        it
            "counts the capped requests left and names the transaction's selection"
            $ do
                rg <- newRegistered
                [low, high, middle] <-
                    book
                        rg
                        'p'
                        [ (bookedKey "low" processingDeadline){bkTip = 1_000_000}
                        , (bookedKey "high" processingDeadline){bkTip = 3_000_000}
                        , (bookedKey "middle" processingDeadline){bkTip = 2_000_000}
                        ]
                let skipped = txInOf 's' 0
                addLive
                    (rgWorld rg)
                    [
                        ( skipped
                        , pendingOutput
                            (rgRegistry rg)
                            (bookedKey "at a key" processingDeadline)
                            & addrTxOutL .~ rgBooker rg
                        )
                    ]
                selected <- fitting rg (Just 2)
                map pendingRef (foldSelected selected) `shouldBe` [high, middle]
                map fst (foldedRequests (foldTransaction selected))
                    `shouldBe` [high, middle]
                foldLeft selected `shouldBe` 1
                foldSkipped selected
                    `shouldBe` [SkippedHolder skipped HeldAtKeyAddress]
                length (foldSelected selected)
                    + length (foldSkipped selected)
                    + foldLeft selected
                    `shouldBe` 4
                foldBoundary selected `shouldBe` Nothing
                low `shouldSatisfy` (`notElem` map pendingRef (foldSelected selected))
                whole <- fitting rg Nothing
                foldLeft whole `shouldBe` 0
                foldBoundary whole `shouldBe` Nothing
                length (foldSelected whole) `shouldBe` 3
                named <- withSession (rgWorld rg) $ \session ->
                    expectBuilt
                        =<< buildFold
                            session
                            (rgScript rg)
                            standInApplication
                            (rgRegistry rg)
                            [low, high, middle]
                            (rgFolder rg)
                            (Just 1)
                map fst (foldedRequests (foldTransaction named))
                    `shouldBe` [low, high, middle]
                foldLeft named `shouldBe` 0

        it "records the measured refusal at the next prefix" $ do
            (rg, refs, limit) <- prepareByteBoundary
            named <- foldNow rg refs
            selected <- fitting rg Nothing
            case named of
                Left (CapacityExceeded boundary@(TransactionSize used allowed)) -> do
                    allowed `shouldBe` limit
                    used `shouldSatisfy` (> allowed)
                    foldBoundary selected `shouldBe` Just boundary
                other -> expectationFailure (show other)
            foldLeft selected `shouldBe` 1
            length (foldSelected selected) `shouldBe` 2

        forM_ ["memory", "steps"] $ \dimension ->
            it
                ("checks actual aggregate " <> dimension <> " at the fitting boundary")
                $ do
                    rg <- newRegistered
                    refs@[one, two, _] <-
                        book
                            rg
                            'p'
                            [ (bookedKey "one" processingDeadline){bkTip = 3_000_000}
                            , (bookedKey "two" processingDeadline){bkTip = 2_000_000}
                            , (bookedKey "three" processingDeadline){bkTip = 1_000_000}
                            ]
                    smaller <- expectBuilt =<< foldNow rg [one, two]
                    larger <- expectBuilt =<< foldNow rg refs
                    let units tx =
                            let Redeemers rs = tx ^. witsTxL . rdmrsTxWitsL
                            in  sum
                                    [ if dimension == "memory" then toInteger m else toInteger s
                                    | (_, ExUnits m s) <- Map.elems rs
                                    ]
                        limit = (units smaller + units larger) `div` 2
                    units smaller `shouldSatisfy` (< units larger)
                    advanceChain (worldChain (rgWorld rg)) $ \facts ->
                        let ExUnits memory steps = csPParams facts ^. ppMaxTxExUnitsL
                            limited =
                                if dimension == "memory"
                                    then ExUnits (fromInteger limit) steps
                                    else ExUnits memory (fromInteger limit)
                        in  facts{csPParams = csPParams facts & ppMaxTxExUnitsL .~ limited}
                    control <- expectBuilt =<< foldNow rg [one, two]
                    judge (rgWorld rg) control >>= (`shouldSatisfy` everyScriptAccepts)
                    selected <- fitting rg Nothing
                    map pendingRef (foldSelected selected) `shouldBe` [one, two]
                    case foldBoundary selected of
                        Just (ExecutionMemory used allowed)
                            | dimension == "memory" ->
                                (used > allowed, allowed) `shouldBe` (True, limit)
                        Just (ExecutionSteps used allowed)
                            | dimension == "steps" ->
                                (used > allowed, allowed) `shouldBe` (True, limit)
                        other -> expectationFailure (show other)

        forM_ ["memory", "steps"] $ \dimension ->
            it
                ( "names genuine CEK "
                    <> dimension
                    <> " exhaustion without shortening a named batch"
                )
                $ do
                    rg <- newRegistered
                    refs <- book rg 'p' [bookedKey "one" processingDeadline]
                    control <- expectBuilt =<< foldNow rg refs
                    judge (rgWorld rg) control >>= (`shouldSatisfy` everyScriptAccepts)
                    advanceChain (worldChain (rgWorld rg)) $ \facts ->
                        let ExUnits memory steps = csPParams facts ^. ppMaxTxExUnitsL
                            limited = if dimension == "memory" then ExUnits 1 steps else ExUnits memory 1
                        in  facts{csPParams = csPParams facts & ppMaxTxExUnitsL .~ limited}
                    named <- foldNow rg refs
                    case named of
                        Left (CapacityExceeded (ExecutionMemory used 1)) | dimension == "memory" -> used `shouldSatisfy` (> 1)
                        Left (CapacityExceeded (ExecutionSteps used 1)) | dimension == "steps" -> used `shouldSatisfy` (> 1)
                        other -> expectationFailure (show other)

        it "tries every longer prefix even when build cost is not monotone" $ do
            let build xs =
                    pure $
                        if length xs `elem` [2, 4]
                            then Right (length xs)
                            else
                                Left (CapacityExceeded (TransactionSize (toInteger (length xs)) 0))
            result <- largestFittingPrefix build Nothing [1 :: Int .. 5]
            result
                `shouldBe` Right (BatchSelection [1, 2, 3, 4] 1 4 (Just (TransactionSize 5 0)))
            capped <- largestFittingPrefix build (Just 3) [1 :: Int .. 5]
            capped
                `shouldBe` Right (BatchSelection [1, 2] 3 2 (Just (TransactionSize 3 0)))

        it
            "refuses an empty selection or exhausted singleton instead of building zero requests"
            $ do
                let emptyBuild _ = pure (Right () :: Either Refusal ())
                    noFit _ =
                        pure
                            (Left (CapacityExceeded (ExecutionMemory 2 1)) :: Either Refusal ())
                largestFittingPrefix emptyBuild Nothing ([] :: [Int])
                    `shouldReturn` Left NothingToFold
                largestFittingPrefix emptyBuild (Just 0) [1 :: Int]
                    `shouldReturn` Left NothingToFold
                largestFittingPrefix noFit Nothing [1 :: Int]
                    `shouldReturn` Left (CapacityExceeded (ExecutionMemory 2 1))

        forM_
            [ ProcessingWindowClosed
            , BuildFailed "TxSizeExceeded is only message text"
            , DuplicateKey "same"
            ]
            $ \refusal ->
                it ("preserves a noncapacity refusal: " <> show refusal) $ do
                    let build xs = pure $ if length xs == 3 then Left refusal else Right ()
                    result <- largestFittingPrefix build Nothing [1 :: Int .. 3]
                    result `shouldBe` Left refusal

        it "orders by the folder's take, independently of provider order" $ do
            rg <- newRegistered
            [low, high, middle] <-
                book
                    rg
                    'p'
                    [ (bookedKey "low" processingDeadline){bkTip = 1_000_000}
                    , (bookedKey "high" processingDeadline){bkTip = 3_000_000}
                    , (bookedKey "middle" processingDeadline){bkTip = 2_000_000}
                    ]
            forM_ [False, True] $ \backwards -> do
                tx <- discoverWithOrder rg backwards
                map fst (foldedRequests tx) `shouldBe` [high, middle, low]

        it
            "breaks equal takes by output reference, even when served backwards"
            $ do
                rg <- newRegistered
                refs <-
                    book
                        rg
                        'p'
                        [ bookedKey "one" processingDeadline
                        , bookedKey "two" processingDeadline
                        ]
                tx <- discoverWithOrder rg True
                map fst (foldedRequests tx) `shouldBe` refs

        it "folds the greatest prefix that builds at a measured byte boundary" $ do
            (rg, [high, middle, _], _) <- prepareByteBoundary
            tx <- discoverFold rg (rgFolder rg)
            map fst (foldedRequests tx) `shouldBe` [high, middle]
            judge (rgWorld rg) tx >>= (`shouldSatisfy` everyScriptAccepts)

        it
            "refuses an oversized named batch without trimming and names the byte limit"
            $ do
                (rg, refs, limit) <- prepareByteBoundary
                namedOutcome <- foldNow rg refs
                namedOutcome `shouldSatisfy` isLeft
                show namedOutcome
                    `shouldSatisfy` (Text.isInfixOf "size" . Text.toLower . Text.pack)
                show namedOutcome
                    `shouldSatisfy` (Text.isInfixOf (Text.pack (show limit)) . Text.pack)

        it "refuses a named expired request and skips it during discovery" $ do
            rg <- newRegistered
            refs@[current, expired] <-
                book
                    rg
                    'p'
                    [ (bookedKey "current" processingDeadline){bkTip = 2_000_000}
                    , (bookedKey "expired" 1){bkTip = 1_000_000}
                    ]
            control <- expectBuilt =<< foldNow rg [current]
            judge (rgWorld rg) control >>= (`shouldSatisfy` everyScriptAccepts)
            foldNow rg refs `shouldReturn` Left ProcessingWindowClosed
            selected <- fitting rg Nothing
            map pendingRef (foldSelected selected) `shouldBe` [current]
            foldSkipped selected
                `shouldBe` [SkippedHolder expired (UnfoldableRequest ProcessingWindowClosed)]
            foldLeft selected `shouldBe` 0

    describe "discovery from public approval holders" $ do
        it "finds the registry's requests without naming their references" $ do
            rg <- newRegistered
            refs <-
                book
                    rg
                    'p'
                    [ bookedKey "one" processingDeadline
                    , bookedKey "two" processingDeadline
                    ]
            -- Owned by this example, serial, released with its session; no worker escapes.
            queries <- newIORef []
            tx <- withSession (rgWorld rg) $ \session -> do
                let counted =
                        session
                            { outputs = \query -> do
                                modifyIORef' queries (<> [query])
                                outputs session query
                            }
                expectBuilt
                    =<< buildRegistrationFold
                        counted
                        (rgScript rg)
                        standInApplication
                        (rgRegistry rg)
                        []
                        (rgFolder rg)
            map fst (foldedRequests tx) `shouldMatchList` refs
            seen <- readIORef queries
            [policy | HoldingPolicy policy <- seen] `shouldBe` [standInPolicy]
            judge (rgWorld rg) tx >>= (`shouldSatisfy` everyScriptAccepts)

        forM_ ["key address", "another registry", "undecodable"] $ \shape ->
            it
                ("skips " <> shape <> " beside an accepted holder of the same request")
                $ do
                    rg <- newRegistered
                    let booked = bookedKey "one" processingDeadline
                        RegistryIdentity policy _ = rgRegistry rg
                        foreignRegistry =
                            RegistryIdentity
                                policy
                                (snd' (registryOf (rgScript rg) (txInOf 'x' 0)))
                        correct = pendingOutput (rgRegistry rg) booked
                        foreignHolder = case shape of
                            "key address" -> correct & addrTxOutL .~ rgBooker rg
                            "another registry" -> pendingOutput foreignRegistry booked
                            _ -> correct & datumTxOutL .~ mkInlineDatum (PLC.I 0)
                        skipped = txInOf 's' 0
                    refs <- book rg 'p' [booked]
                    addLive (rgWorld rg) [(skipped, foreignHolder)]
                    tx <- discoverFold rg (rgFolder rg)
                    map fst (foldedRequests tx) `shouldBe` refs
                    inputsOf tx `shouldSatisfy` (skipped `notElem`)
                    judge (rgWorld rg) tx >>= (`shouldSatisfy` everyScriptAccepts)
                    (found, omitted) <- withSession (rgWorld rg) $ \session -> discoverPending session standInApplication (rgRegistry rg) []
                    map pendingRef found `shouldBe` refs
                    omitted
                        `shouldBe` [ SkippedHolder
                                        skipped
                                        ( case shape of
                                            "key address" -> HeldAtKeyAddress
                                            "another registry" -> DecodedForAnotherRegistry
                                            _ -> NotAcceptedByApplication
                                        )
                                   ]

        describe "the configuration output the description names" $ do
            let
                -- The output with this datum is the stand-in's configuration.
                naming datum =
                    standInApplication
                        { appIsConfiguration = \output -> inlineDatum output == Just datum
                        }
                marker = PLC.Constr 7 [PLC.I 7]
                -- A datum shaped like an application's configuration that the stand-in does not name.
                lookalike = PLC.Constr 0 [PLC.Constr 0 (map PLC.I [1, 2, 3, 4, 5])]
                holding rg datum =
                    pendingOutput
                        (rgRegistry rg)
                        (bookedKey "configuration" processingDeadline)
                        & datumTxOutL .~ mkInlineDatum datum
                discovery rg application = withSession (rgWorld rg) $ \session ->
                    discoverPending session application (rgRegistry rg) []

            it "is in neither list, beside an accepted holder of the same request" $ do
                rg <- newRegistered
                refs <- book rg 'p' [bookedKey "one" processingDeadline]
                let configuration = txInOf 'c' 0
                addLive (rgWorld rg) [(configuration, holding rg marker)]
                (found, omitted) <- discovery rg (naming marker)
                map pendingRef found `shouldBe` refs
                omitted `shouldBe` []

            it
                "leaves the folded set, order, left count and transaction as they were"
                $ do
                    rg <- newRegistered
                    _ <-
                        book
                            rg
                            'p'
                            [ (bookedKey "one" processingDeadline){bkTip = 3_000_000}
                            , (bookedKey "two" processingDeadline){bkTip = 2_000_000}
                            , (bookedKey "three" processingDeadline){bkTip = 1_000_000}
                            ]
                    -- Adding an output advances the tip, and the transaction carries it.
                    let fold = do
                            setSlot (rgWorld rg) 10_050
                            withSession (rgWorld rg) $ \session ->
                                expectBuilt
                                    =<< buildFold
                                        session
                                        (rgScript rg)
                                        (naming marker)
                                        (rgRegistry rg)
                                        []
                                        (rgFolder rg)
                                        (Just 2)
                    alone <- fold
                    addLive (rgWorld rg) [(txInOf 'c' 0, holding rg marker)]
                    beside <- fold
                    length (foldSelected alone) `shouldBe` 2
                    foldLeft alone `shouldBe` 1
                    foldSkipped alone `shouldBe` []
                    foldSelected beside `shouldBe` foldSelected alone
                    foldLeft beside `shouldBe` foldLeft alone
                    foldTransaction beside `shouldBe` foldTransaction alone
                    foldSkipped beside `shouldBe` []

            it "is not in the accounting of a refused fold" $ do
                rg <- newRegistered
                addLive (rgWorld rg) [(txInOf 'c' 0, holding rg marker)]
                outcome <- withSession (rgWorld rg) $ \session ->
                    attemptFold
                        session
                        (rgScript rg)
                        (naming marker)
                        (rgRegistry rg)
                        []
                        (rgFolder rg)
                        Nothing
                case outcome of
                    Left failure -> do
                        foldFailureReason failure `shouldBe` NothingToFold
                        foldFailureObserved failure `shouldBe` Just ([], 0)
                    Right built -> expectationFailure (show built)

            it "keeps the skip and the reason of an unrecognised holder beside it" $ do
                rg <- newRegistered
                let unrecognised = txInOf 'u' 0
                addLive
                    (rgWorld rg)
                    [ (txInOf 'c' 0, holding rg marker)
                    , (unrecognised, holding rg (PLC.I 0))
                    ]
                (found, omitted) <- discovery rg (naming marker)
                found `shouldBe` []
                omitted
                    `shouldBe` [SkippedHolder unrecognised NotAcceptedByApplication]

            it
                "keeps a holder at a key address skipped as such, whatever its datum"
                $ do
                    rg <- newRegistered
                    let keyHeld = txInOf 'k' 0
                    addLive
                        (rgWorld rg)
                        [(keyHeld, holding rg marker & addrTxOutL .~ rgBooker rg)]
                    (found, omitted) <- discovery rg (naming marker)
                    found `shouldBe` []
                    omitted `shouldBe` [SkippedHolder keyHeld HeldAtKeyAddress]

            forM_
                [ ("the marker", marker, lookalike)
                , ("the lookalike", lookalike, marker)
                ]
                $ \(named, hidden, shown) ->
                    it
                        ( "hides what the description names, never what resembles an application's configuration: "
                            <> named
                        )
                        $ do
                            rg <- newRegistered
                            let visible = txInOf 's' 0
                            addLive
                                (rgWorld rg)
                                [ (txInOf 'h' 0, holding rg hidden)
                                , (visible, holding rg shown)
                                ]
                            (found, omitted) <- discovery rg (naming hidden)
                            found `shouldBe` []
                            omitted `shouldBe` [SkippedHolder visible NotAcceptedByApplication]

        it "replays earlier folds before discovering a later registration" $ do
            rg <- newRegistered
            (first, _) <- folded rg [bookedKey "earlier" processingDeadline]
            applyTx (rgWorld rg) first
            refs <- book rg 'q' [bookedKey "later" processingDeadline]
            tx <- discoverFold rg (rgFolder rg)
            map fst (foldedRequests tx) `shouldBe` refs
            judge (rgWorld rg) tx >>= (`shouldSatisfy` everyScriptAccepts)

        it
            "does not accept a registration whose held value cannot cover its deposit"
            $ do
                rg <- newRegistered
                let booked = bookedKey "one" processingDeadline
                    ref = txInOf 's' 0
                    output =
                        pendingOutput (rgRegistry rg) booked
                            & coinTxOutL .~ Coin (bkDeposit booked - 1)
                addLive (rgWorld rg) [(ref, output)]
                (found, skipped) <- withSession (rgWorld rg) $ \session -> discoverPending session standInApplication (rgRegistry rg) []
                found `shouldBe` []
                skipped `shouldBe` [SkippedHolder ref NotAcceptedByApplication]
                withSession
                    (rgWorld rg)
                    ( \session ->
                        buildRegistrationFold
                            session
                            (rgScript rg)
                            standInApplication
                            (rgRegistry rg)
                            [ref]
                            (rgFolder rg)
                    )
                    `shouldReturn` Left (NotAPendingRegistration ref)

        it
            "finds the same requests through the booker's and a fresh folder's sessions"
            $ do
                rg <- newRegistered
                refs <- book rg 'p' [bookedKey "one" processingDeadline]
                booker <- discoverFold rg (rgBooker rg)
                folder <- discoverFold rg (rgFolder rg)
                map fst (foldedRequests booker) `shouldBe` refs
                foldedRequests folder `shouldBe` foldedRequests booker

        forM_ ["failed", "truncated", "timed out"] $ \problem ->
            it
                ( "preserves a "
                    <> problem
                    <> " policy read instead of returning nothing pending"
                )
                $ do
                    rg <- newRegistered
                    let failure = BackendReadFailure ("policy holdings " <> Text.pack problem)
                    withSession
                        (rgWorld rg)
                        ( \session ->
                            let unavailable =
                                    session
                                        { outputs = \query -> case query of
                                            HoldingPolicy{} -> pure (Left failure)
                                            _ -> outputs session query
                                        }
                            in  buildRegistrationFold
                                    unavailable
                                    (rgScript rg)
                                    standInApplication
                                    (rgRegistry rg)
                                    []
                                    (rgFolder rg)
                        )
                        `shouldThrow` (== failure)

        it "preserves a failed parameter read after discovery" $ do
            rg <- newRegistered
            _ <- book rg 'p' [bookedKey "one" processingDeadline]
            let failure = BackendReadFailure "protocol parameters after discovery"
            withSession
                (rgWorld rg)
                ( \session ->
                    buildRegistrationFold
                        session{protocolParameters = pure (Left failure)}
                        (rgScript rg)
                        standInApplication
                        (rgRegistry rg)
                        []
                        (rgFolder rg)
                )
                `shouldThrow` (== failure)

    describe
        "the fold of one pending registration, built by a second wallet from the chain"
        $ do
            it "is accepted by the compiled state validator" $ do
                rg <- newRegistered
                (tx, _) <- folded rg [bookedKey "key one" processingDeadline]
                judged <- judge (rgWorld rg) tx
                everyScriptAccepts judged `shouldBe` True
                purposesRun judged `shouldBe` [(Mint, 2), (Spend, 2)]

            it "burns the approval and mints one token of the key, nothing else" $ do
                rg <- newRegistered
                let booked = bookedKey "key one" processingDeadline
                (tx, _) <- folded rg [booked]
                let policy = statePolicy (rgScript rg)
                sort' (mintedOf tx)
                    `shouldBe` sort'
                        [ (policy, activeTokenName (rgRegistry rg) "key one", 1)
                        , (standInPolicy, approvalFor (rgRegistry rg) booked, -1)
                        ]

            it
                "writes the root of the trie with the key into a state output that holds the token and ADA alone"
                $ do
                    rg <- newRegistered
                    (tx, _) <- folded rg [bookedKey "key one" processingDeadline]
                    previous <- liveState rg
                    [state] <- pure (stateOutputsOf rg tx)
                    outputAddress state `shouldBe` stateAddress network (rgScript rg)
                    assetsOf state
                        `shouldBe` [(statePolicy (rgScript rg), snd' (rgRegistry rg), 1)]
                    inlineDatum state
                        `shouldBe` Just (stateDatum (oracleRoot ["key one"]))
                    valueAda state `shouldBe` valueAda previous

            it
                "delivers the token into the committed holding with the deposit and the datum"
                $ do
                    rg <- newRegistered
                    let booked = bookedKey "key one" processingDeadline
                    (tx, _) <- folded rg [booked]
                    let token = activeTokenName (rgRegistry rg) "key one"
                        holdings =
                            [ out
                            | out <- outputsOf tx
                            , tokenQuantity (statePolicy (rgScript rg)) token out == 1
                            ]
                    length holdings `shouldBe` 1
                    [holding] <- pure holdings
                    outputAddress holding `shouldBe` bkHolding booked
                    valueAda holding `shouldBe` bkDeposit booked
                    inlineDatum holding `shouldBe` Just (bkDatum booked)

            it
                "leaves the folder what the pending registration held above the deposit, less the fee"
                $ do
                    rg <- newRegistered
                    let booked = bookedKey "key one" processingDeadline
                    (tx, _) <- folded rg [booked]
                    paidTo (rgFolder rg) tx
                        `shouldBe` valueAda' 50 + bkTip booked - feeOf tx

            it "ends before the processing deadline" $ do
                rg <- newRegistered
                (tx, _) <- folded rg [bookedKey "key one" processingDeadline]
                case validityOf tx of
                    (_, Just (SlotNo upper)) ->
                        toInteger upper * 1_000 `shouldSatisfy` (<= processingDeadline)
                    other -> expectationFailure ("no upper bound: " <> show other)

            it
                "pays its way: value is conserved, outputs hold their minimum, collateral is declared"
                $ do
                    rg <- newRegistered
                    (tx, _) <- folded rg [bookedKey "key one" processingDeadline]
                    soundnessProblems (rgWorld rg) tx `shouldReturn` []

    describe "a batch of several registrations" $ do
        it "is folded in one transaction that the validator accepts" $ do
            rg <- newRegistered
            let keys = ["key one", "key two", "key three"]
            (tx, _) <- folded rg [bookedKey k processingDeadline | k <- keys]
            judged <- judge (rgWorld rg) tx
            everyScriptAccepts judged `shouldBe` True
            purposesRun judged `shouldBe` [(Mint, 2), (Spend, 4)]
            [state] <- pure (stateOutputsOf rg tx)
            inlineDatum state `shouldBe` Just (stateDatum (oracleRoot keys))

        it
            "mints one token for each key and delivers each into its own holding"
            $ do
                rg <- newRegistered
                let keys = ["key one", "key two", "key three"]
                (tx, _) <- folded rg [bookedKey k processingDeadline | k <- keys]
                forM_ keys $ \key ->
                    length
                        [ ()
                        | out <- outputsOf tx
                        , tokenQuantity
                            (statePolicy (rgScript rg))
                            (activeTokenName (rgRegistry rg) key)
                            out
                            == 1
                        ]
                        `shouldBe` 1

    describe "a later fold" $ do
        it "sees the keys of the folds before it and is accepted" $ do
            rg <- newRegistered
            (first, _) <- folded rg [bookedKey "key one" processingDeadline]
            applyTx (rgWorld rg) first
            second <- foldedAgain rg 'q' [bookedKey "key two" processingDeadline]
            judged <- judge (rgWorld rg) second
            everyScriptAccepts judged `shouldBe` True
            [state] <- pure (stateOutputsOf rg second)
            inlineDatum state
                `shouldBe` Just (stateDatum (oracleRoot ["key one", "key two"]))

        it "declines a key that is already registered" $ do
            rg <- newRegistered
            (first, _) <- folded rg [bookedKey "key one" processingDeadline]
            applyTx (rgWorld rg) first
            refs <- book rg 'q' [bookedKey "key one" processingDeadline]
            outcome <- foldNow rg refs
            outcome `shouldBe` Left (KeyAlreadyRegistered "key one")

    describe
        "the validator refuses the fold once one fact of it is made wrong"
        $ do
            it "the approval is not burned" $ do
                rg <- newRegistered
                (tx, _) <- folded rg [bookedKey "key one" processingDeadline]
                refused rg (withoutMintOf standInPolicy tx)

            it "the token is delivered to another address" $ do
                rg <- newRegistered
                (tx, _) <- folded rg [bookedKey "key one" processingDeadline]
                refused
                    rg
                    ( mapHolding
                        rg
                        "key one"
                        (\out -> out & addrTxOutL .~ keyAddress 0x66)
                        tx
                    )

            it "the holding keeps less than the deposit" $ do
                rg <- newRegistered
                let booked = bookedKey "key one" processingDeadline
                (tx, _) <- folded rg [booked]
                refused
                    rg
                    ( mapHolding
                        rg
                        "key one"
                        (\out -> out & coinTxOutL .~ Coin (bkDeposit booked - 1))
                        tx
                    )

            it "another token is added to the state output" $ do
                rg <- newRegistered
                (tx, _) <- folded rg [bookedKey "key one" processingDeadline]
                let extra =
                        MaryValue
                            (Coin 0)
                            ( MultiAsset
                                (Map.singleton standInPolicy (Map.singleton (snd' (rgRegistry rg)) 1))
                            )
                refused
                    rg
                    ( mapOutput
                        (stateIndex rg tx)
                        (\out -> out & valueTxOutL .~ ((out ^. valueTxOutL) <> extra))
                        tx
                    )

            it "the root is not the root of the trie with the key" $ do
                rg <- newRegistered
                (tx, _) <- folded rg [bookedKey "key one" processingDeadline]
                refused
                    rg
                    ( mapOutput
                        (stateIndex rg tx)
                        (withDatum (stateDatum (oracleRoot ["other"])))
                        tx
                    )

            it "the proof is not the proof of the key's absence" $ do
                rg <- newRegistered
                (first, _) <- folded rg [bookedKey "key one" processingDeadline]
                applyTx (rgWorld rg) first
                second <- foldedAgain rg 'q' [bookedKey "key two" processingDeadline]
                judgedSecond <- judge (rgWorld rg) second
                everyScriptAccepts judgedSecond `shouldBe` True
                refused rg (mapRedeemers dropProofs second)

    describe "the builder declines before it builds" $ do
        it "when there is nothing to fold" $ do
            rg <- newRegistered
            outcome <- foldNow rg []
            outcome `shouldBe` Left NothingToFold

        it "when the same pending registration is named twice" $ do
            rg <- newRegistered
            refs <- book rg 'q' [bookedKey "key one" processingDeadline]
            outcome <- foldNow rg (refs <> refs)
            outcome `shouldBe` Left (DuplicateRequest (firstOf refs))

        it "when two pending registrations ask for the same key" $ do
            rg <- newRegistered
            refs <-
                book
                    rg
                    'q'
                    [ bookedKey "key one" processingDeadline
                    , (bookedKey "key one" processingDeadline){bkDeposit = 6_000_000}
                    ]
            outcome <- foldNow rg refs
            outcome `shouldBe` Left (DuplicateKey "key one")

        it "when a pending registration is not on the chain" $ do
            rg <- newRegistered
            outcome <- foldNow rg [txInOf '8' 8]
            outcome `shouldBe` Left (PendingNotFound (txInOf '8' 8))

        it "when an output is no pending registration of the application" $ do
            rg <- newRegistered
            let wallet = txInOf '2' 0
            outcome <- foldNow rg [wallet]
            outcome `shouldBe` Left (NotAPendingRegistration wallet)

        it "when the pending registration holds no approval" $ do
            rg <- newRegistered
            let booked = bookedKey "key one" processingDeadline
                bare =
                    pendingOutput (rgRegistry rg) booked
                        & valueTxOutL .~ MaryValue (Coin 6_000_000) mempty
                ref = txInOf 'r' 0
            addLive (rgWorld rg) [(ref, bare)]
            outcome <- foldNow rg [ref]
            outcome `shouldBe` Left (NotAPendingRegistration ref)

        it "when the pending registration asks for another registry" $ do
            rg <- newRegistered
            let elsewhere =
                    RegistryIdentity
                        (policyOf (rgRegistry rg))
                        (nameOf (registryOf (rgScript rg) (txInOf '4' 4)))
                booked = bookedKey "key one" processingDeadline
                ref = txInOf 'r' 1
            addLive (rgWorld rg) [(ref, pendingOutput elsewhere booked)]
            outcome <- foldNow rg [ref]
            outcome `shouldBe` Left (PendingOfAnotherRegistry ref)

        it "when the deposit is below the minimum ADA of its holding" $ do
            rg <- newRegistered
            refs <-
                book
                    rg
                    'q'
                    [(bookedKey "key one" processingDeadline){bkDeposit = 100_000}]
            outcome <- foldNow rg refs
            outcome `shouldSatisfy` \case
                Left (DepositBelowHolding ref (Coin 100_000) _) -> ref == firstOf refs
                _ -> False

        it "when the processing deadline has passed" $ do
            rg <- newRegistered
            refs <- book rg 'q' [bookedKey "key one" processingDeadline]
            setSlot (rgWorld rg) 10_700
            outcome <- foldNow rg refs
            outcome `shouldBe` Left ProcessingWindowClosed

        it "when no output holds the state token of the registry" $ do
            rg <- newRegistered
            refs <- book rg 'q' [bookedKey "key one" processingDeadline]
            let unknown = registryOf (rgScript rg) (txInOf '4' 4)
            outcome <- foldFor rg unknown refs
            outcome `shouldBe` Left (NoRegistryState unknown)

        it "when the folder holds no ADA" $ do
            rg <- newRegistered
            refs <- book rg 'q' [bookedKey "key one" processingDeadline]
            outcome <- foldAs rg (keyAddress 0x99) refs
            outcome `shouldBe` Left PayerHasNoFunding

        it "when the folder is a script" $ do
            rg <- newRegistered
            refs <- book rg 'q' [bookedKey "key one" processingDeadline]
            outcome <- foldAs rg standInAddress refs
            outcome `shouldBe` Left PayerIsNotAKey
  where
    snd' (RegistryIdentity _ name) = name
    nameOf = snd'
    policyOf (RegistryIdentity policy _) = policy
    sort' = Map.toList . Map.fromList . map (\(p, n, q) -> ((p, n), q))
    valueAda' n = n * 1_000_000

-- | One public pool with every request-local failure and its foldable control.
unfoldablePool
    :: IO
        (Registered, Application, [(String, [TxIn], Text.Text, TxIn)], [TxIn])
unfoldablePool = do
    rg <- newRegistered
    (previous, _) <-
        folded
            rg
            [ bookedKey "registered" processingDeadline
            , bookedKey "termination" processingDeadline
            ]
    judge (rgWorld rg) previous >>= (`shouldSatisfy` everyScriptAccepts)
    applyTx (rgWorld rg) previous
    -- Move the genuine termination tag from its holding to the public pending fixture.
    advanceChain (worldChain (rgWorld rg)) $ \facts ->
        facts
            { csUTxO =
                Map.filter
                    ( \output ->
                        tokenQuantity
                            (statePolicy (rgScript rg))
                            (activeTokenName (rgRegistry rg) "termination")
                            output
                            == 0
                    )
                    (csUTxO facts)
            }
    [registered, fresh, deposit, funded, expired, current, earlier, later] <-
        book
            rg
            'u'
            [ (bookedKey "registered" processingDeadline){bkTip = 9_000_000}
            , bookedKey "fresh" processingDeadline
            , (bookedKey "deposit" processingDeadline)
                { bkDeposit = 100_000
                , bkTip = 8_000_000
                }
            , bookedKey "funded" processingDeadline
            , (bookedKey "expired" 1){bkTip = 7_000_000}
            , bookedKey "current" processingDeadline
            , (bookedKey "duplicate" processingDeadline){bkTip = 5_000_000}
            , (bookedKey "duplicate" processingDeadline){bkTip = 4_000_000}
            ]
    let missing = txInOf 't' 0
        active = txInOf 't' 1
        registry = rgRegistry rg
        termination key =
            pendingOutput registry (bookedKey key processingDeadline)
                & valueTxOutL
                    .~ MaryValue
                        (Coin 6_000_000)
                        ( MultiAsset
                            ( Map.fromList
                                [
                                    ( standInPolicy
                                    , Map.singleton (approvalName (terminationPreimage key registry)) 1
                                    )
                                ,
                                    ( statePolicy (rgScript rg)
                                    , Map.singleton (activeTokenName registry key) 1
                                    )
                                ]
                            )
                        )
                & datumTxOutL .~ mkInlineDatum (PLC.Constr 1 [PLC.B key])
        application =
            standInApplication
                { appDecode = \identity keys output -> case inlineDatum output of
                    Just (PLC.Constr 1 [PLC.B key]) -> Just (TerminationRequest identity key)
                    _ -> appDecode standInApplication identity keys output
                }
    addLive
        (rgWorld rg)
        [ (missing, termination "inactive")
        , (active, termination "termination")
        ]
    pure
        ( rg
        , application
        ,
            [ ("registered", [fresh, registered], "KeyAlreadyRegistered", fresh)
            , ("termination", [active, missing], "KeyNotActive", active)
            , ("duplicate", [earlier, later], "DuplicateKey", earlier)
            , ("deposit", [funded, deposit], "DepositBelowHolding", funded)
            , ("deadline", [current, expired], "ProcessingWindowClosed", current)
            ]
        , [fresh, active, earlier, funded, current]
        )

hasApprovals :: TxOut ConwayEra -> Bool
hasApprovals output = case output ^. valueTxOutL of
    MaryValue _ (MultiAsset policies) -> Map.member standInPolicy policies

-- | Book these registrations and build the fold of them as the second wallet.
folded :: Registered -> [Booked] -> IO (ConwayTx, [TxIn])
folded rg bookings = do
    refs <- book rg 'p' bookings
    tx <- foldNow rg refs >>= expectBuilt
    pure (tx, refs)

-- | The fold of a batch booked after an earlier fold was applied.
foldedAgain :: Registered -> Char -> [Booked] -> IO ConwayTx
foldedAgain rg tag bookings = do
    refs <- book rg tag bookings
    foldNow rg refs >>= expectBuilt

-- | The fold builder's answer for these pending registrations, built by the folder.
foldNow :: Registered -> [TxIn] -> IO (Either Refusal ConwayTx)
foldNow rg = foldAs rg (rgFolder rg)

foldAs :: Registered -> Addr -> [TxIn] -> IO (Either Refusal ConwayTx)
foldAs rg folder refs =
    withSession (rgWorld rg) $ \session ->
        buildRegistrationFold
            session
            (rgScript rg)
            standInApplication
            (rgRegistry rg)
            refs
            folder

foldFor
    :: Registered
    -> RegistryIdentity
    -> [TxIn]
    -> IO (Either Refusal ConwayTx)
foldFor rg registry refs =
    withSession (rgWorld rg) $ \session ->
        buildRegistrationFold
            session
            (rgScript rg)
            standInApplication
            registry
            refs
            (rgFolder rg)

-- | The validator refuses the transaction: some script purpose answers with a failure.
refused :: Registered -> ConwayTx -> Expectation
refused rg tx = do
    judged <- judge (rgWorld rg) tx
    refusedBy judged `shouldBe` True

-- | The live state output of the registry.
liveState :: Registered -> IO (TxOut ConwayEra)
liveState rg = outputAt (rgWorld rg) (rgState rg) >>= maybe (fail "no state") pure

-- | The outputs of a transaction that hold the state token.
stateOutputsOf :: Registered -> ConwayTx -> [TxOut ConwayEra]
stateOutputsOf rg tx =
    [ out
    | out <- outputsOf tx
    , tokenQuantity
        (statePolicy (rgScript rg))
        (nameOfRegistry (rgRegistry rg))
        out
        == 1
    ]

nameOfRegistry :: RegistryIdentity -> AssetName
nameOfRegistry (RegistryIdentity _ name) = name

-- | The index of the output that holds the state token.
stateIndex :: Registered -> ConwayTx -> Int
stateIndex rg =
    holderIndex
        (statePolicy (rgScript rg))
        (nameOfRegistry (rgRegistry rg))

-- | Change the holding of a key.
mapHolding
    :: Registered
    -> ByteString
    -> (TxOut ConwayEra -> TxOut ConwayEra)
    -> ConwayTx
    -> ConwayTx
mapHolding rg key change tx =
    mapOutput
        ( holderIndex
            (statePolicy (rgScript rg))
            (activeTokenName (rgRegistry rg) key)
            tx
        )
        change
        tx

-- | The state redeemer with the proofs of its changes emptied.
dropProofs :: ConwayPlutusPurpose f ConwayEra -> PLC.Data -> PLC.Data
dropProofs _ datum = case decodeFoldRedeemer datum of
    Just (seed, changes) -> foldRedeemer seed (map empty changes)
    Nothing -> datum
  where
    empty = \case
        Register request key holding deposit _ -> Register request key holding deposit []
        Terminate request key _ -> Terminate request key []

-- | The first of the pending registrations just booked.
firstOf :: [TxIn] -> TxIn
firstOf = \case
    ref : _ -> ref
    [] -> error "nothing was booked"

{- | Measure two actual builds, then set the protocol limit strictly between
them. The shorter named batch is independently rebuilt and evaluated as the
accepted boundary control before either selection assertion runs.
-}
prepareByteBoundary :: IO (Registered, [TxIn], Integer)
prepareByteBoundary = do
    let key = signingKey 1
    rg <- registeredForSigning key
    refs@[high, middle, _] <-
        book
            rg
            'p'
            [ (bookedKey "high" processingDeadline){bkTip = 3_000_000}
            , (bookedKey "middle" processingDeadline){bkTip = 2_000_000}
            , (bookedKey "low" processingDeadline){bkTip = 1_000_000}
            ]
    two <- expectBuilt =<< foldNow rg [high, middle]
    three <- expectBuilt =<< foldNow rg refs
    let bytes tx = serializedBytes (signedBy [key] tx)
        limit = (bytes two + bytes three) `div` 2
    bytes two `shouldSatisfy` (< bytes three)
    advanceChain (worldChain (rgWorld rg)) $ \facts ->
        facts
            { csPParams = csPParams facts & ppMaxTxSizeL .~ fromIntegral limit
            }
    control <- expectBuilt =<< foldNow rg [high, middle]
    judge (rgWorld rg) control >>= (`shouldSatisfy` everyScriptAccepts)
    pure (rg, refs, limit)

{- | Actual signatures exercise one key, distinct additional signers and the
CBOR witness-array length boundary. The payer's key appears in both its
funding credential and the explicit signer set and must be counted once.
-}
prepareSubmissionBoundary
    :: Int
    -> IO
        ( Registered
        , Application
        , [SignKeyDSIGN Ed25519DSIGN]
        , [TxIn]
        , Integer
        )
prepareSubmissionBoundary count = do
    let keys = map signingKey [1 .. count]
    payer <- case keys of
        key : _ -> pure key
        _ -> fail "a submitted fold needs a payer"
    rg <- registeredForSigning payer
    let application =
            standInApplication
                { appFold = \requests -> do
                    appFold standInApplication requests
                    mapM_ (Tx.requireSignature . signingHash) keys
                }
    refs@[high, _] <-
        book
            rg
            'p'
            [ (bookedKey "high" processingDeadline){bkTip = 3_000_000}
            , (bookedKey "low" processingDeadline){bkTip = 1_000_000}
            ]
    one <- expectBuilt =<< foldWithApplication rg application [high]
    two <- expectBuilt =<< foldWithApplication rg application refs
    let signedOne = signedBy keys one
        signedTwo = signedBy keys two
        lower = max (serializedBytes two) (serializedBytes signedOne)
        limit = (lower + serializedBytes signedTwo) `div` 2
    Set.size (signedTwo ^. witsTxL . addrTxWitsL) `shouldBe` count
    serializedBytes two `shouldSatisfy` (< limit)
    limit `shouldSatisfy` (< serializedBytes signedTwo)
    serializedBytes signedOne `shouldSatisfy` (<= limit)
    judge (rgWorld rg) signedTwo >>= (`shouldSatisfy` everyScriptAccepts)
    -- At the exact submitted size the whole named batch must still fit:
    -- reserving a constant or double-counting the payer is not acceptable.
    advanceChain (worldChain (rgWorld rg)) $ \facts ->
        facts
            { csPParams =
                csPParams facts
                    & ppMaxTxSizeL .~ fromInteger (serializedBytes signedTwo)
            }
    exact <- expectBuilt =<< foldWithApplication rg application refs
    serializedBytes (signedBy keys exact)
        `shouldBe` serializedBytes signedTwo
    advanceChain (worldChain (rgWorld rg)) $ \facts ->
        facts{csPParams = csPParams facts & ppMaxTxSizeL .~ fromInteger limit}
    control <- expectBuilt =<< foldWithApplication rg application [high]
    serializedBytes (signedBy keys control) `shouldSatisfy` (<= limit)
    pure (rg, application, keys, refs, limit)

signingKey :: Int -> SignKeyDSIGN Ed25519DSIGN
signingKey n = genKeyDSIGN (mkSeedFromBytes (BS.replicate 32 (fromIntegral n)))

registeredForSigning :: SignKeyDSIGN Ed25519DSIGN -> IO Registered
registeredForSigning key = do
    original <- newRegistered
    let KeyHash payerHash = signingHash key
        payerAddress = Addr network (KeyHashObj (KeyHash payerHash)) StakeRefNull
    advanceChain (worldChain (rgWorld original)) $ \facts ->
        facts
            { csUTxO =
                Map.map
                    ( \output ->
                        if output ^. addrTxOutL == rgFolder original
                            then output & addrTxOutL .~ payerAddress
                            else output
                    )
                    (csUTxO facts)
            }
    pure original{rgFolder = payerAddress}

signingHash :: SignKeyDSIGN Ed25519DSIGN -> KeyHash Guard
signingHash = hashKey . VKey . deriveVerKeyDSIGN

signedBy :: [SignKeyDSIGN Ed25519DSIGN] -> ConwayTx -> ConwayTx
signedBy keys tx = foldl' (\current key -> signedTx (signTx key current)) tx keys

serializedBytes :: ConwayTx -> Integer
serializedBytes tx = toInteger (LBS.length (serialize (eraProtVerHigh @ConwayEra) tx))

foldWithApplication
    :: Registered -> Application -> [TxIn] -> IO (Either Refusal ConwayTx)
foldWithApplication rg application refs = withSession (rgWorld rg) $ \session ->
    buildRegistrationFold
        session
        (rgScript rg)
        application
        (rgRegistry rg)
        refs
        (rgFolder rg)

fitting :: Registered -> Maybe Word32 -> IO FoldResult
fitting rg cap = withSession (rgWorld rg) $ \session ->
    expectBuilt
        =<< buildFold
            session
            (rgScript rg)
            standInApplication
            (rgRegistry rg)
            []
            (rgFolder rg)
            cap

-- | Change only the served order, preserving the exact outputs and evidence.
discoverWithOrder :: Registered -> Bool -> IO ConwayTx
discoverWithOrder rg backwards = withSession (rgWorld rg) $ \session -> do
    let reordered =
            session
                { outputs = \query -> do
                    result <- outputs session query
                    pure $ case query of
                        HoldingPolicy{}
                            | backwards ->
                                fmap (\answer -> answer{value = reverse (value answer)}) result
                        _ -> result
                }
    expectBuilt
        =<< buildRegistrationFold
            reordered
            (rgScript rg)
            standInApplication
            (rgRegistry rg)
            []
            (rgFolder rg)

discoverFold :: Registered -> Addr -> IO ConwayTx
discoverFold rg payer =
    withSession (rgWorld rg) $ \session ->
        expectBuilt
            =<< buildRegistrationFold
                session
                (rgScript rg)
                standInApplication
                (rgRegistry rg)
                []
                payer
