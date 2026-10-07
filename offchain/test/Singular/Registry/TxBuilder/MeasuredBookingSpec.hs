{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.TxBuilder.MeasuredBookingSpec
Description : #300 — a booking's fee, units and collateral are measured, not declared
License     : Apache-2.0

A booking is the one script-running transaction the ordinary commands
built with a declared fee (2 ADA) and declared units (14M memory, 1G
steps) that nothing measured, putting the wallet's whole funding output up
as collateral with no return. Against a public network a reviewer needs the
opposite: the units the node's evaluator measured, the fee the ledger's own
estimator charges for that body with the reference scripts it reads, and a
collateral the transaction states — 'totalCollateral' at the protocol's
percentage of that fee and a return carrying the rest of the output back.

Every expected budget here is obtained from the imported ledger on the final
body, using the raw outputs and synthetic cost model supplied to the builder, from the wallet the generator drew, and from the
ledger's own functions over the parameters the public preprod node reports
(fee 155381 + 44 per byte, 150% collateral, 15 per reference-script byte,
prices 0.0577 and 0.0000721). Nothing is typed from a builder's output.

The fixed booking ('bookEdgeWith') stays for the development journeys. It
is the control: the same judgement must find it unmeasured. Each mutation
of a measured booking must be found too, and must first have changed it.
-}
module Singular.Registry.TxBuilder.MeasuredBookingSpec (spec) where

import Control.Exception (ErrorCall, evaluate, try)
import Data.ByteString (ByteString)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (maximumBy)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust, fromMaybe)
import Data.Ord (comparing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((&), (.~), (^.))
import Test.Hspec
import Test.QuickCheck
    ( Gen
    , checkCoverage
    , chooseInteger
    , conjoin
    , counterexample
    , cover
    , forAll
    , ioProperty
    , listOf1
    , oneof
    , property
    , suchThat
    , (===)
    )

import Cardano.Ledger.Api.PParams
    ( ppCollateralPercentageL
    , ppTxFeePerByteL
    )
import Cardano.Ledger.Api.Tx (bodyTxL, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( collateralReturnTxBodyL
    , feeTxBodyL
    , totalCollateralTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , mkBasicTxOut
    , referenceScriptTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes
    ( StrictMaybe (..)
    )
import Cardano.Ledger.Coin
    ( Coin (..)
    , CoinPerByte (..)
    , CompactForm (CompactCoin)
    )
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    )
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Balance (refScriptsSize)
import Cardano.Tx.Ledger (ConwayTx)

import Cardano.Ledger.Alonzo.Plutus.Evaluate (evalTxExUnits)
import Cardano.Ledger.Alonzo.Scripts (AsIx)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose)
import Cardano.Ledger.Core (Script)
import Cardano.Ledger.State (UTxO (..))
import Singular.PhaseLogFixture
    ( logObjects
    , phaseLines
    , textField
    , withLogFile
    )
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (ConwayEra, PParams)
import Singular.Registry.LedgerProvider
    ( LedgerProvider (..)
    , Network
    , OutputQuery (..)
    , Session (..)
    )
import Singular.Registry.NetworkTime
    ( networkEpochInfo
    , networkSystemStart
    )
import Singular.Registry.SessionIO (parameters, withLatest)
import Singular.Registry.StubSession
import Singular.Registry.SyntheticLedger (withCostCoefficients)
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.TraceRender (readPhaseLog)
import Singular.Registry.TxBuilder.BookingFixture
import Singular.Registry.TxBuilder.CollateralJudgement
    ( Spend (..)
    , judgeCollateral
    )
import Singular.Registry.TxBuilder.Edges
    ( BookingApproval (..)
    , bookEdgeMeasured
    , bookEdgeWith
    , bookingApproval
    , edgeDestinationOf
    )
import Singular.Registry.TxBuilder.Internal
    ( addrKeyHashBytes
    , approvalDestination
    )
import Singular.Registry.Types (Edge)

-- ---------------------------------------------------------
-- What the wallet holds and what the evaluator measures
-- ---------------------------------------------------------

-- | A wallet output: an output reference index and its lovelace.
data Held = Held TxIn Integer

txIns :: [TxIn]
txIns =
    [ either
        (error . ("MeasuredBookingSpec fixture: " <>))
        id
        (parseOutRef (T.pack (replicate 64 c <> "#" <> show i)))
    | (c, i) <- zip "abcdef0123456789" (cycle [0 :: Int, 1])
    ]

-- | The output carrying the application script, read by reference.
refIn :: TxIn
refIn =
    either
        (error . ("MeasuredBookingSpec fixture: " <>))
        id
        (parseOutRef (T.pack (replicate 64 '9' <> "#7")))

refOut :: TxOut ConwayEra
refOut =
    mkBasicTxOut payer (MaryValue (Coin 50_000_000) mempty)
        & referenceScriptTxOutL .~ SJust publishedScript

{- | A published script of realistic size: the reference-script tier charges
per byte, so a fee that ignores the bytes read is off by far more than the
witness allowance below.
-}
publishedScript :: Script ConwayEra
publishedScript = applicationScript

-- | The first of a list the fixture guarantees is not empty.
first :: String -> [a] -> a
first _ (x : _) = x
first what [] = error ("MeasuredBookingSpec: no " <> what)

-- | The booking request and explicit synthetic ledger cost coefficients.
data Scenario = Scenario
    { scWallet :: [Held]
    -- ^ ada-only outputs of the payer (n > 1 in general)
    , scUnits :: ExUnits
    -- ^ synthetic ledger startup memory and CPU coefficients
    , scSlope :: Integer
    {- ^ synthetic SHA256 CPU slope increment; the script hashes fee/100 bytes
    after reading its actual V3 transaction context
    -}
    , scDeposit :: Integer
    , scByReference :: Bool
    -- ^ the application script is read from 'refOut'
    , scPinned :: Maybe Int
    -- ^ index of the wallet output the caller chose, if any
    }

instance Show Scenario where
    show sc =
        "Scenario wallet="
            <> show [l | Held _ l <- scWallet sc]
            <> " units="
            <> show (scUnits sc)
            <> " deposit="
            <> show (scDeposit sc)
            <> " byReference="
            <> show (scByReference sc)
            <> " pinned="
            <> show (scPinned sc)

{- | One funding output near the smallest that can carry the booking: below
it the builder must refuse, above it the booking must be valid, and the
boundary lies inside the range.
-}
genTight :: Gen Scenario
genTight = do
    funding <- chooseInteger (3_000_000, 7_000_000)
    pure
        Scenario
            { scWallet = [Held (first "txIn" txIns) funding]
            , scUnits = ExUnits 500_000 200_000_000
            , scSlope = 10
            , scDeposit = 2_000_000
            , scByReference = False
            , scPinned = Nothing
            }

genScenario :: Gen Scenario
genScenario = do
    lovelaces <- listOf1 (chooseInteger (9_000_000, 12_000_000_000))
    extra <- chooseInteger (2_000_000, 12_000_000_000)
    let wallet = zipWith Held txIns (extra : lovelaces)
    mem <- chooseInteger (1, 14_000_000)
    steps <- chooseInteger (1, 1_000_000_000)
    slope <- oneof [pure 0, chooseInteger (1, 50)]
    deposit <-
        oneof [pure 2_000_000, chooseInteger (1_500_000, 6_000_000)]
    byRef <- oneof [pure True, pure False]
    pin <-
        oneof
            [ pure Nothing
            , Just <$> chooseInteger (0, fromIntegral (length wallet) - 1)
            ]
    pure
        Scenario
            { scWallet = wallet
            , scUnits = ExUnits (fromIntegral mem) (fromIntegral steps)
            , scSlope = slope
            , scDeposit = deposit
            , scByReference = byRef
            , scPinned = fromIntegral <$> pin
            }

walletOuts :: Scenario -> [(TxIn, TxOut ConwayEra)]
walletOuts sc =
    [ (i, mkBasicTxOut payer (MaryValue (Coin l) mempty))
    | Held i l <- scWallet sc
    ]
        <> [(refIn, refOut) | scByReference sc]

{- | Independent expected budgets: invoke the imported ledger on the
actual final body and the scenario's raw wallet/reference outputs, outside
both the common service and the builder's convergence loop.
-}
evaluatedOn
    :: Scenario
    -> ConwayTx
    -> Map.Map (ConwayPlutusPurpose AsIx ConwayEra) ExUnits
evaluatedOn sc tx =
    let actual =
            evalTxExUnits
                (parametersFor sc)
                tx
                (UTxO (Map.fromList (walletOuts sc)))
                (networkEpochInfo syntheticTime)
                (networkSystemStart syntheticTime)
    in  Map.map
            (either (error . ("independent booking evaluation: " <>) . show) id)
            actual

-- | Raw facts from the one view; no provider-selected evaluator.
parametersFor :: Scenario -> PParams ConwayEra
parametersFor sc = withCostCoefficients (scUnits sc) (scSlope sc) preprodParams

viewFor :: Scenario -> Session NoWitness IO
viewFor sc =
    withAddressOutputs (\_ -> pure (walletOuts sc))
        $ withParameters
            (withCostCoefficients (scUnits sc) (scSlope sc) preprodParams)
        $ withTime (pure syntheticTime)
        $ withResolvedOutputs
            ( \wanted ->
                pure
                    [ (reference, output)
                    | (reference, output) <- walletOuts sc
                    , reference `Set.member` wanted
                    ]
            )
            stubSession

-- | The provider every acquisition of which is that view.
providerFor :: Scenario -> (Network, LedgerProvider NoWitness IO)
providerFor = servingSession . viewFor

edge0 :: Edge
edge0 = 1

key0 :: ByteString
key0 = first "key" keys

approvalFor :: Scenario -> BookingApproval
approvalFor sc =
    let owner = addrKeyHashBytes payer
        dest = approvalDestination (edgeDestinationOf cfg codes payer edge0)
        base = fromJust (bookingApproval codes edge0 key0 owner dest)
    in  if scByReference sc
            then base{baScriptReference = Just refIn}
            else base

fundingOf :: Scenario -> Maybe TxIn
fundingOf sc = case scPinned sc of
    Nothing -> Nothing
    Just n -> case drop n (scWallet sc) of
        Held i _ : _ -> Just i
        [] -> Nothing

-- | Book through the measured builder and keep the unsigned transaction.
measuredBooking :: Scenario -> IO ConwayTx
measuredBooking sc =
    bookEdgeMeasured
        cfg
        (viewFor sc)
        payer
        tokenId
        key0
        edge0
        (edgeDestinationOf cfg codes payer edge0)
        (scDeposit sc)
        (approvalFor sc)
        [(refIn, refOut) | scByReference sc]
        (fundingOf sc)

-- | Book through the fixed builder, the control.
fixedBooking :: Scenario -> IO ConwayTx
fixedBooking sc =
    bookEdgeWith
        cfg
        (providerFor sc)
        pure
        payer
        tokenId
        key0
        edge0
        (edgeDestinationOf cfg codes payer edge0)
        (scDeposit sc)
        (Just (approvalFor sc))

-- ---------------------------------------------------------
-- The judgement
-- ---------------------------------------------------------

{- | The wallet output the design funds from when the caller chose none:
the largest ada-only output that is not a reference publication.
-}
largestAdaOnly :: Scenario -> TxIn
largestAdaOnly sc =
    case [ (i, l)
         | Held i l <- scWallet sc
         ] of
        [] -> error "the scenario holds no output"
        held -> fst (maximumBy (comparing snd) held)

expectedFunding :: Scenario -> TxIn
expectedFunding sc = fromMaybe (largestAdaOnly sc) (fundingOf sc)

{- | Everything a measured booking owes, as named findings. Empty means it
holds. The expected values are derived here from the scenario, the
evaluator's units and the ledger's own estimator.
-}
findings :: Scenario -> ConwayTx -> [Text]
findings sc tx =
    [ "the declared units are "
        <> T.pack (show declared)
        <> " but the evaluator measures "
        <> T.pack (show (evaluatedOn sc tx))
        <> " on the body as submitted"
    | declared /= evaluatedOn sc tx
    ]
        <> judgeCollateral
            Spend
                { spInputs = [(funding, fundingValue)]
                , spFunding = funding
                , spRefBytes = refBytes
                }
            tx
  where
    declared =
        let Redeemers m = tx ^. witsTxL . rdmrsTxWitsL
        in  Map.map snd m
    funding = expectedFunding sc
    fundingValue =
        first "funding" [l | Held i l <- scWallet sc, i == funding]
    refBytes
        | scByReference sc =
            refScriptsSize (Set.singleton refIn) [(refIn, refOut)]
        | otherwise = 0

-- ---------------------------------------------------------
-- Mutations: each must change the booking, and must then be found
-- ---------------------------------------------------------

mutations
    :: [(String, Gen Scenario, Scenario -> ConwayTx -> ConwayTx)]
mutations =
    [
        ( "the collateral return dropped"
        , genScenario
        , \_ tx -> tx & bodyTxL . collateralReturnTxBodyL .~ SNothing
        )
    ,
        ( "total collateral one lovelace short"
        , genScenario
        , \_ tx -> case tx ^. bodyTxL . totalCollateralTxBodyL of
            SJust (Coin c) -> tx & bodyTxL . totalCollateralTxBodyL .~ SJust (Coin (c - 1))
            SNothing -> tx
        )
    ,
        ( "the fee one lovelace over"
        , genScenario
        , \_ tx ->
            let Coin f = tx ^. bodyTxL . feeTxBodyL
            in  tx & bodyTxL . feeTxBodyL .~ Coin (f + 1)
        )
    ,
        ( "the fee short by the reference-script tier of the published script"
        , genScenario
        , \_ tx ->
            let Coin f = tx ^. bodyTxL . feeTxBodyL
            in  tx & bodyTxL . feeTxBodyL .~ Coin (f - 135_000)
        )
    ,
        ( "the declared units replaced by the generous ones"
        , genScenario
        , \_ tx ->
            let Redeemers m = tx ^. witsTxL . rdmrsTxWitsL
            in  tx
                    & witsTxL . rdmrsTxWitsL
                        .~ Redeemers
                            (Map.map (\(d, _) -> (d, ExUnits 14_000_000 1_000_000_000)) m)
        )
    ,
        ( "the units measured before the fee was known, not on the body as submitted"
        , genScenario `suchThat` ((> 0) . scSlope)
        , \sc tx ->
            let Redeemers m = tx ^. witsTxL . rdmrsTxWitsL
            in  tx
                    & witsTxL . rdmrsTxWitsL
                        .~ Redeemers
                            ( Map.mapWithKey
                                ( \purpose (d, _) ->
                                    ( d
                                    , Map.findWithDefault
                                        (ExUnits 0 0)
                                        purpose
                                        (evaluatedOn sc (tx & bodyTxL . feeTxBodyL .~ Coin 0))
                                    )
                                )
                                m
                            )
        )
    ]

-- ---------------------------------------------------------
-- The rows
-- ---------------------------------------------------------

spec :: Spec
spec =
    describe "a booking's fee, units and collateral are measured (#300)" $ do
        it
            "logs the build of a measured booking and each evaluation it \
            \made, as the preview of an insert prepares one (#363)"
            $ withLogFile
            $ \path -> do
                let sc =
                        Scenario
                            { scWallet = zipWith Held txIns [9_000_000_000, 5_000_000_000]
                            , scUnits = ExUnits 500_000 200_000_000
                            , scSlope = 10
                            , scDeposit = 2_000_000
                            , scByReference = False
                            , scPinned = Nothing
                            }
                    base = viewFor sc
                evaluations <- newIORef (0 :: Int)
                let counted =
                        base
                            { sessionTracer = readPhaseLog path
                            , outputs = \query -> do
                                case query of
                                    AnyOf _ -> atomicModifyIORef' evaluations (\n -> (n + 1, ()))
                                    AtTxIn _ -> atomicModifyIORef' evaluations (\n -> (n + 1, ()))
                                    _ -> pure ()
                                outputs base query
                            }
                _ <-
                    withLatest (servingSession counted) $ \v ->
                        bookEdgeMeasured
                            cfg
                            v
                            payer
                            tokenId
                            key0
                            edge0
                            (edgeDestinationOf cfg codes payer edge0)
                            (scDeposit sc)
                            (approvalFor sc)
                            []
                            Nothing
                measured <- readIORef evaluations
                objects <- logObjects path
                -- the balancer evaluates more than once: the count is not one
                measured `shouldSatisfy` (> 0)
                length (phaseLines "eval" objects) `shouldBe` measured
                map (textField "builder") (phaseLines "build-body" objects)
                    `shouldBe` [Just "bookEdgeMeasured"]
                map (textField "outcome") (phaseLines "build-body" objects)
                    `shouldBe` [Just "ok"]
        it
            "holds for every generated wallet, evaluator reading and funding choice"
            $ property
            $ forAll genScenario
            $ \sc -> ioProperty $ do
                tx <- measuredBooking sc
                pure (findings sc tx === [])
        it
            "either refuses a funding output that cannot carry the booking or builds it valid, at every boundary"
            $ checkCoverage
            $ forAll genTight
            $ \sc -> ioProperty $ do
                built <- try (measuredBooking sc >>= evaluate)
                pure $ case built of
                    Left (_ :: ErrorCall) ->
                        cover 10 True "refused" (property True)
                    Right tx ->
                        cover 10 True "built" (findings sc tx === [])
        it
            "never collateralises a whole funding output: under a collateral percentage high enough to leave a funding output no room for a return it refuses or states a return"
            $ property
            $ forAll genTight
            $ \sc -> ioProperty $ do
                let high = parametersFor sc & ppCollateralPercentageL .~ 1800
                    Held _ funding = first "funding" (scWallet sc)
                built <-
                    try
                        ( bookEdgeMeasured
                            cfg
                            (withParameters high $ viewFor sc)
                            payer
                            tokenId
                            key0
                            edge0
                            (edgeDestinationOf cfg codes payer edge0)
                            (scDeposit sc)
                            (approvalFor sc)
                            []
                            Nothing
                            >>= evaluate
                        )
                pure $ case built of
                    Left (_ :: ErrorCall) -> property True
                    Right tx ->
                        let body = tx ^. bodyTxL
                        in  conjoin
                                [ property (body ^. collateralReturnTxBodyL /= SNothing)
                                , property (body ^. totalCollateralTxBodyL /= SJust (Coin funding))
                                ]
        it
            "judges the fixed booking unmeasured: the control the judgement can fail"
            $ property
            $ forAll genScenario
            $ \sc -> ioProperty $ do
                tx <- fixedBooking sc
                pure (not (null (findings sc tx)))
        describe
            "finds each mutation of a measured booking, having first changed it"
            $ mapM_
                ( \(name, generate, mutate) ->
                    it name $
                        property $
                            forAll generate $ \sc -> ioProperty $ do
                                tx <- measuredBooking sc
                                let mutated = mutate sc tx
                                pure
                                    ( conjoin
                                        [ findings sc tx === []
                                        , property (mutated /= tx)
                                        , property (not (null (findings sc mutated)))
                                        ]
                                    )
                )
                mutations
        it
            "is built, measured and certified from the one view it is handed, whatever a later acquisition answers"
            $ property
            $ forAll genScenario
            $ \sc -> ioProperty $ do
                -- tree-change-requires-approval then P2: the first acquisition holds tree-change-requires-approval, every later one P2,
                -- with a fee per byte ten times as high. The booking is built inside
                -- one acquisition and must be the tree-change-requires-approval build; a booking built from a
                -- P2 view must be dearer, so the parameters do reach the body.
                acquired <- newIORef (0 :: Int)
                let p1 = parametersFor sc
                    p2 = p1 & ppTxFeePerByteL .~ CoinPerByte (CompactCoin 440)
                    (network, original) = providerFor sc
                    moving =
                        ( network
                        , original
                            { acquire = \request k -> do
                                n <- atomicModifyIORef' acquired (\c -> (c + 1, c))
                                acquire
                                    ( snd
                                        ( servingSession
                                            (withParameters (if n == 0 then p1 else p2) (viewFor sc))
                                        )
                                    )
                                    request
                                    k
                            }
                        )
                    under v =
                        bookEdgeMeasured
                            cfg
                            v
                            payer
                            tokenId
                            key0
                            edge0
                            (edgeDestinationOf cfg codes payer edge0)
                            (scDeposit sc)
                            (approvalFor sc)
                            [(refIn, refOut) | scByReference sc]
                            (fundingOf sc)
                handed1 <- under (viewFor sc)
                (captured, whileMoving) <-
                    withLatest moving $ \v -> do
                        capturedParameters <- parameters v
                        (,) capturedParameters <$> under v
                handed2 <- under (withParameters p2 $ viewFor sc)
                acquisitions <- readIORef acquired
                let feeOf t = let Coin f = t ^. bodyTxL . feeTxBodyL in f
                    -- the time a request is stamped with differs between two builds,
                    -- so a build is compared by what it states: its fee, its total
                    -- collateral and the units it declares
                    summary t =
                        let Redeemers m = t ^. witsTxL . rdmrsTxWitsL
                        in  ( feeOf t
                            , t ^. bodyTxL . totalCollateralTxBodyL
                            , [u | (_, (_, u)) <- Map.toList m]
                            )
                pure
                    ( conjoin
                        [ counterexample
                            "the view the booking was built in did not hold the first answer"
                            (captured === p1)
                        , counterexample
                            "a booking built in the P1 view differs from the P1 build"
                            (summary whileMoving === summary handed1)
                        , counterexample
                            ("the booking acquired " <> show acquisitions <> " views, not one")
                            (acquisitions === 1)
                        , counterexample
                            ( "fees "
                                <> show (feeOf handed1, feeOf handed2)
                                <> ": a P2 body is not dearer than a P1 body"
                            )
                            (property (feeOf handed2 > feeOf handed1))
                        ]
                    )
        it "refuses a funding output that is not the wallet's" $
            do
                let sc =
                        Scenario
                            { scWallet = [Held (first "txIn" txIns) 50_000_000]
                            , scUnits = ExUnits 1 1
                            , scSlope = 0
                            , scDeposit = 2_000_000
                            , scByReference = False
                            , scPinned = Nothing
                            }
                    stranger = txIns !! 5
                measuredBookingWith sc (Just stranger)
                    `shouldThrow` anyErrorCall
  where
    measuredBookingWith sc =
        bookEdgeMeasured
            cfg
            (viewFor sc)
            payer
            tokenId
            key0
            edge0
            (edgeDestinationOf cfg codes payer edge0)
            (scDeposit sc)
            (approvalFor sc)
            []
