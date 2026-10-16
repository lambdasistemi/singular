{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Singular.Registry.SubmitSpec
Description : Submitting a signed bundle without sending anything twice
License     : Apache-2.0

The proofs of @singular submit@, one row per promise it makes to the
signer who hands back the witnesses. This slice holds the assembly
promise: the assembled signed transaction keeps the bundle's body bytes
and identity and adds exactly the verified witnesses. The witness
pairing, the needed keys, the plan and the command rows arrive with
their own slices.

Every expected value is obtained at run time from the producer: the
identities from the ledger's own transaction ids, the witnesses from
the signer's own key. The fixture is the synthetic raw chain; the
packaged offline refusals and the devnet rows live in the controls and
the end-to-end lane.
-}
module Singular.Registry.SubmitSpec (spec) where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Maybe (fromMaybe)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Word (Word32, Word64)
import Lens.Micro ((&), (.~), (^.))
import Test.Hspec

import Cardano.Crypto.DSIGN
    ( Ed25519DSIGN
    , SignKeyDSIGN
    , deriveVerKeyDSIGN
    , rawDeserialiseSignKeyDSIGN
    , rawSerialiseVerKeyDSIGN
    )
import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Alonzo.TxBody (reqSignerHashesTxBodyL)
import Cardano.Ledger.Api.Tx
    ( addrTxWitsL
    , bodyTxL
    , mkBasicTx
    , txIdTx
    , witsTxL
    )
import Cardano.Ledger.Api.Tx.Body
    ( ValidityInterval (..)
    , feeTxBodyL
    , inputsTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (TxOut, mkBasicTxOut)
import Cardano.Ledger.BaseTypes
    ( SlotNo (..)
    , StrictMaybe (..)
    , TxIx (..)
    )
import Cardano.Ledger.Binary (serialize')
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (eraProtVerHigh)
import Cardano.Ledger.Keys
    ( KeyHash
    , KeyRole (Guard, Witness)
    , VKey (..)
    , WitVKey (..)
    , hashKey
    )
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.BundleSpec (fixedKey)
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Ledger (Coin (..), ConwayTxBody)
import Singular.Registry.Signing
    ( SignedTx
    , assembleSigned
    , detachedWitness
    , signTx
    , signedTx
    )
import Singular.Registry.Wallet
    ( Wallet (..)
    , walletAddr
    , walletFromSignKey
    )

magic :: Word32
magic = 42

spec :: Spec
spec = do
    describe "Assembling the signed transaction" $ do
        it
            "carries every verified witness of a body needing two keys, and only those"
            $ do
                let body = twoSignerBody
                    firstWitness = keyWitnessOf fixedKey body
                    secondWitness = keyWitnessOf strangerKey body
                    sealed = assembleSigned body [firstWitness, secondWitness]
                    added = witnessKeysOf sealed
                length added `shouldBe` 2
                added `shouldContain` [verKeyOf fixedKey]
                added `shouldContain` [verKeyOf strangerKey]
                -- the witnesses are exactly the two given, each over this body
                Set.toList (signedTx sealed ^. witsTxL . addrTxWitsL)
                    `shouldContain` [detachedWitness fixedKey body]
                Set.toList (signedTx sealed ^. witsTxL . addrTxWitsL)
                    `shouldContain` [detachedWitness strangerKey body]
        it
            "replaces, not keeps, the key witnesses the envelope already carries"
            $ do
                let body = twoSignerBody
                    -- an envelope that already holds a witness nobody
                    -- supplied for the assembly: another signer's
                    preWitnessed = signedTx (signTx strangerKey body)
                    sealed = assembleSigned preWitnessed [keyWitnessOf fixedKey body]
                witnessKeysOf sealed `shouldBe` [verKeyOf fixedKey]
                witnessKeysOf sealed `shouldNotContain` [verKeyOf strangerKey]
                txIdTx (signedTx sealed) `shouldBe` txIdTx preWitnessed
                serialize' (eraProtVerHigh @ConwayEra) (signedTx sealed ^. bodyTxL)
                    `shouldBe` serialize' (eraProtVerHigh @ConwayEra) (preWitnessed ^. bodyTxL)
        it "keeps each body's own witnesses apart across the bundle" $ do
            let bodies = chainedBodies 1000
            case bodies of
                [first, second] -> do
                    let sealedFirst =
                            assembleSigned first [keyWitnessOf fixedKey first]
                        sealedSecond =
                            assembleSigned second [keyWitnessOf strangerKey second]
                    witnessKeysOf sealedFirst `shouldBe` [verKeyOf fixedKey]
                    witnessKeysOf sealedSecond `shouldBe` [verKeyOf strangerKey]
                    witnessKeysOf sealedFirst `shouldNotContain` [verKeyOf strangerKey]
                    witnessKeysOf sealedSecond `shouldNotContain` [verKeyOf fixedKey]
                    txIdTx (signedTx sealedFirst) `shouldBe` txIdTx first
                    txIdTx (signedTx sealedSecond) `shouldBe` txIdTx second
                _ -> expectationFailure "the chained fixture did not build two bodies"
        it
            "keeps the bundle's body bytes and identity, adding exactly the witnesses"
            $ do
                let bodies = chainedBodies 1000
                    witnesses = map (keyWitnessOf fixedKey) bodies
                case (bodies, witnesses) of
                    (first : _, firstWitness : _) -> do
                        let sealed = assembleSigned first [firstWitness]
                            tx = signedTx sealed
                        txIdTx tx `shouldBe` txIdTx first
                        serialize' (eraProtVerHigh @ConwayEra) (tx ^. bodyTxL)
                            `shouldBe` serialize' (eraProtVerHigh @ConwayEra) (first ^. bodyTxL)
                        let added = Set.toList (tx ^. witsTxL . addrTxWitsL)
                        length added `shouldBe` 1
                        forM_ added $ \witness -> do
                            witness `shouldBe` detachedWitness fixedKey first
                            verKeyBytes witness
                                `shouldBe` rawSerialiseVerKeyDSIGN (deriveVerKeyDSIGN fixedKey)
                    _ -> expectationFailure "the fixture bundle signed no witnesses"
        it "assembles each body of the bundle with its own witnesses" $ do
            let bodies = chainedBodies 1000
                sealed =
                    [ assembleSigned body [keyWitnessOf fixedKey body]
                    | body <- bodies
                    ]
            map (txIdTx . signedTx) sealed `shouldBe` map txIdTx bodies

-- ---------------------------------------------------------
-- Bundles and bodies
-- ---------------------------------------------------------

{- | The bodies the rows assemble: two chained transactions, the second
spending the first's only output, each requiring the wallet's signature
and bounded by the slot given.
-}
chainedBodies :: Word64 -> [ConwayTx]
chainedBodies bound =
    let wallet = walletOf fixedKey
        first = mkBasicTx (spendingBody wallet [funding 1] bound) :: ConwayTx
        second =
            mkBasicTx
                (spendingBody wallet [TxIn (txIdTx first) (TxIx 0)] bound)
                :: ConwayTx
    in  [first, second]

spendingBody :: Wallet -> [TxIn] -> Word64 -> ConwayTxBody
spendingBody wallet spent upper =
    mkBasicTxBody
        & inputsTxBodyL .~ Set.fromList spent
        & outputsTxBodyL
            .~ StrictSeq.singleton (paymentOutput (walletAddr wallet))
        & feeTxBodyL .~ Coin 1_000_000
        & vldtTxBodyL .~ ValidityInterval SNothing (SJust (SlotNo upper))

-- ---------------------------------------------------------
-- Keys, addresses and outputs
-- ---------------------------------------------------------

walletOf :: SignKeyDSIGN Ed25519DSIGN -> Wallet
walletOf = walletFromSignKey magic

-- | A second deterministic key, distinct from the fixture's own.
strangerKey :: SignKeyDSIGN Ed25519DSIGN
strangerKey =
    fromMaybe
        (error "the stranger key's bytes do not decode")
        (rawDeserialiseSignKeyDSIGN (BC.pack (replicate 31 's' <> "k")))

{- | A body requiring two different payment keys as its signers: its
assembly must carry one verified witness from each, and only those.
-}
twoSignerBody :: ConwayTx
twoSignerBody =
    mkBasicTx
        ( spendingBody (walletOf fixedKey) [funding 1] 1000
            & reqSignerHashesTxBodyL
                .~ Set.fromList [signerHash fixedKey, signerHash strangerKey]
        )

signerHash :: SignKeyDSIGN Ed25519DSIGN -> KeyHash Guard
signerHash key = hashKey (VKey (deriveVerKeyDSIGN key))

verKeyOf :: SignKeyDSIGN Ed25519DSIGN -> ByteString
verKeyOf = rawSerialiseVerKeyDSIGN . deriveVerKeyDSIGN

witnessKeysOf :: SignedTx -> [ByteString]
witnessKeysOf sealed =
    map
        verKeyBytes
        (Set.toList (signedTx sealed ^. witsTxL . addrTxWitsL))

paymentOutput :: Addr -> TxOut ConwayEra
paymentOutput address = mkBasicTxOut address (MaryValue (Coin 2_000_000_000) mempty)

funding :: Int -> TxIn
funding n =
    either
        (error . ("funding: " <>))
        id
        (parseOutRef (T.pack (replicate 63 'f' <> show n <> "#0")))

{- | The key witness the signer's detached witness carries, reconstructed
from its own signing key — the value the assembly boundary accepts.
-}
keyWitnessOf
    :: SignKeyDSIGN Ed25519DSIGN -> ConwayTx -> WitVKey Witness
keyWitnessOf = detachedWitness

verKeyBytes :: WitVKey Witness -> ByteString
verKeyBytes (WitVKey (VKey verKey) _) = rawSerialiseVerKeyDSIGN verKey
