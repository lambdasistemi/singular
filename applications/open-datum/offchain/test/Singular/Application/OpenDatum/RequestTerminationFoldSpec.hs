{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Singular.Application.OpenDatum.RequestTerminationFoldSpec
Description : Public termination folds and mixed batches under both compiled validators
License     : Apache-2.0

A holding is reached through creation, booking and folding. A hand-assembled
termination booking is judged by the compiled application validator and put
on the public chain. The shared builder must then fold it using only that
chain and a second wallet. The hand booking isolates fold construction from
the separately delivered donation-capable booking builder.
-}
module Singular.Application.OpenDatum.RequestTerminationFoldSpec (spec) where

import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldMatchList
    , shouldReturn
    , shouldSatisfy
    )

import Cardano.Crypto.DSIGN
    ( Ed25519DSIGN
    , SignKeyDSIGN
    , deriveVerKeyDSIGN
    , genKeyDSIGN
    )
import Cardano.Crypto.Hash (hashFromBytes)
import Cardano.Crypto.Seed (mkSeedFromBytes)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Alonzo.TxBody (scriptIntegrityHashTxBodyL)
import Cardano.Ledger.Alonzo.TxWits (Redeemers (..), TxDats (..))
import Cardano.Ledger.Api.Scripts.Data (Data (..))
import Cardano.Ledger.Api.Tx
    ( addrTxWitsL
    , mkBasicTx
    , txIdTx
    , witsTxL
    )
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , feeTxBodyL
    , inputsTxBodyL
    , mintTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    , reqSignerHashesTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (mkBasicTxOut)
import Cardano.Ledger.Api.Tx.Wits (rdmrsTxWitsL, scriptTxWitsL)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Conway.TxBody (treasuryDonationTxBodyL)
import Cardano.Ledger.Core (extractHash)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Keys
    ( KeyHash (..)
    , KeyRole (Payment)
    , VKey (..)
    , WitVKey (..)
    , asWitness
    , hashKey
    , verifySignedDSIGN
    )
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.Plutus.Language (Language (PlutusV3))
import Cardano.Ledger.TxIn (TxId (..), TxIn)
import Cardano.Tx.Balance (computeScriptIntegrity)
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Application.OpenDatum.CreationWorld
import Singular.Application.OpenDatum.RequestHoldingSpec
    ( withHoldingIn
    )
import Singular.Application.OpenDatum.RequestWorld
    ( expectBuilt
    , feeOf
    , inlineDatum
    , keyAddress
    , mintedOf
    , network
    , outputRef
    , signersOf
    , valueAda
    , withMint
    )
import Singular.Application.OpenDatum.Requests.Booking (Booking (..))
import Singular.Application.OpenDatum.Requests.Fold
    ( openDatumApplication
    )
import Singular.Application.OpenDatum.Requests.Script
    ( RequestScript (..)
    , requestAddress
    , requestPolicy
    , requestScriptHash
    )
import Singular.Registry.Ledger (ConwayEra, TxOut)
import Singular.Registry.LedgerProvider
    ( OutputQuery (..)
    , Session (..)
    )
import Singular.Registry.SessionIO qualified as Session
import Singular.Registry.Signing (signTx, signedTx)
import Singular.Registry.TrieState (RegistryIdentity)
import Singular.State.Assemble (Payer (..), resolvePayer)
import Singular.State.Fold (buildRegistrationFold)
import Singular.State.Preimage
    ( activeTokenName
    , approvalName
    , seedData
    , terminationPreimage
    )
import Singular.State.Script (statePolicy)

folderKey :: SignKeyDSIGN Ed25519DSIGN
folderKey = genKeyDSIGN (mkSeedFromBytes (BS.replicate 32 77))

folderAddress :: Addr
folderAddress =
    Addr
        network
        ( KeyHashObj
            (hashKey (VKey (deriveVerKeyDSIGN folderKey)) :: KeyHash Payment)
        )
        StakeRefNull

-- | Only the folder's private key exists in this fixture; the controller is a public address.
withTermination
    :: (Creation -> RegistryIdentity -> TxIn -> TxOut ConwayEra -> IO ())
    -> IO ()
withTermination action = withHoldingIn (newCreationFor (keyAddress 0x41) folderAddress) $ \world registry holding input -> do
    booked <- handTermination world registry holding input
    judged <- judge world booked
    judged `shouldSatisfy` everyScriptAccepts
    purposesRun judged `shouldBe` [(Mint, 1), (Spend, 1)]
    soundnessProblems world booked `shouldReturn` []
    request <-
        maybe (fail "no termination request") pure (outputAtIndex booked 0)
    applyTx world booked
    action world registry (outputRef booked 0) request

-- | A raw booking fixture, whose actual spend and mint are independently evaluated.
handTermination
    :: Creation -> RegistryIdentity -> TxIn -> TxOut ConwayEra -> IO ConwayTx
handTermination world registry holding input = withSession world $ \session -> do
    payer <- expectBuilt =<< resolvePayer session (crBooker world)
    pp <- Session.parameters session
    deposit <- case inlineDatum input of
        Just (PLC.Constr 2 [PLC.Constr 0 [_, _, _, _, PLC.I amount], _]) -> pure amount
        _ -> fail "the reached holding has no protected deposit"
    controller <-
        maybe
            (fail "bad controller hash")
            (pure . KeyHash)
            (hashFromBytes (controllerOf (crBooker world)))
    let (funding, fundingOutput) = payerFunding payer
        approval = approvalName (terminationPreimage "a live key" registry)
        active = activeTokenName registry "a live key"
        appPolicy = requestPolicy (crRequest world)
        appHash = requestScriptHash (crRequest world)
        minted = MultiAsset (Map.singleton appPolicy (Map.singleton approval 1))
        tokens =
            MultiAsset
                (Map.singleton (statePolicy (crState world)) (Map.singleton active 1))
                <> minted
        inputs = Set.fromList [funding, holding]
        requestValue = 3_000_000
        fee = 1_000_000
        change =
            valueAda fundingOutput + valueAda input - deposit - requestValue - fee
        redeemers =
            Redeemers
                ( Map.fromList
                    [
                        ( ConwayMinting (AsIx 0)
                        ,
                            ( Data (PLC.List [PLC.Constr 3 [seedData holding, PLC.I 0]])
                            , ExUnits 1_000_000 1_000_000_000
                            )
                        )
                    ,
                        ( ConwaySpending (AsIx (fromIntegral (Set.findIndex holding inputs)))
                        , (Data (PLC.Constr 4 [PLC.I 0]), ExUnits 1_000_000 1_000_000_000)
                        )
                    ]
                )
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ inputs
                & collateralInputsTxBodyL .~ Set.singleton funding
                & outputsTxBodyL
                    .~ StrictSeq.fromList
                        [ mkBasicTxOut
                            (requestAddress network (crRequest world))
                            (MaryValue (Coin requestValue) tokens)
                        , mkBasicTxOut (crBooker world) (MaryValue (Coin change) mempty)
                        ]
                & feeTxBodyL .~ Coin fee
                & treasuryDonationTxBodyL .~ Coin deposit
                & mintTxBodyL .~ minted
                & reqSignerHashesTxBodyL .~ Set.singleton controller
                & scriptIntegrityHashTxBodyL
                    .~ computeScriptIntegrity
                        (Set.singleton PlutusV3)
                        pp
                        redeemers
                        (TxDats mempty)
    pure
        ( mkBasicTx body
            & witsTxL . rdmrsTxWitsL .~ redeemers
            & witsTxL . scriptTxWitsL
                .~ Map.singleton appHash (rsScript (crRequest world))
        )

-- | Public data only: querying the controller's wallet is an immediate test failure.
folding :: Creation -> RegistryIdentity -> [TxIn] -> IO ConwayTx
folding world registry requests = withSession world $ \session -> do
    let public =
            session
                { outputs = \query ->
                    if asksController query
                        then fail "fold read the controller's wallet"
                        else outputs session query
                }
        asksController = \case
            AtAddress address -> address == crBooker world
            AnyOf queries -> any asksController (toList queries)
            AllOf queries -> any asksController (toList queries)
            _ -> False
    application <-
        expectBuilt =<< openDatumApplication public (crRequest world) network
    expectBuilt
        =<< buildRegistrationFold
            public
            (crState world)
            application
            registry
            requests
            (crFolder world)

spec :: Spec
spec = describe "termination folds from public data" $ do
    it
        "burns both tokens, pays the whole request to a second wallet and is signed only by that wallet"
        $ withTermination
        $ \world registry request held -> do
            funding <- withSession world $ \session -> expectBuilt =<< resolvePayer session (crFolder world)
            tx <- folding world registry [request]
            judge world tx >>= (`shouldSatisfy` everyScriptAccepts)
            mintedOf tx
                `shouldMatchList` [
                                      ( statePolicy (crState world)
                                      , activeTokenName registry "a live key"
                                      , -1
                                      )
                                  ,
                                      ( requestPolicy (crRequest world)
                                      , approvalName (terminationPreimage "a live key" registry)
                                      , -1
                                      )
                                  ]
            paidTo (crFolder world) tx
                `shouldBe` valueAda (snd (payerFunding funding)) + valueAda held - feeOf tx
            signersOf tx `shouldBe` []
            let signed = signedTx (signTx folderKey tx)
                TxId bodyHash = txIdTx signed
            case Set.toList (signed ^. witsTxL . addrTxWitsL) of
                [WitVKey signer signature] -> do
                    signer `shouldBe` asWitness (VKey (deriveVerKeyDSIGN folderKey))
                    verifySignedDSIGN signer (extractHash bodyHash) signature
                        `shouldBe` True
                _ -> fail "the fold did not have exactly the folder's signature"
            soundnessProblems world signed `shouldReturn` []

    it "mixes a termination with a registration of another key" $
        withTermination $ \world registry request _ -> do
            booking <-
                expectBuilt
                    =<< bookAs
                        world
                        ( Booking
                            registry
                            "another key"
                            (PLC.I 7)
                            (Coin 5_000_000)
                            (Coin 1_000_000)
                            (crBooker world)
                        )
            judge world booking >>= (`shouldSatisfy` everyScriptAccepts)
            applyTx world booking
            tx <- folding world registry [request, pendingOf world booking]
            judge world tx >>= (`shouldSatisfy` everyScriptAccepts)
            length (mintedOf tx) `shouldBe` 4
            soundnessProblems world tx `shouldReturn` []
            applyTx world tx
            -- A later fold must replay the termination as part of public history.
            next <-
                expectBuilt
                    =<< bookAs
                        world
                        ( Booking
                            registry
                            "later key"
                            (PLC.I 9)
                            (Coin 5_000_000)
                            (Coin 1_000_000)
                            (crBooker world)
                        )
            applyTx world next
            later <- folding world registry [pendingOf world next]
            judge world later >>= (`shouldSatisfy` everyScriptAccepts)

    it "refuses either missing burn beside a passing termination fold" $
        withTermination $ \world registry request _ -> do
            tx <- folding world registry [request]
            judge world tx >>= (`shouldSatisfy` everyScriptAccepts)
            let changes =
                    [ MultiAsset (Map.singleton policy (Map.singleton name amount))
                    | (policy, name, amount) <- mintedOf tx
                    ]
            forM_ changes $ \only -> judge world (withMint only tx) >>= (`shouldSatisfy` refusedBy)
