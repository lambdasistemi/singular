{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.Application.OpenDatum.ClosedModeSpec
Description : Library application-pin resolution
License     : Apache-2.0

The library selects an open or closed application derivation by its pins.
These checks resolve registries directly and retain the loader and refused-pin
assertions independently of public command routing.
-}
module Singular.Application.OpenDatum.ClosedModeSpec (spec) where

import Cardano.Ledger.Api.Tx.Out (addrTxOutL, valueTxOutL)
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value
    ( MaryValue (MaryValue)
    , MultiAsset (MultiAsset)
    )
import Data.Aeson qualified as Aeson ()
import Data.ByteString qualified as BS (replicate)
import Data.ByteString.Base16 qualified as B16 ()
import Data.ByteString.Char8 qualified as BC ()
import Data.ByteString.Short qualified as SBS (ShortByteString)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
    ( findWithDefault
    , lookup
    , singleton
    , toAscList
    )
import Data.Text qualified as T ()
import Data.Text.Encoding qualified as TE ()
import Lens.Micro ((^.))
import Singular.Application.OpenDatum.StateTokenFixture qualified as Fixture
    ( Chain (chainMints, chainNetwork, chainOutputs)
    , honestChain
    , release
    , seedIn
    , stateIn
    , stateOutput
    , token
    )
import Singular.Application.OpenDatum.Value
    ( Mode (..)
    , applicationIn
    , openDatumApplication
    )
import Singular.CLI.Command qualified as RegistryCLI ()
import Singular.Registry.Application (Application (appPin))
import Singular.Registry.Blueprint
    ( ApplicationCodes (..)
    , applyBytesParam
    )
import Singular.Registry.Config
    ( CageConfig (..)
    , bootStateFromCfg
    )
import Singular.Registry.Config.Application
    ( RegistryEconomics (..)
    , configForApplication
    )
import Singular.Registry.Evidence (Evidenced (..), NoWitness)
import Singular.Registry.LedgerProvider qualified as LP
    ( OutputQuery
        ( AllOf
        , AnyOf
        , AtAddress
        , AtTxIn
        , CarryingReferenceScript
        , HoldingAsset
        , HoldingPolicy
        )
    , ReadFailure (MissingOutput)
    , Session (mintRecord, networkTime, outputs, sessionNetwork)
    )
import Singular.Registry.StateToken
    ( IdentityRefusal (..)
    , PinField (..)
    , Release (..)
    , resolveRegistry
    , resolveRegistryAmong
    )
import Singular.Registry.StubSession (stubSession)
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.TxBuilder.BookingFixture qualified as Booking
    ( program
    )
import Singular.Registry.TxBuilder.Internal
    ( emptyRoot
    , txInToRef
    )
import Singular.Registry.Types
    ( OnChainRoot (..)
    , OnChainTokenState
    )
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldReturn
    )

spec :: Spec
spec = do
    modeReadFromChain
    unreadableNotGuessed
    loaderDecidesCode

-- ---------------------------------------------------------
-- Shared pieces
-- ---------------------------------------------------------

openAppProg :: SBS.ShortByteString
openAppProg = applyBytesParam (BS.replicate 32 0x61) Booking.program

closedAppProg :: SBS.ShortByteString
closedAppProg = applyBytesParam (BS.replicate 32 0x62) Booking.program

thirdAppProg :: SBS.ShortByteString
thirdAppProg = applyBytesParam (BS.replicate 32 0x63) Booking.program

toyRelease :: SBS.ShortByteString -> Release
toyRelease appProg =
    Release
        { releaseState = releaseState Fixture.release
        , releaseRequest = releaseRequest Fixture.release
        , releaseCodes = (releaseCodes Fixture.release){ncApplication = appProg}
        }

releaseOpen :: Release
releaseOpen = toyRelease openAppProg

releaseClosed :: Release
releaseClosed = toyRelease closedAppProg

releaseThird :: Release
releaseThird = toyRelease thirdAppProg

econ :: RegistryEconomics
econ =
    RegistryEconomics
        { reProcessTime = 600_000
        , reRetractTime = 300_000
        , reTip = Coin 1_000_000
        }

cfgOpen :: CageConfig
cfgClosed :: CageConfig
cfgThird :: CageConfig
(cfgOpen, _) =
    configForApplication
        (appPin (applicationIn Open))
        (releaseCodes releaseOpen)
        (releaseState releaseOpen)
        (releaseRequest releaseOpen)
        econ
        Testnet
        (txInToRef Fixture.seedIn)
(cfgClosed, _) =
    configForApplication
        (appPin (applicationIn Closed))
        (releaseCodes releaseClosed)
        (releaseState releaseClosed)
        (releaseRequest releaseClosed)
        econ
        Testnet
        (txInToRef Fixture.seedIn)
(cfgThird, _) =
    configForApplication
        (appPin (applicationIn Open))
        (releaseCodes releaseThird)
        (releaseState releaseThird)
        (releaseRequest releaseThird)
        econ
        Testnet
        (txInToRef Fixture.seedIn)

stateOpen :: OnChainTokenState
stateClosed :: OnChainTokenState
stateThird :: OnChainTokenState
stateOpen = bootStateFromCfg cfgOpen (OnChainRoot emptyRoot)
stateClosed = bootStateFromCfg cfgClosed (OnChainRoot emptyRoot)
stateThird = bootStateFromCfg cfgThird (OnChainRoot emptyRoot)

-- ---------------------------------------------------------
-- Chains
-- ---------------------------------------------------------

chainWith :: OnChainTokenState -> Fixture.Chain
chainWith st =
    Fixture.honestChain
        { Fixture.chainOutputs =
            Map.singleton Fixture.stateIn (Fixture.stateOutput st)
        }

gateSelects
    :: Bool -> OnChainTokenState -> IO (Either IdentityRefusal Mode)
gateSelects withClosed datum = do
    let candidates =
            (applicationIn Open, releaseOpen)
                :| [(applicationIn Closed, releaseClosed) | withClosed]
    resolved <-
        resolveRegistryAmong
            candidates
            Fixture.token
            (sessionFor (chainWith datum))
    pure $ case resolved of
        Left refusal -> Left refusal
        Right (_, (selected, _))
            | appPin selected == appPin (applicationIn Closed) -> Right Closed
            | otherwise -> Right Open

modeReadFromChain :: Spec
modeReadFromChain = describe "the mode selected by the gate" $ do
    it "selects the closed derivation for a closed datum" $
        gateSelects True stateClosed `shouldReturn` Right Closed
    it "selects the open derivation for an open datum" $
        gateSelects True stateOpen `shouldReturn` Right Open
    it
        "selects the open derivation for an open registry with an older blueprint"
        $ gateSelects False stateOpen `shouldReturn` Right Open

unreadableNotGuessed :: Spec
unreadableNotGuessed = describe "an unreadable mode is not guessed" $ do
    it "refuses a neither-hash, naming the application" $
        gateSelects True stateThird
            `shouldReturn` Left RegistryPinMismatchEvery
    it
        "refuses a neither-hash with an older blueprint, naming the application"
        $ gateSelects False stateThird
            `shouldReturn` Left (RegistryPinMismatch PinApplication)
loaderDecidesCode :: Spec
loaderDecidesCode = describe "the loader decides the code" $ do
    it "resolves a closed registry through the open-titled value" $ do
        let sess = sessionFor (chainWith stateClosed)
        res <-
            resolveRegistry openDatumApplication releaseClosed Fixture.token sess
        case res of
            Right _ -> pure ()
            Left err ->
                expectationFailure
                    ("closed resolve through open value refused: " <> show err)

sessionFor :: Fixture.Chain -> LP.Session NoWitness IO
sessionFor chain =
    (stubSessionFor chain)
        { LP.sessionNetwork = Fixture.chainNetwork chain
        }

stubSessionFor :: Fixture.Chain -> LP.Session NoWitness IO
stubSessionFor chain =
    stubSession
        { LP.sessionNetwork = Fixture.chainNetwork chain
        , LP.outputs = pure . fmap (`Evidenced` Nothing) . select
        , LP.mintRecord = \a ->
            pure
                (Right (Evidenced (Map.lookup a (Fixture.chainMints chain)) Nothing))
        , LP.networkTime = pure (Right (Evidenced syntheticTime Nothing))
        }
  where
    live = Fixture.chainOutputs chain
    select = \case
        LP.AtAddress addr ->
            Right [u | u@(_, o) <- Map.toAscList live, o ^. addrTxOutL == addr]
        LP.HoldingPolicy policy ->
            Right
                [ u
                | u@(_, o) <- Map.toAscList live
                , let MaryValue _ (MultiAsset assets) = o ^. valueTxOutL
                , maybe False (any (/= 0)) (Map.lookup policy assets)
                ]
        LP.HoldingAsset (pol, nm) ->
            Right [u | u@(_, o) <- Map.toAscList live, holds pol nm o]
        LP.AtTxIn ref -> case Map.lookup ref live of
            Nothing -> Left (LP.MissingOutput ref)
            Just o -> Right [(ref, o)]
        LP.CarryingReferenceScript _ -> Right []
        LP.AnyOf _ -> Right (Map.toAscList live)
        LP.AllOf _ -> Right (Map.toAscList live)
    holds pol nm o =
        let MaryValue _ (MultiAsset m) = o ^. valueTxOutL
        in  maybe False ((/= 0) . Map.findWithDefault 0 nm) (Map.lookup pol m)
