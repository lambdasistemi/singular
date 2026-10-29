{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.OpenDatum.RequestFoldSpec
Description : A booked registration is folded by a second wallet, under both compiled validators
License     : Apache-2.0

The journey of a registration on one chain: a registry of open datum is
created, a registration is booked with the booking builder, and a second
wallet, which holds nothing of the booker's, folds it from the chain alone. The
state validator and the request validator both run on the fold and both accept
it. Each is refused again when one fact of the transaction is made wrong, so
neither validator is left to the other.
-}
module Singular.Application.OpenDatum.RequestFoldSpec
    ( spec
    ) where

import Control.Monad (forM)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Lens.Micro ((&), (.~))
import PlutusCore.Data qualified as PLC
import Test.Hspec

import Cardano.Ledger.Api.Tx.Out (coinTxOutL)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Application.OpenDatum.CreationWorld
import Singular.Application.OpenDatum.RequestWorld
    ( feeOf
    , inlineDatum
    , keyAddress
    , mapOutput
    , mintedOf
    , network
    , validityOf
    , valueAda
    , withDatum
    , withValidity
    )
import Singular.Application.OpenDatum.Requests.Booking (Booking (..))
import Singular.Application.OpenDatum.Requests.Fold
    ( openDatumApplication
    )
import Singular.Application.OpenDatum.Requests.Records (liveDatum)
import Singular.Application.OpenDatum.Requests.Script (requestPolicy)
import Singular.Registry.TrieState (RegistryIdentity)
import Singular.State.Fold (buildRegistrationFold)
import Singular.State.Preimage (activeTokenName)
import Singular.State.Refusal qualified as State
import Singular.State.Script (statePolicy)

spec :: Spec
spec = do
    describe
        "a booked registration, folded by a second wallet from the chain"
        $ do
            it "is accepted by both compiled validators" $ do
                (world, registry, pendings) <- booked ["first key"]
                tx <- folding world registry pendings
                judged <- judge world tx
                everyScriptAccepts judged `shouldBe` True
                purposesRun judged `shouldBe` [(Mint, 2), (Spend, 2)]

            it
                "delivers the key's token into a holding at the request address with the live datum and exactly the deposit"
                $ do
                    (world, registry, pendings) <- booked ["first key"]
                    tx <- folding world registry pendings
                    let index = holder world registry "first key" tx
                    holdings <- maybe (fail "no holding") pure (outputAtIndex tx index)
                    valueAda holdings `shouldBe` 5_000_000
                    inlineDatum holdings
                        `shouldBe` Just
                            ( liveDatum
                                registry
                                "first key"
                                (controllerOf (crBooker world))
                                5_000_000
                                (PLC.I 42)
                            )

            it
                "burns the approval and mints the token of the key, and leaves the tip to the folder"
                $ do
                    (world, registry, pendings) <- booked ["first key"]
                    tx <- folding world registry pendings
                    let minted = mintedOf tx
                    length
                        [() | (policy, _, 1) <- minted, policy == statePolicy (crState world)]
                        `shouldBe` 1
                    length
                        [ ()
                        | (policy, _, -1) <- minted
                        , policy == requestPolicy (crRequest world)
                        ]
                        `shouldBe` 1
                    paidTo (crFolder world) tx
                        `shouldBe` 50_000_000 + 1_000_000 - feeOf tx

            it
                "pays its way: value is conserved, outputs hold their minimum, collateral is declared"
                $ do
                    (world, registry, pendings) <- booked ["first key"]
                    tx <- folding world registry pendings
                    soundnessProblems world tx `shouldReturn` []

    describe "a batch of registrations" $ do
        it "is folded in one transaction that both validators accept" $ do
            (world, registry, pendings) <-
                booked ["key one", "key two", "key three"]
            tx <- folding world registry pendings
            judged <- judge world tx
            everyScriptAccepts judged `shouldBe` True
            purposesRun judged `shouldBe` [(Mint, 2), (Spend, 4)]

    describe "a batch of six registrations" $ do
        it "is folded in one transaction that both validators accept" $ do
            (world, registry, pendings) <-
                booked ["key " <> BS.singleton n | n <- [1 .. 6]]
            tx <- folding world registry pendings
            judged <- judge world tx
            everyScriptAccepts judged `shouldBe` True
            purposesRun judged `shouldBe` [(Mint, 2), (Spend, 7)]

    describe "each validator refuses what the other would accept" $ do
        it
            "the request validator refuses a fold that outlives the processing deadline"
            $ do
                (world, registry, pendings) <- booked ["first key"]
                tx <- folding world registry pendings
                refused world (withValidity (fst (validityOf tx)) (Just 20_000) tx)

        it
            "the request validator refuses a holding that keeps one lovelace more than the deposit"
            $ do
                (world, registry, pendings) <- booked ["first key"]
                tx <- folding world registry pendings
                refused
                    world
                    ( mapOutput
                        (holder world registry "first key" tx)
                        (\out -> out & coinTxOutL .~ Coin (valueAda out + 1))
                        tx
                    )

        it
            "the state validator refuses a holding whose datum is not the one the approval commits"
            $ do
                (world, registry, pendings) <- booked ["first key"]
                tx <- folding world registry pendings
                refused
                    world
                    ( mapOutput
                        (holder world registry "first key" tx)
                        (withDatum (PLC.I 0))
                        tx
                    )

-- | Create a registry and book these keys, as the booker; the pending registrations in order.
booked :: [ByteString] -> IO (Creation, RegistryIdentity, [TxIn])
booked keys = do
    world <- newCreation >>= withPublicScripts
    registry <- created world
    pendings <- forM keys $ \key -> do
        tx <-
            bookAs
                world
                Booking
                    { bookRegistry = registry
                    , bookKey = key
                    , bookPayload = PLC.I 42
                    , bookDeposit = Coin 5_000_000
                    , bookTip = Coin 1_000_000
                    , bookRefund = keyAddress 0x22
                    }
                >>= either (fail . show) pure
        applyTx world tx
        pure (pendingOf world tx)
    pure (world, registry, pendings)

-- | The fold of these pending registrations, built as the second wallet.
folding :: Creation -> RegistryIdentity -> [TxIn] -> IO ConwayTx
folding world registry pendings =
    withSession world $ \session -> do
        application <-
            openDatumApplication session (crRequest world) network
                >>= either (fail . show) pure
        buildRegistrationFold
            session
            (crState world)
            application
            registry
            pendings
            (crFolder world)
            >>= either (fail . show :: State.Refusal -> IO ConwayTx) pure

refused :: Creation -> ConwayTx -> Expectation
refused world tx = do
    judged <- judge world tx
    refusedBy judged `shouldBe` True

-- | The index of the output that holds the token of a key.
holder
    :: Creation -> RegistryIdentity -> ByteString -> ConwayTx -> Int
holder world registry key =
    holderIndex
        (statePolicy (crState world))
        (activeTokenName registry key)
