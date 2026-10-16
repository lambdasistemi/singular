{-# LANGUAGE LambdaCase #-}
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
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short (toShort)
import Data.Foldable (toList)
import Data.List (isInfixOf)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word32, Word64)
import Lens.Micro ((&), (.~), (^.))
import Test.Hspec

import Cardano.Crypto.DSIGN
    ( Ed25519DSIGN
    , SignKeyDSIGN
    , SignedDSIGN (..)
    , deriveVerKeyDSIGN
    , rawDeserialiseSignKeyDSIGN
    , rawSerialiseSigDSIGN
    , rawSerialiseVerKeyDSIGN
    )
import Cardano.Crypto.Hash (hashToBytes)
import Cardano.Ledger.Address (Addr (..))
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
    , collateralInputsTxBodyL
    , feeTxBodyL
    , inputsTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (TxOut, mkBasicTxOut)
import Cardano.Ledger.BaseTypes
    ( Network (Testnet)
    , SlotNo (..)
    , StrictMaybe (..)
    , TxIx (..)
    )
import Cardano.Ledger.Binary (serialize')
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (eraProtVerHigh, extractHash)
import Cardano.Ledger.Credential
    ( Credential (KeyHashObj, ScriptHashObj)
    , StakeReference (StakeRefNull)
    )
import Cardano.Ledger.Keys
    ( KeyHash
    , KeyRole (Guard, Witness)
    , VKey (..)
    , WitVKey (..)
    , hashKey
    , unKeyHash
    )
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Bundle
import Singular.Registry.BundleSpec (fixedKey, fixedSigner)
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Ledger (Coin (..), ConwayTxBody)
import Singular.Registry.LedgerProvider
    ( ChainPoint (..)
    , InclusionStatus (..)
    )
import Singular.Registry.Signing
    ( SignedTx
    , assembleSigned
    , detachedWitness
    , signTx
    , signedTx
    )
import Singular.Registry.Submit
    ( PlanStep (..)
    , SubmitRefusal (..)
    , matchWitnesses
    , neededKeys
    , planSubmission
    , renderSubmitRefusal
    )
import Singular.Registry.TxBuilder.Internal.Identity
    ( computeScriptHash
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
    describe "Pairing witnesses with bodies" $ do
        it "pairs each witness with the body its signature verifies over" $ do
            let bodies = chainedBodies 1000
                bundle = bundleOf bodies
                -- supplied in reverse body order: pairing cannot be by position
                witnesses =
                    reverse (map (detachedWitnessOf fixedKey) bodies)
                witnessesSecond =
                    reverse (map (detachedWitnessOf strangerKey) bodies)
            case matchWitnesses bundle (witnesses ++ witnessesSecond) of
                Left refusal ->
                    expectationFailure ("a sound witness was refused: " <> show refusal)
                Right paired -> do
                    -- every key is a body of the bundle, and each bucket is
                    -- exactly that body's own witnesses, nothing else
                    Map.keysSet paired `shouldBe` Set.fromList (map bodyIdentityOf bodies)
                    forM_ bodies $ \body ->
                        Map.findWithDefault [] (bodyIdentityOf body) paired
                            `shouldMatchList` [ detachedWitnessOf key body
                                              | key <- [fixedKey, strangerKey]
                                              ]
        it
            "refuses a witness that verifies against no body of the bundle, naming its public key"
            $ do
                let bodies = chainedBodies 1000
                    bundle = bundleOf bodies
                    foreignBody = mkBasicTx (syntheticBodyOf 2000) :: ConwayTx
                    foreignWitness = detachedWitnessOf fixedKey foreignBody
                case matchWitnesses bundle [foreignWitness] of
                    Left refusal@SubmitWitnessForeignBody{} -> do
                        renderSubmitRefusal refusal
                            `shouldSatisfy` isInfixOf (hexOf (verKeyOf fixedKey))
                        forM_ bodies $ \body ->
                            renderSubmitRefusal refusal
                                `shouldNotSatisfy` isInfixOf (hexOf (bodyIdentityOf body))
                    other ->
                        expectationFailure ("expected a foreign-body refusal: " <> show other)
    describe "The key hashes that need a witness" $ do
        it
            "needs each required signer and the payment key of every input and collateral output; a script credential adds nothing"
            $ do
                let signerWallet = walletOf fixedKey
                    inputWallet = walletOf strangerKey
                    collateralWallet = walletOf thirdKey
                    signer = signerHash fixedKey
                    input = funding 1
                    collateralInput = funding 2
                    -- three distinct keys, each present where the planner
                    -- must read it: the signer in the body's required set,
                    -- the input among the body's spent inputs, the
                    -- collateral among the body's collateral inputs
                    body =
                        mkBasicTx
                            ( spendingBody signerWallet [input] 1000
                                & reqSignerHashesTxBodyL .~ Set.singleton signer
                                & collateralInputsTxBodyL .~ Set.singleton collateralInput
                            )
                    resolved =
                        Map.fromList
                            [ (input, paymentOutput (walletAddr inputWallet))
                            , (collateralInput, paymentOutput (walletAddr collateralWallet))
                            ]
                case neededKeys (bundleOf [body]) resolved of
                    Left refusal ->
                        expectationFailure ("needed keys refused: " <> show refusal)
                    Right needed ->
                        Map.lookup (bodyIdentityOf body) needed
                            `shouldBe` Just
                                ( Set.fromList
                                    [ signerHashK signerWallet
                                    , signerHashK inputWallet
                                    , signerHashK collateralWallet
                                    ]
                                )
        it "adds no key for a script-credential output the body spends" $ do
            let wallet = walletOf fixedKey
                input = funding 1
                body = mkBasicTx (spendingBody wallet [input] 1000)
                resolved = Map.singleton input (scriptOutput 7)
            case neededKeys (bundleOf [body]) resolved of
                Left refusal ->
                    expectationFailure ("needed keys refused: " <> show refusal)
                Right needed ->
                    Map.lookup (bodyIdentityOf body) needed
                        `shouldBe` Just Set.empty
        it "needs the required signer alone when no input adds a key" $ do
            let signer = signerHash fixedKey
                body =
                    mkBasicTx
                        ( syntheticBodyOf 1000
                            & reqSignerHashesTxBodyL .~ Set.singleton signer
                        )
                        :: ConwayTx
            case neededKeys (bundleOf [body]) Map.empty of
                Left refusal ->
                    expectationFailure ("needed keys refused: " <> show refusal)
                Right needed ->
                    Map.lookup (bodyIdentityOf body) needed
                        `shouldBe` Just (Set.singleton (hashToBytes (unKeyHash signer)))
        it
            "needs the payment key of an input alone when no signer is required"
            $ do
                let inputWallet = walletOf strangerKey
                    body = mkBasicTx (spendingBody (walletOf fixedKey) [funding 1] 1000)
                    resolved = Map.singleton (funding 1) (paymentOutput (walletAddr inputWallet))
                case neededKeys (bundleOf [body]) resolved of
                    Left refusal ->
                        expectationFailure ("needed keys refused: " <> show refusal)
                    Right needed ->
                        Map.lookup (bodyIdentityOf body) needed
                            `shouldBe` Just (Set.singleton (signerHashK inputWallet))
        it "needs the payment key of a collateral input alone" $ do
            let collateralWallet = walletOf thirdKey
                body =
                    mkBasicTx
                        ( syntheticBodyOf 1000
                            & collateralInputsTxBodyL .~ Set.singleton (funding 2)
                        )
                        :: ConwayTx
                resolved =
                    Map.singleton
                        (funding 2)
                        (paymentOutput (walletAddr collateralWallet))
            case neededKeys (bundleOf [body]) resolved of
                Left refusal ->
                    expectationFailure ("needed keys refused: " <> show refusal)
                Right needed ->
                    Map.lookup (bodyIdentityOf body) needed
                        `shouldBe` Just (Set.singleton (signerHashK collateralWallet))
        it
            "reads an input produced by an earlier body of the bundle from that body"
            $ do
                let bodies = chainedBodies 1000
                    produced = outputsOfBodies [firstBody bodies]
                case soleInput (last bodies) of
                    Nothing ->
                        expectationFailure "the second body does not spend exactly one input"
                    Just secondInput -> case Map.lookup secondInput produced of
                        Nothing ->
                            expectationFailure "the earlier body does not produce the input"
                        Just out ->
                            -- the external map supplies every genuinely
                            -- external input; the second body's input
                            -- comes only from the earlier body's output
                            case neededKeys
                                (bundleOf bodies)
                                ( Map.union
                                    ( Map.fromList
                                        [ (funding n, paymentOutput (walletAddr (walletOf fixedKey)))
                                        | n <- [1 .. 6 :: Int]
                                        ]
                                    )
                                    (Map.singleton secondInput out)
                                ) of
                                Left refusal ->
                                    expectationFailure ("needed keys refused: " <> show refusal)
                                Right needed ->
                                    Map.lookup (bodyIdentityOf (last bodies)) needed
                                        `shouldBe` Just
                                            (Set.singleton (signerHashK (walletOf fixedKey)))
        it "refuses an input neither produced by an earlier body nor resolved" $ do
            let bodies = chainedBodies 1000
            case neededKeys (bundleOf bodies) Map.empty of
                Left refusal@SubmitInputUnresolved{} ->
                    renderSubmitRefusal refusal
                        `shouldSatisfy` isInfixOf (txInHex (funding 1))
                other ->
                    expectationFailure ("expected an unresolved input: " <> show other)
    describe "The plan of what to send" $ do
        it "sends the bundle's transactions in order when none is on chain" $ do
            let bodies = chainedBodies 1000
            case planOf bodies 0 of
                Left refusal ->
                    expectationFailure ("a sound bundle was refused: " <> show refusal)
                Right steps -> do
                    [stepAction step | step <- toList steps] `shouldBe` [Send, Send]
                    map stepIdentity steps
                        `shouldBe` map bodyIdentityOf bodies
        it "skips a transaction the chain already holds, by its identity" $ do
            let bodies = chainedBodies 1000
                point = At (SlotNo 9) (BC.replicate 32 '\1')
                statuses =
                    Map.fromList
                        [ (bodyIdentityOf (firstBody bodies), IncludedAt point 4)
                        , (bodyIdentityOf (last bodies), NotOnChain)
                        ]
            case planSubmission
                (bundleOf bodies)
                (witnessesDataOf bodies)
                (resolvedOf bodies)
                statuses
                100 of
                Left refusal ->
                    expectationFailure
                        ("a found transaction stopped the run: " <> show refusal)
                Right steps -> case toList steps of
                    [found, send] -> do
                        stepAction found `shouldBe` Found
                        stepFoundPoint found `shouldBe` Just (point, 4)
                        stepAction send `shouldBe` Send
                        stepIdentity send `shouldBe` bodyIdentityOf (last bodies)
                    other ->
                        expectationFailure
                            ("expected one found step and one send: " <> show other)
        it "plans only found steps when the chain holds every body" $ do
            let bodies = chainedBodies 1000
                statuses =
                    Map.fromList
                        [ (bodyIdentityOf b, IncludedAt (At (SlotNo 1) (BS.replicate 32 2)) 2)
                        | b <- bodies
                        ]
            case planSubmission
                (bundleOf bodies)
                (witnessesDataOf bodies)
                (resolvedOf bodies)
                statuses
                100 of
                Left refusal ->
                    expectationFailure
                        ("an all-found bundle was refused: " <> show refusal)
                Right steps -> do
                    [stepAction step | step <- toList steps] `shouldBe` [Found, Found]
                    map stepIdentity (toList steps) `shouldBe` map bodyIdentityOf bodies
        it
            "refuses an expired body with the word rebuild at and past the bound, never one slot before it"
            $ do
                let bodies = chainedBodies 1000
                    bound = 1000 :: Word64
                forM_ [(bound - 1, False), (bound, True), (bound + 1, True)] $
                    \(tip, expired) ->
                        case planOf bodies tip of
                            Left refusal@(SubmitBodyExpired _ readBound readTip) -> do
                                expired `shouldBe` True
                                readBound `shouldBe` bound
                                readTip `shouldBe` tip
                                renderSubmitRefusal refusal `shouldSatisfy` isInfixOf "rebuild"
                            other -> do
                                expired `shouldBe` False
                                case other of
                                    Left refusal ->
                                        expectationFailure
                                            ("refused before the bound: " <> show refusal)
                                    Right steps -> length steps `shouldBe` 2
        it "never refuses a body with no validity upper bound" $ do
            let wallet = walletOf fixedKey
                bodies =
                    [unboundedBody wallet (funding 1), unboundedBody wallet (funding 3)]
            case planSubmission
                (bundleOf bodies)
                (witnessesDataOf bodies)
                (resolvedOf bodies)
                (notOnChainOf bodies)
                (10 ^ (12 :: Int)) of
                Left refusal ->
                    expectationFailure ("an unbounded body was refused: " <> show refusal)
                Right steps -> do
                    [stepAction step | step <- toList steps] `shouldBe` [Send, Send]
                    map stepIdentity (toList steps) `shouldBe` map bodyIdentityOf bodies
        it "refuses a missing witness as incomplete, before any send" $ do
            let bodies = chainedBodies 1000
                firstWitnesses = [detachedWitnessOf fixedKey (firstBody bodies)]
            case planSubmission
                (bundleOf bodies)
                firstWitnesses
                (resolvedOf bodies)
                (notOnChainOf bodies)
                0 of
                Left refusal@(SubmitWitnessMissing keyHash identity) -> do
                    keyHash `shouldBe` signerHashK (walletOf fixedKey)
                    identity `shouldBe` bodyIdentityOf (last bodies)
                    renderSubmitRefusal refusal
                        `shouldSatisfy` isInfixOf "needs a witness"
                other ->
                    expectationFailure ("expected a missing witness: " <> show other)
        it "refuses a single valid witness for a key no transaction needs" $ do
            let bodies = chainedBodies 1000
                -- only the stranger's witness, and no other: an
                -- implementation that refuses only duplicates fails here
                strangerWitness = detachedWitnessOf strangerKey (firstBody bodies)
            case planSubmission
                (bundleOf bodies)
                [strangerWitness]
                (resolvedOf bodies)
                (notOnChainOf bodies)
                0 of
                Left refusal@(SubmitWitnessUnneededKey keyHash) -> do
                    keyHash `shouldBe` signerHashK (walletOf strangerKey)
                    renderSubmitRefusal refusal
                        `shouldSatisfy` isInfixOf "needs no witness"
                other ->
                    expectationFailure ("expected an unneeded key: " <> show other)
        it "refuses a duplicate of a needed witness as its own refusal" $ do
            let bodies = chainedBodies 1000
                witness = detachedWitnessOf fixedKey (firstBody bodies)
                duplicates = [witness, witness]
            case planSubmission
                (bundleOf bodies)
                duplicates
                (resolvedOf bodies)
                (notOnChainOf bodies)
                0 of
                Left refusal@SubmitWitnessUnneededKey{} ->
                    renderSubmitRefusal refusal
                        `shouldSatisfy` isInfixOf "needs no witness"
                other ->
                    expectationFailure
                        ("expected the duplicate to be refused: " <> show other)
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

-- | A third deterministic key, distinct from the two above.
thirdKey :: SignKeyDSIGN Ed25519DSIGN
thirdKey =
    fromMaybe
        (error "the third key's bytes do not decode")
        (rawDeserialiseSignKeyDSIGN (BC.pack (replicate 31 't' <> "k")))

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
{-# NOINLINE twoSignerBody #-}
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

{- | The bundle the rows plan: the bodies in order with the fixture's
signer.
-}
bundleOf :: [ConwayTx] -> Bundle
bundleOf bodies =
    Bundle
        { bundleCommand = "singular registry fold"
        , bundleNetworkMagic = magic
        , bundleStateToken = Nothing
        , bundleSigners = fixedSigner :| []
        , bundleTransactions =
            fromMaybe (error "a bundle needs transactions") (nonEmptyOf entries)
        }
  where
    entries =
        [ BundleTransaction
            { bundleTxIdentity = bodyIdentityOf body
            , bundleTxEnvelope = transactionEnvelope body
            , bundleTxDeadline = deadlineOf body
            , bundleTxEffects =
                ["claims to move " <> hexOf' (bodyIdentityOf body) <> "'s funds"]
            }
        | body <- bodies
        ]

deadlineOf :: ConwayTx -> Maybe Word64
deadlineOf tx = case tx ^. bodyTxL . vldtTxBodyL of
    ValidityInterval _ (SJust (SlotNo n)) -> Just n
    ValidityInterval _ SNothing -> Nothing

unboundedBody :: Wallet -> TxIn -> ConwayTx
unboundedBody wallet input =
    mkBasicTx
        ( spendingBody wallet [input] 1000
            & vldtTxBodyL
                .~ ValidityInterval SNothing SNothing
        )

syntheticBodyOf :: Word64 -> ConwayTxBody
syntheticBodyOf bound =
    mkBasicTxBody
        & vldtTxBodyL .~ ValidityInterval SNothing (SJust (SlotNo bound))

witnessesDataOf :: [ConwayTx] -> [DetachedWitness]
witnessesDataOf bodies =
    [detachedWitnessOf fixedKey body | body <- bodies]

detachedWitnessOf
    :: SignKeyDSIGN Ed25519DSIGN -> ConwayTx -> DetachedWitness
detachedWitnessOf = witnessDataOfRaw

witnessDataOfRaw
    :: SignKeyDSIGN Ed25519DSIGN -> ConwayTx -> DetachedWitness
witnessDataOfRaw key tx = witnessDataOf (detachedWitness key tx)

witnessDataOf :: WitVKey Witness -> DetachedWitness
witnessDataOf (WitVKey (VKey verKey) (SignedDSIGN sig)) =
    DetachedWitness
        { detachedKeyBytes = rawSerialiseVerKeyDSIGN verKey
        , detachedSignatureBytes = rawSerialiseSigDSIGN sig
        }

outputsOfBodies :: [ConwayTx] -> Map TxIn (TxOut ConwayEra)
outputsOfBodies bodies =
    Map.fromList
        [ (TxIn (txIdTx body) (TxIx (fromIntegral ix)), out)
        | body <- bodies
        , (ix, out) <-
            zip [0 :: Int ..] (toList (body ^. bodyTxL . outputsTxBodyL))
        ]

{- | The resolver a sound caller supplies: every genuinely external
input (the funding the chain holds) beside the outputs the bundle's
own earlier bodies produce.
-}
resolvedOf :: [ConwayTx] -> Map TxIn (TxOut ConwayEra)
resolvedOf bodies =
    Map.union
        ( Map.fromList
            [ (funding n, paymentOutput (walletAddr (walletOf fixedKey)))
            | n <- [1 .. 6 :: Int]
            ]
        )
        (outputsOfBodies bodies)

notOnChainOf :: [ConwayTx] -> Map ByteString InclusionStatus
notOnChainOf bodies =
    Map.fromList [(bodyIdentityOf body, NotOnChain) | body <- bodies]

planOf :: [ConwayTx] -> Word64 -> Either SubmitRefusal [PlanStep]
planOf bodies tip =
    fmap
        toList
        ( planSubmission
            (bundleOf bodies)
            (witnessesDataOf bodies)
            (resolvedOf bodies)
            (notOnChainOf bodies)
            tip
        )

soleInput :: ConwayTx -> Maybe TxIn
soleInput body = case Set.toList (body ^. bodyTxL . inputsTxBodyL) of
    [i] -> Just i
    _ -> Nothing

-- | Which action a step names.
data StepAction = Send | Found
    deriving stock (Eq, Show)

stepAction :: PlanStep -> StepAction
stepAction = \case
    PlanSend{} -> Send
    PlanFound{} -> Found

stepIdentity :: PlanStep -> ByteString
stepIdentity = \case
    PlanSend t _ _ -> bundleTxIdentity t
    PlanFound t _ _ -> bundleTxIdentity t

stepFoundPoint :: PlanStep -> Maybe (ChainPoint, Word64)
stepFoundPoint = \case
    PlanFound _ point confirmations -> Just (point, confirmations)
    PlanSend{} -> Nothing

bodyIdentityOf :: ConwayTx -> ByteString
bodyIdentityOf = bodyIdentity

-- | A script-locked output, whose credential adds nothing to the keys.
scriptOutput :: Int -> TxOut ConwayEra
scriptOutput seed =
    mkBasicTxOut
        (scriptLockedAddress seed)
        (MaryValue (Coin 2_000_000_000) mempty)

scriptLockedAddress :: Int -> Addr
scriptLockedAddress seed =
    Addr
        Testnet
        ( ScriptHashObj
            (computeScriptHash (toShort (BC.pack ("script" <> show seed))))
        )
        StakeRefNull

-- | The payment key hash a wallet's address carries.
signerHashK :: Wallet -> ByteString
signerHashK wallet = case walletAddr wallet of
    Addr _ (KeyHashObj hash) _ -> hashToBytes (unKeyHash hash)
    other -> error ("not a key address: " <> show other)

txInHex :: TxIn -> String
txInHex (TxIn key _) = hexOf (txIdToBytes key)

txIdToBytes :: TxId -> ByteString
txIdToBytes (TxId h) = hashToBytes (extractHash h)

hexOf :: ByteString -> String
hexOf = BC.unpack . B16.encode

hexOf' :: ByteString -> Text
hexOf' = TE.decodeUtf8 . B16.encode

nonEmptyOf :: [a] -> Maybe (NonEmpty a)
nonEmptyOf [] = Nothing
nonEmptyOf (x : xs) = Just (x :| xs)

{- | The first of a non-empty list of bodies, spelled for the rows that
name it.
-}
firstBody :: [ConwayTx] -> ConwayTx
firstBody (b : _) = b
firstBody [] = error "the chained fixture did not build its bodies"
