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

import Control.Monad (forM, forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Lens.Micro ((&), (.~))
import PlutusCore.Data qualified as PLC
import Test.Hspec

import Cardano.Ledger.Api.Scripts.Data (Datum (DatumHash, NoDatum))
import Cardano.Ledger.Api.Tx.Out
    ( addrTxOutL
    , coinTxOutL
    , datumTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.Plutus.Data (Data (..), hashData)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Application.OpenDatum.CreationWorld
import Singular.Application.OpenDatum.RequestWorld
    ( assetsOf
    , feeOf
    , inlineDatum
    , keyAddress
    , mapOutput
    , mintedOf
    , network
    , outputsOf
    , scriptAddress
    , tokenQuantity
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
import Singular.Registry.Evidence (Evidenced (..))
import Singular.Registry.Ledger (ConwayEra, TxOut)
import Singular.Registry.LedgerProvider
    ( OutputQuery (..)
    , Session (outputs)
    )
import Singular.Registry.TrieState (RegistryIdentity)
import Singular.State.Fold
    ( Application (..)
    , FoldFailure (..)
    , PendingRequest (..)
    , attemptFold
    , buildFold
    , buildRegistrationFold
    , discoverPending
    , foldSelected
    , foldSkipped
    , foldedRequests
    )
import Singular.State.Preimage
    ( activeTokenName
    , configurationTokenName
    )
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

    describe
        "the configuration record the creation made, beside booked registrations"
        $ do
            it "is in neither list of the discovery" $ do
                (world, registry, pendings) <- booked ["key one", "key two"]
                (found, skipped) <- withSession world $ \session -> do
                    application <-
                        openDatumApplication session (crRequest world) network
                            >>= either (fail . show) pure
                    discoverPending session application registry []
                map pendingRef found `shouldMatchList` pendings
                length found `shouldBe` 2
                skipped `shouldBe` []

            it "is not among the skipped holders of a successful fold" $ do
                (world, registry, pendings) <- booked ["key one", "key two"]
                result <- withSession world $ \session -> do
                    application <-
                        openDatumApplication session (crRequest world) network
                            >>= either (fail . show) pure
                    buildFold
                        session
                        (crState world)
                        application
                        registry
                        []
                        (crFolder world)
                        Nothing
                built <- either (fail . show) pure result
                map pendingRef (foldSelected built) `shouldMatchList` pendings
                foldSkipped built `shouldBe` []

            it "is not among the skipped holders of a refused fold" $ do
                (world, registry, _) <- booked []
                result <- withSession world $ \session -> do
                    application <-
                        openDatumApplication session (crRequest world) network
                            >>= either (fail . show) pure
                    attemptFold
                        session
                        (crState world)
                        application
                        registry
                        []
                        (crFolder world)
                        Nothing
                case result of
                    Left failure -> do
                        foldFailureReason failure `shouldBe` State.NothingToFold
                        foldFailureObserved failure `shouldBe` Just ([], 0)
                    Right built -> expectationFailure (show built)

    describe "what the open datum description names as its configuration" $ do
        it "is exactly the output the creation step makes, of any registry" $ do
            ours <- newCreation >>= withPublicScripts
            other <- withFreshSeed ours '8'
            (ourTx, ourRegistry) <-
                createRegistry ours >>= either (fail . show) pure
            (otherTx, otherRegistry) <-
                createRegistry other >>= either (fail . show) pure
            ourRegistry `shouldNotBe` otherRegistry
            application <- applicationOf ours
            let named tx = filter (appIsConfiguration application) (outputsOf tx)
                makes registry creation =
                    [ out
                    | out <- outputsOf creation
                    , tokenQuantity
                        (requestPolicy (crRequest ours))
                        (configurationTokenName registry)
                        out
                        == 1
                    ]
            length (makes ourRegistry ourTx) `shouldBe` 1
            named ourTx `shouldBe` makes ourRegistry ourTx
            named otherTx `shouldBe` makes otherRegistry otherTx
            length (named otherTx) `shouldBe` 1

        it
            "names no request, no output elsewhere and no output that does not decode"
            $ do
                (world, registry, pendings) <- booked ["key one", "key two"]
                application <- applicationOf world
                live <- forM pendings (liveAt world)
                request <- case live of
                    first : _ -> pure first
                    [] -> fail "no request was booked"
                registration <-
                    maybe (fail "no registration datum") pure (inlineDatum request)
                (_, configuration) <- configurationOf world registry
                datum <-
                    maybe (fail "no configuration datum") pure (inlineDatum configuration)
                let at addr out = out & addrTxOutL .~ addr
                    atRequest = at (outputAddress configuration)
                    tokens = assetsOf configuration
                    holding assets out =
                        out
                            & valueTxOutL
                                .~ MaryValue
                                    (Coin (valueAda out))
                                    ( MultiAsset
                                        ( Map.fromListWith
                                            (Map.unionWith (+))
                                            [ (policy, Map.singleton name quantity)
                                            | (policy, name, quantity) <- assets
                                            ]
                                        )
                                    )
                    approvals = assetsOf request
                    lookalikes :: [(String, TxOut ConwayEra)]
                    lookalikes =
                        [ ("a registration request", request)
                        , ("a termination request", configuration & datumTxOutL .~ NoDatum)
                        ,
                            ( "the record at another script address"
                            , at (scriptAddress 0x66 0x67) configuration
                            )
                        , ("the record at a key address", at (keyAddress 0x68) configuration)
                        ,
                            ( "a datum that does not decode"
                            , atRequest (withDatum (PLC.I 0) configuration)
                            )
                        ,
                            ( "a datum of four parameters"
                            , atRequest
                                ( withDatum
                                    (PLC.Constr 0 [PLC.Constr 0 (map PLC.I [1, 2, 3, 4])])
                                    configuration
                                )
                            )
                        ,
                            ( "a registration datum on the record"
                            , atRequest (withDatum registration configuration)
                            )
                        ,
                            ( "the record with its datum hash only"
                            , atRequest
                                ( configuration
                                    & datumTxOutL .~ DatumHash (hashData (Data datum :: Data ConwayEra))
                                )
                            )
                        ,
                            ( "the record holding a second token of its policy"
                            , atRequest (holding (tokens <> approvals) configuration)
                            )
                        ,
                            ( "the record holding two of its token"
                            , atRequest
                                ( holding
                                    [(policy, name, 2) | (policy, name, _) <- tokens]
                                    configuration
                                )
                            )
                        ,
                            ( "the record holding a token of another policy as well"
                            , atRequest
                                ( holding
                                    ( tokens
                                        <> [(statePolicy (crState world), configurationTokenName registry, 1)]
                                    )
                                    configuration
                                )
                            )
                        ,
                            ( "the record holding only a token of another policy"
                            , atRequest
                                ( holding
                                    [(statePolicy (crState world), configurationTokenName registry, 1)]
                                    configuration
                                )
                            )
                        , ("the record holding no token", atRequest (holding [] configuration))
                        ]
                    decodes out = isJust (appDecode application registry ["key one", "key two"] out)
                appIsConfiguration application configuration `shouldBe` True
                forM_ lookalikes $ \(name, out) ->
                    (name, appIsConfiguration application out) `shouldBe` (name, False)
                -- Decoding and configuration never claim the same output.
                forM_ (("the configuration record", configuration) : lookalikes) $ \(name, out) ->
                    (name, decodes out && appIsConfiguration application out)
                        `shouldBe` (name, False)
                map decodes live `shouldBe` [True, True]

        it "is still refused when it is named as a pending registration" $ do
            (world, registry, _) <- booked ["key one"]
            (ref, _) <- configurationOf world registry
            foldOutcome world registry [ref]
                `shouldReturn` Left (State.NotAPendingRegistration ref)

    describe "a batch of registrations" $ do
        it "is folded in one transaction that both validators accept" $ do
            (world, registry, pendings) <-
                booked ["key one", "key two", "key three"]
            tx <- folding world registry pendings
            judged <- judge world tx
            everyScriptAccepts judged `shouldBe` True
            purposesRun judged `shouldBe` [(Mint, 2), (Spend, 4)]

    describe "a batch of six registrations" $ do
        it
            "refuses the oversized named batch and folds all six through fitting public batches"
            $ do
                (world, registry, pendings) <-
                    booked ["key " <> BS.singleton n | n <- [1 .. 6]]
                named <- foldOutcome world registry pendings
                case named of
                    Left (State.CapacityExceeded (State.ExecutionMemory used limit)) -> used `shouldSatisfy` (> limit)
                    other -> expectationFailure (show other)
                let finish [] = pure []
                    finish remaining = do
                        tx <- folding world registry []
                        let chosen = map fst (foldedRequests tx)
                        chosen `shouldSatisfy` (not . null)
                        chosen `shouldSatisfy` all (`elem` remaining)
                        judged <- judge world tx
                        everyScriptAccepts judged `shouldBe` True
                        purposesRun judged `shouldBe` [(Mint, 2), (Spend, length chosen + 1)]
                        soundnessProblems world tx `shouldReturn` []
                        applyTx world tx
                        later <- finish (filter (`notElem` chosen) remaining)
                        pure (chosen <> later)
                finish pendings >>= (`shouldMatchList` pendings)

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
    foldOutcome world registry pendings >>= either (fail . show) pure

foldOutcome
    :: Creation
    -> RegistryIdentity
    -> [TxIn]
    -> IO (Either State.Refusal ConwayTx)
foldOutcome world registry pendings =
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

-- | The open datum application of a world's request validator.
applicationOf :: Creation -> IO Application
applicationOf world =
    withSession world $ \session ->
        openDatumApplication session (crRequest world) network
            >>= either (fail . show) pure

-- | The live output at a reference.
liveAt :: Creation -> TxIn -> IO (TxOut ConwayEra)
liveAt world ref = withSession world $ \session -> do
    answer <- outputs session (AtTxIn ref)
    case answer of
        Right (Evidenced [(_, out)] _) -> pure out
        _ -> fail ("not live: " <> show ref)

-- | The registry's configuration record, as the chain serves it.
configurationOf
    :: Creation -> RegistryIdentity -> IO (TxIn, TxOut ConwayEra)
configurationOf world registry = withSession world $ \session -> do
    found <-
        outputs
            session
            ( HoldingAsset
                (requestPolicy (crRequest world), configurationTokenName registry)
            )
    case found of
        Right (Evidenced [one] _) -> pure one
        _ -> fail "the creation did not leave a single configuration record"
