{-# LANGUAGE NumericUnderscores #-}

{- | Retained generic raw-source and common time obligations. Original
atomic node/indexer requirements are published uncovered by ContractSuite;
their removed mechanics are not renamed into this fixture.
-}
module Singular.Registry.ProviderSpec (spec) where

import Cardano.Ledger.Api.PParams (emptyPParams)
import Cardano.Slotting.Slot (SlotNo (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Singular.Registry.ContractMemory (memoryHarness)
import Singular.Registry.ContractSuite (contractSuite)
import Singular.Registry.LedgerProvider
    ( ReadFailure (..)
    , Session (..)
    , TipObservation (..)
    )
import Singular.Registry.NetworkTime (NetworkTimeFailure (..))
import Singular.Registry.RawChainFixture
    ( ChainFacts (..)
    , advanceChain
    , loseConnection
    , newRawChain
    , rawChainProvider
    )
import Singular.Registry.SessionIO qualified as Services
import Singular.Registry.SessionServices qualified as Common
import Singular.Registry.SyntheticTime (syntheticTime)
import Test.Hspec

spec :: Spec
spec = describe
    "generic raw sessions and original uncovered node requirements"
    $ do
        contractSuite memoryHarness
        it
            "each raw fixture mutation advances its observed tip without establishing binding"
            $ do
                chain <- newRawChain genesis
                advanceChain chain id
                first <- Services.withLatest (rawChainProvider chain) Services.tip
                advanceChain chain id
                second <- Services.withLatest (rawChainProvider chain) Services.tip
                observedSlot second `shouldBe` succ (observedSlot first)
                observedHash second `shouldNotBe` observedHash first
        it
            "common time keeps original rounding and extends the pinned final era"
            $ do
                chain <- newRawChain genesis
                advanceChain chain id
                Services.withLatest (rawChainProvider chain) $ \session -> do
                    Common.floorSlot session 5_010 `shouldReturn` Right (SlotNo 5)
                    Common.ceilingSlot session 5_010 `shouldReturn` Right (SlotNo 6)
                    Common.slotStart session (SlotNo 6) `shouldReturn` Right 6_000
                    Common.floorSlot session 4_320_000_000_000
                        `shouldReturn` Right (SlotNo 4_320_000_000)
        it
            "common time preserves actual source loss and wrong time network as distinct refusals"
            $ do
                chain <- newRawChain genesis
                advanceChain chain id
                Services.withLatest (rawChainProvider chain) $ \session -> do
                    loseConnection chain
                    Common.floorSlot session 5_000
                        `shouldReturn` Left
                            (Common.ServiceReadFailure (BackendReadFailure "ViewConnectionLost"))
                wrong <- newRawChain genesis{csNetwork = 1}
                advanceChain wrong id
                Services.withLatest (rawChainProvider wrong) $ \session ->
                    Common.floorSlot session 5_000
                        `shouldReturn` Left (Common.ServiceTimeFailure (WrongTimeNetwork 1 42))
        it "common time refuses released raw scope with its actual identity" $ do
            chain <- newRawChain genesis
            advanceChain chain id
            escaped <- Services.withLatest (rawChainProvider chain) pure
            Common.floorSlot escaped 5_000
                `shouldReturn` Left (Common.ServiceReadFailure (ReleasedSession (sessionId escaped)))

genesis :: ChainFacts
genesis =
    ChainFacts
        { csNetwork = 42
        , csTip = Nothing
        , csPParams = emptyPParams
        , csUTxO = Map.empty
        , csRegistered = Set.empty
        , csNetworkTime = syntheticTime
        }
