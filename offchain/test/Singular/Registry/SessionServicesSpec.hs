module Singular.Registry.SessionServicesSpec (spec) where

import Cardano.Ledger.Alonzo.Plutus.Evaluate (evalTxExUnits)
import Cardano.Ledger.State (UTxO (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Slotting.Time (getRelativeTime, getSlotLength)
import Codec.Serialise (DeserialiseFailure, deserialiseOrFail)
import Control.Monad (forM_)
import Control.Monad.State.Strict (State, modify', runState)
import Control.Tracer (nullTracer)
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Ouroboros.Consensus.HardFork.History.EraParams (EraParams (..))
import Ouroboros.Consensus.HardFork.History.Summary
    ( Bound (..)
    , EraSummary (..)
    )
import Singular.Registry.Evidence
    ( Evidenced (..)
    , NoWitness
    , SessionBinding (..)
    , SessionId (..)
    )
import Singular.Registry.LedgerProvider
import Singular.Registry.LocalEvaluation
    ( EvaluationContext (..)
    , EvaluationFailure (..)
    )
import Singular.Registry.LocalEvaluationSpec (fixture)
import Singular.Registry.NetworkTime
    ( NetworkTimeFailure (..)
    , NetworkTimeManifest (..)
    , networkEpochInfo
    , networkSystemStart
    , slotStartMs
    )
import Singular.Registry.NetworkTimeSpec (loadNetworkFixture)
import Singular.Registry.SessionServices qualified as Services
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldSatisfy
    )

-- Recorded raw evaluation material, without a provider or an injected
-- evaluator/conversion answer. This fixture tests the local-service boundary;
-- constructor coverage belongs to Provider.Koios.ProviderSpec.
rawSession
    :: EvaluationContext -> Outputs -> Session NoWitness (State [Text])
rawSession context resolved =
    Session
        { sessionNetwork = Network 1
        , sessionId = SessionId "local-service-fixture"
        , sessionBinding = Unbound
        , sessionTracer = nullTracer
        , sessionEvaluated = \_ -> pure ()
        , outputs = \query -> observed "outputs" $ case query of
            AnyOf references ->
                Right
                    ( Evidenced
                        [pair | pair <- resolved, AtTxIn (fst pair) `elem` references]
                        Nothing
                    )
            _ ->
                Left (BackendReadFailure "unsupported local-service fixture query")
        , protocolParameters =
            observed
                "parameters"
                (Right (Evidenced (evaluationParameters context) Nothing))
        , tipObservation =
            observed "tip" (Left (BackendReadFailure "unused fixture tip"))
        , networkTime =
            observed
                "network-time"
                (Right (Evidenced (evaluationNetworkTime context) Nothing))
        , scriptRegistered =
            const
                ( observed
                    "registration"
                    (Left (BackendReadFailure "unused fixture registration"))
                )
        , mintRecord =
            const
                ( observed
                    "mint-record"
                    (Left (BackendReadFailure "unused fixture mint record"))
                )
        , history = \_ _ ->
            observed
                "history"
                ( Left
                    (HistoryReadFailure (BackendReadFailure "unused fixture history"))
                )
        }
  where
    observed name result = modify' (<> [name]) >> pure result

spec :: Spec
spec = describe "Generic local services" $ do
    it
        "evaluates complete spent, collateral and reference facts in pure State"
        $ do
            (context, resolved, tx, _, _, _) <- fixture
            let (actual, calls) = runState (Services.evaluateTx (rawSession context resolved) tx) []
                time = evaluationNetworkTime context
                expected =
                    evalTxExUnits
                        (evaluationParameters context)
                        tx
                        (UTxO (Map.fromList resolved))
                        (networkEpochInfo time)
                        (networkSystemStart time)
            Map.size expected `shouldSatisfy` (> 0)
            fmap show actual `shouldBe` Right (show expected)
            calls `shouldBe` ["parameters", "network-time", "outputs"]
    it "names each missing resolved input before evaluation" $ do
        (context, resolved, tx, _, _, _) <- fixture
        forM_ resolved $ \(reference, _) -> do
            let (actual, _) =
                    runState
                        ( Services.evaluateTx
                            (rawSession context (filter ((/= reference) . fst) resolved))
                            tx
                        )
                        []
            case actual of
                Left failure ->
                    failure
                        `shouldBe` Services.ServiceEvaluationFailure
                            (MissingEvaluationInputs (Set.singleton reference))
                Right _ -> expectationFailure "incomplete evaluation context was accepted"
    it "refuses a time context bound to another network" $ do
        (context, resolved, _, _, _, _) <- fixture
        let session = (rawSession context resolved){sessionNetwork = Network 42}
            (actual, calls) = runState (Services.floorSlot session 0) []
        actual
            `shouldBe` Left (Services.ServiceTimeFailure (WrongTimeNetwork 42 1))
        calls `shouldBe` ["network-time"]
    it
        "keeps rounding and far-future slot starts in the pinned final era"
        $ do
            (context, resolved, _, _, _, _) <- fixture
            start <-
                either
                    (fail . show)
                    pure
                    (slotStartMs (evaluationNetworkTime context) (SlotNo 100))
            (manifest, _, rawHistory, _) <- loadNetworkFixture "preprod"
            eras <-
                either
                    (fail . show)
                    pure
                    ( deserialiseOrFail (LBS.fromStrict rawHistory)
                        :: Either DeserialiseFailure [EraSummary]
                    )
            finalEra <- case reverse eras of
                era : _ -> pure era
                [] -> fail "EmptyRawHistory"
            -- Earlier eras use different slot lengths. Extrapolate only the
            -- raw final era, preserving its recorded start and offset.
            let finalStart = eraStart finalEra
                remaining =
                    toInteger (unSlotNo (SlotNo maxBound))
                        - toInteger (unSlotNo (boundSlot finalStart))
                farStart =
                    timeSystemStartMs manifest
                        + floor
                            ( ( getRelativeTime (boundTime finalStart)
                                    + fromInteger remaining
                                        * getSlotLength (eraSlotLength (eraParams finalEra))
                              )
                                * 1000
                            )
            let session = rawSession context resolved
                action = do
                    below <- Services.floorSlot session (start + 1)
                    above <- Services.ceilingSlot session (start + 1)
                    beginning <- Services.slotStart session (SlotNo 100)
                    outside <- Services.slotStart session (SlotNo maxBound)
                    pure (below, above, beginning, outside)
                (actual, calls) = runState action []
            actual
                `shouldBe` ( Right (SlotNo 100)
                           , Right (SlotNo 101)
                           , Right start
                           , Right farStart
                           )
            calls `shouldBe` replicate 4 "network-time"
    it "preserves raw read refusal without starting derived work" $ do
        (context, resolved, tx, _, _, _) <- fixture
        let session =
                (rawSession context resolved)
                    { protocolParameters =
                        modify' (<> ["parameters"])
                            >> pure (Left (BackendReadFailure "raw-parameters-refusal"))
                    }
            (actual, calls) = runState (Services.evaluateTx session tx) []
        case actual of
            Left failure ->
                failure
                    `shouldBe` Services.ServiceReadFailure
                        (BackendReadFailure "raw-parameters-refusal")
            Right _ -> expectationFailure "raw refusal became an evaluation result"
        calls `shouldBe` ["parameters"]
