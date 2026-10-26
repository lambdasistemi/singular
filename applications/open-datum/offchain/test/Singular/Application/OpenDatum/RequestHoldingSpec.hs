{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Singular.Application.OpenDatum.RequestHoldingSpec
Description : Controller updates and termination bookings judged by the compiled validator
License     : Apache-2.0

A live holding is reached by creating a registry, booking and folding a
registration. Its controller then updates or books termination. The ledger's
script evaluator judges the actual built transaction; output values and
identities are read independently from the transaction.
-}
module Singular.Application.OpenDatum.RequestHoldingSpec (spec, withHoldingIn) where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Lens.Micro ((%~), (&), (.~), (^.))
import PlutusCore.Data qualified as PLC
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldReturn
    , shouldSatisfy
    )

import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Out (coinTxOutL, valueTxOutL)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway.TxBody (treasuryDonationTxBodyL)
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Application.OpenDatum.CreationWorld
import Singular.Application.OpenDatum.RequestWorld
    ( assetsOf
    , expectBuilt
    , inlineDatum
    , mapOutput
    , mintedOf
    , network
    , oracleLive
    , outputRef
    , referencesOf
    , signersOf
    , txInOf
    , valueAda
    , withDatum
    , withSigners
    )
import Singular.Application.OpenDatum.Requests.Booking (Booking (..))
import Singular.Application.OpenDatum.Requests.Fold
    ( openDatumApplication
    )
import Singular.Application.OpenDatum.Requests.Holding (buildUpdate)
import Singular.Application.OpenDatum.Requests.Refusal (Refusal (..))
import Singular.Registry.Ledger (ConwayEra, TxOut)
import Singular.Registry.TrieState (RegistryIdentity)
import Singular.State.Fold (buildRegistrationFold)
import Singular.State.Preimage (activeTokenName)
import Singular.State.Script (statePolicy)

key :: ByteString
key = "a live key"

-- | A live holding, reached through the ordinary builders, with every script run.
withHolding
    :: (Creation -> RegistryIdentity -> TxIn -> TxOut ConwayEra -> IO ())
    -> IO ()
withHolding = withHoldingIn newCreation

-- | Reach a holding in an explicitly supplied public-chain fixture.
withHoldingIn
    :: IO Creation
    -> (Creation -> RegistryIdentity -> TxIn -> TxOut ConwayEra -> IO ())
    -> IO ()
withHoldingIn makeWorld action = do
    world <- makeWorld
    registry <- created world
    booking <-
        expectBuilt
            =<< bookAs
                world
                ( Booking
                    registry
                    key
                    (PLC.I 42)
                    (Coin 5_000_000)
                    (Coin 1_000_000)
                    (crBooker world)
                )
    judge world booking >>= (`shouldSatisfy` everyScriptAccepts)
    applyTx world booking
    foldTx <- withSession world $ \session -> do
        application <-
            expectBuilt =<< openDatumApplication session (crRequest world) network
        expectBuilt
            =<< buildRegistrationFold
                session
                (crState world)
                application
                registry
                [pendingOf world booking]
                (crFolder world)
    judge world foldTx >>= (`shouldSatisfy` everyScriptAccepts)
    let index =
            holderIndex
                (statePolicy (crState world))
                (activeTokenName registry key)
                foldTx
    holding <-
        maybe (fail "no live holding") pure (outputAtIndex foldTx index)
    applyTx world foldTx
    action world registry (outputRef foldTx index) holding

update :: Creation -> TxIn -> PLC.Data -> IO (Either Refusal ConwayTx)
update world ref payload = withSession world $ \session ->
    buildUpdate session (crRequest world) ref payload (crBooker world)

spec :: Spec
spec = do
    describe "a controller updates a live holding" $ do
        forM_
            [ PLC.I 0
            , PLC.B "new payload"
            , PLC.Constr 3 [PLC.List [PLC.I 8, PLC.I 9]]
            ]
            $ \payload ->
                it ("changes only the payload to " <> show payload) $ withHolding $ \world registry ref before -> do
                    tx <- expectBuilt =<< update world ref payload
                    judge world tx >>= (`shouldSatisfy` everyScriptAccepts)
                    let index =
                            holderIndex
                                (statePolicy (crState world))
                                (activeTokenName registry key)
                                tx
                    after <-
                        maybe (fail "no updated holding") pure (outputAtIndex tx index)
                    assetsOf after `shouldBe` assetsOf before
                    valueAda after `shouldSatisfy` (>= 5_000_000)
                    inlineDatum after
                        `shouldBe` Just
                            ( oracleLive
                                registry
                                key
                                (controllerOf (crBooker world))
                                5_000_000
                                payload
                            )
                    mintedOf tx `shouldBe` []
                    referencesOf tx `shouldBe` []
                    signersOf tx `shouldBe` [controllerOf (crBooker world)]
                    tx ^. bodyTxL . treasuryDonationTxBodyL `shouldBe` Coin 0
                    soundnessProblems world tx `shouldReturn` []

        it
            "refuses mutations of signature, protected control, tokens and deposit beside a passing update"
            $ withHolding
            $ \world registry ref _ -> do
                tx <- expectBuilt =<< update world ref (PLC.I 7)
                judge world tx >>= (`shouldSatisfy` everyScriptAccepts)
                let index =
                        holderIndex
                            (statePolicy (crState world))
                            (activeTokenName registry key)
                            tx
                    mutated =
                        [ withSigners [] tx
                        , mapOutput
                            index
                            ( withDatum
                                ( oracleLive
                                    registry
                                    key
                                    (controllerOf (crFolder world))
                                    5_000_000
                                    (PLC.I 7)
                                )
                            )
                            tx
                        , mapOutput
                            index
                            (\out -> out & valueTxOutL .~ MaryValue (Coin (valueAda out)) mempty)
                            tx
                        , mapOutput
                            index
                            ( \out ->
                                out
                                    & valueTxOutL %~ \(MaryValue coin assets) -> MaryValue coin (assets <> assets)
                            )
                            tx
                        , mapOutput index (\out -> out & coinTxOutL .~ Coin 4_999_999) tx
                        ]
                forM_ mutated $ \bad -> judge world bad >>= (`shouldSatisfy` refusedBy)

    describe "an update builder declines before signing" $ do
        it "declines a missing holding beside each successful builder" $ withHolding $ \world _ ref _ -> do
            let missing = txInOf 'f' 0
            _ <- expectBuilt =<< update world ref (PLC.I 7)
            update world missing (PLC.I 7)
                `shouldReturn` Left (HoldingNotFound missing)
        it
            "declines a payer who is not the controller beside each successful builder"
            $ withHolding
            $ \world _ ref _ -> do
                _ <- expectBuilt =<< update world ref (PLC.I 7)
                withSession
                    world
                    ( \session ->
                        buildUpdate session (crRequest world) ref (PLC.I 7) (crFolder world)
                    )
                    `shouldReturn` Left PayerIsNotController
