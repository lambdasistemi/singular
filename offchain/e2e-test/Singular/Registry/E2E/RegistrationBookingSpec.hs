{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.E2E.RegistrationBookingSpec
Description : A registration booked on a devnet, judged by the compiled validators
License     : Apache-2.0

One registry is booted on a devnet from the compiled blueprint, and one
registration is booked against it through the library's builder. The
validators that judge it are the compiled request policy and the compiled
open policy, not the library's own reading of them.

What the row shows, and what it does not:

* a booking built from the registry's authenticated state is accepted by the
  node, so the compiled request mint handler and the compiled open policy
  both accept it under the ledger's own presentation of the validity
  interval (the interval boundary the unit rows cannot reach);
* the same booking, with one thing changed after it was built and signed
  again, is refused by the node: one lovelace less in the request output, the
  upper end of the interval one slot later, the lower end far enough back to
  make the interval wider than the registry's widest (set to three seconds
  for this row, so that the devnet need not be old to reach it). Each refused
  submission leaves the funding output unspent, and the unchanged booking is
  submitted last and accepted, so the change, and nothing else, is what the
  node refused: the earlier submissions happened inside the same validity
  interval, so none of them can have been refused for having expired. The
  devnet converts slots to time only thirty slots past its tip, so the
  interval is short (2.7 seconds) and a round whose last submission is
  refused is made again from a fresh tip, at most three times;
* what the accepted booking left on chain is read back and compared with the
  registration it states: the value, both tags, and the datum.

It does not show that the node's refusal reason names the handler's refusal
(the reason text is recorded in the log, not asserted), nor anything about
spending or retracting the booked registration, nor behaviour under load.
-}
module Singular.Registry.E2E.RegistrationBookingSpec (spec) where

import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Sequence.Strict qualified as StrictSeq
import Lens.Micro ((%~), (&), (^.))
import PlutusCore.Data (Data (..))
import Test.Hspec

import Cardano.Ledger.Address (serialiseAddr)
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( ValidityInterval (..)
    , outputsTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , coinTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes
    ( Network (..)
    , SlotNo (..)
    , TxIx (..)
    )
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    )
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Node.Client.E2E.Setup
    ( genesisAddr
    , genesisSignKey
    )
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Blueprint
    ( Blueprint
    , NamingCodes (..)
    , extractCompiledCode
    , loadRegistryCodesFromEnv
    )
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Driver qualified as Driver
import Singular.Registry.E2E.CageSpec (withBootedCage)
import Singular.Registry.Ledger (Coin (..), ConwayEra)
import Singular.Registry.LedgerProvider
    ( SubmitResult (..)
    , observedSlot
    )
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.Signing (signTx, signedTx)
import Singular.Registry.TxBuilder.Internal
    ( cageAddrFromCfg
    , cagePolicyIdFromCfg
    , extractCageDatum
    , findStateUtxo
    , policyIdFromPin
    , requestAddrFromCfg
    )
import Singular.Registry.TxBuilder.RegistrationBooking
    ( RegistrationBooking (..)
    , bookRegistrationImpl
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRegistrationRequest (..)
    , applicationTagName
    , trieReadyTagName
    )

spec :: Blueprint -> Spec
spec bp = describe "Booking a registration" $
    case ( extractCompiledCode "state.state" bp
         , extractCompiledCode "request.request" bp
         , extractCompiledCode "open.open" bp
         ) of
        (Just stateBytes, Just requestBytes, Just _) ->
            bookingSpec stateBytes requestBytes
        _ ->
            it "the blueprint carries the compiled scripts" $
                expectationFailure
                    "state.state, request.request or open.open is not in \
                    \REGISTRY_BLUEPRINT"

bookingSpec :: SBS.ShortByteString -> SBS.ShortByteString -> Spec
bookingSpec stateBytes requestBytes =
    it
        "is accepted by the compiled validators, and refused by the node once its money or its clock is changed"
        $ withBootedCage widthOfThirtySlots stateBytes requestBytes
        $ \cfg prov submit _tm reg -> do
            codes <- loadRegistryCodesFromEnv
            let tokenId = Driver.registryTokenId reg
                stateAddr = cageAddrFromCfg cfg Testnet
                requestAddr = requestAddrFromCfg cfg tokenId Testnet
            stateUtxos <- Cage.withLatest prov (`Cage.outputsAt` stateAddr)
            stateRef <- case findStateUtxo (cagePolicyIdFromCfg cfg) tokenId stateUtxos of
                Just (ref, _) -> pure ref
                Nothing ->
                    expectationFailure
                        "no state output carrying the registry token"
                        >> fail "unreachable"
            let
                -- The interval is read from the node's own tip: two slots
                -- back and twenty-five ahead. The devnet converts slots to
                -- time only thirty slots (3 s) past its tip, so the upper
                -- end must stay inside that, and the whole booking has to
                -- be submitted within the 2.5 s the interval leaves.
                build = Cage.withLatest prov $ \view -> do
                    SlotNo now <- observedSlot <$> Cage.tip view
                    let lower = SlotNo (now - 2)
                        upper = SlotNo (now + 25)
                    tx <-
                        bookRegistrationImpl
                            cfg
                            view
                            tokenId
                            stateRef
                            (booking codes lower upper)
                            genesisAddr
                    ms <- Cage.slotStart view upper
                    pure (tx, ms)
                -- Three changes the compiled request policy must refuse.
                -- Each is made to the finished booking and signed again;
                -- none spends anything, because the node refuses it. The
                -- interval's upper end moves one slot, still inside the
                -- horizon and the registry's widest interval, and its lower
                -- end back ten slots, which makes the interval 3.7 seconds
                -- against the registry's widest, 3 seconds. The lower end is
                -- moved a few slots only: the devnet is seconds old, and a
                -- lower end cannot go before slot zero.
                refusals =
                    [
                        ( "one lovelace less in the request output"
                        , shortenRequestByOneLovelace
                        )
                    ,
                        ( "the interval's upper end one slot later"
                        , moveUpperEnd 1
                        )
                    ,
                        ( "the interval's lower end back past the registry's widest interval"
                        , moveLowerEnd (-10)
                        )
                    ]
                -- The unchanged booking is submitted last. If it is accepted
                -- every refusal before it happened inside its validity, so
                -- none of them can be an expiry. If it is refused (the
                -- interval ran out before the submission) the whole round is
                -- made again from a fresh tip, at most three times.
                attempt :: Int -> IO (ConwayTx, Integer)
                attempt n = do
                    (unsigned, upperMs) <- build
                    mapM_
                        ( \(what, change) -> do
                            result <- capSubmit submit (signTx genesisSignKey (change unsigned))
                            putStrLn
                                ("round " <> show n <> ", refusal [" <> what <> "]: " <> show result)
                            case result of
                                SubmitRefused _ -> pure ()
                                other ->
                                    expectationFailure
                                        ( "the node did not refuse the booking with "
                                            <> what
                                            <> ": "
                                            <> show other
                                        )
                        )
                        refusals
                    let signed = signTx genesisSignKey unsigned
                    result <- capSubmit submit signed
                    putStrLn
                        ("round " <> show n <> ", the unchanged booking: " <> show result)
                    case result of
                        SubmitAccepted _ -> do
                            capConfirm submit (signedTx signed)
                            pure (signedTx signed, upperMs)
                        other
                            | n < 3 -> attempt (n + 1)
                            | otherwise ->
                                expectationFailure
                                    ( "the node did not accept the unchanged booking in three rounds: "
                                        <> show other
                                    )
                                    >> fail "unreachable"
            (accepted, upperMs) <- attempt 1
            requestUtxos <- Cage.withLatest prov (`Cage.outputsAt` requestAddr)
            out <- case lookup (TxIn (txIdTx accepted) (TxIx 0)) requestUtxos of
                Just o -> pure o
                Nothing ->
                    expectationFailure
                        "the accepted booking left no output at the request address"
                        >> fail "unreachable"
            readBack cfg upperMs out

{- | The registry's widest interval for this row: three seconds, thirty
slots of the devnet. The booking's own interval is 2.7 seconds, inside it; a
lower end moved back ten slots makes it 3.7, outside it, on a devnet that is
only seconds old.
-}
widthOfThirtySlots :: CageConfig -> CageConfig
widthOfThirtySlots c = c{defaultBookingWidth = 3_000}

-- | The booking the row makes: its registry, key, destination and clock.
booking :: NamingCodes -> SlotNo -> SlotNo -> RegistrationBooking
booking codes lower upper =
    RegistrationBooking
        { rbKey = "e2e-booked-key"
        , rbRefundAddress = genesisAddr
        , rbDestination = serialiseAddr genesisAddr
        , rbDatum = Just (I 7)
        , rbDeclaredTip = Coin 1_500_000
        , rbCarrier = Coin 1_500_000
        , rbNonce = 1
        , rbLower = lower
        , rbUpper = upper
        , rbApplicationScript = ncApplication codes
        }

-- | Take one lovelace from the request output and give it to the change.
shortenRequestByOneLovelace :: ConwayTx -> ConwayTx
shortenRequestByOneLovelace tx =
    tx
        & bodyTxL . outputsTxBodyL %~ \outs ->
            case toList outs of
                request : middle@(_ : _) ->
                    StrictSeq.fromList
                        ( (request & coinTxOutL %~ plus (-1))
                            : init middle
                                <> [last middle & coinTxOutL %~ plus 1]
                        )
                _ -> outs
  where
    plus n (Coin c) = Coin (c + n)

-- | Move the interval's upper end by this many slots.
moveUpperEnd :: Integer -> ConwayTx -> ConwayTx
moveUpperEnd slots tx =
    tx
        & bodyTxL . vldtTxBodyL %~ \(ValidityInterval lower upper) ->
            ValidityInterval lower (fmap (shift slots) upper)

-- | Move the interval's lower end by this many slots.
moveLowerEnd :: Integer -> ConwayTx -> ConwayTx
moveLowerEnd slots tx =
    tx
        & bodyTxL . vldtTxBodyL %~ \(ValidityInterval lower upper) ->
            ValidityInterval (fmap (shift slots) lower) upper

shift :: Integer -> SlotNo -> SlotNo
shift n (SlotNo s) = SlotNo (fromInteger (max 0 (toInteger s + n)))

{- | What the accepted booking left at the request address, read from the
chain and compared with the registration its own datum states: the value is
the declared cost, tip and carrier; the two tags are exactly the names the
registration commits to, one under each policy; the booked time is the start
of the interval's upper slot.
-}
readBack :: CageConfig -> Integer -> TxOut ConwayEra -> Expectation
readBack cfg upperMs out = do
    request <- case extractCageDatum out of
        Just (RegistrationDatum r) -> pure r
        _ ->
            expectationFailure "the booked output carries no registration datum"
                >> fail "unreachable"
    let Coin cost = defaultRegistrationCost cfg
    -- what the datum states
    regKey request `shouldBe` "e2e-booked-key"
    regSubmittedAt request `shouldBe` upperMs
    regRegistrationCost request `shouldBe` cost
    regDeclaredTip request `shouldBe` 1_500_000
    regCarrierAda request `shouldBe` 1_500_000
    regNonce request `shouldBe` 1
    regDatum request `shouldBe` Just (I 7)
    -- what the output holds
    out ^. coinTxOutL `shouldBe` Coin (cost + 1_500_000 + 1_500_000)
    let MaryValue _ (MultiAsset assets) = out ^. valueTxOutL
        applicationName =
            applicationTagName
                (regKey request)
                (regRefundAddress request)
                (regDestination request)
                (regNonce request)
        trieName = trieReadyTagName request
    Map.map Map.toList assets
        `shouldBe` Map.fromList
            [
                ( policyIdFromPin (cfgRequestPolicy cfg)
                , [(AssetName (SBS.toShort trieName), 1)]
                )
            ,
                ( policyIdFromPin (cfgApplicationPolicy cfg)
                , [(AssetName (SBS.toShort applicationName), 1)]
                )
            ]
