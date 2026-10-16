{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.Submit
Description : The pure planner that decides how a signed bundle is submitted
License     : Apache-2.0

The decisions of @singular submit@, all pure: which witness belongs to
which body (by verifying its signature over that body's identity, never
by its file name), which key hashes each transaction needs a witness
for (its required signers and the payment key hashes of its inputs and
collateral; a script credential adds nothing), and — given where the
chain holds each transaction and the tip — the ordered plan of what to
send and what to skip. Every refusal names what it concerns and no
secret. The module reads no file, no clock and no chain: those belong
to the command that calls it.
-}
module Singular.Registry.Submit
    ( SubmitRefusal (..)
    , renderSubmitRefusal
    , PlanStep (..)
    , neededKeys
    , matchWitnesses
    , planSubmission
    ) where

import Cardano.Crypto.DSIGN
    ( Ed25519DSIGN
    , SigDSIGN
    , VerKeyDSIGN
    , rawDeserialiseSigDSIGN
    , rawDeserialiseVerKeyDSIGN
    , verifyDSIGN
    )
import Cardano.Crypto.Hash (hashToBytes)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body
    ( ValidityInterval (..)
    , collateralInputsTxBodyL
    , inputsTxBodyL
    , reqSignerHashesTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (TxOut, addrTxOutL)
import Cardano.Ledger.BaseTypes (SlotNo (..), StrictMaybe (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (extractHash)
import Cardano.Ledger.Credential (Credential (KeyHashObj))
import Cardano.Ledger.Keys (VKey (..), hashKey, unKeyHash)
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import Control.Monad (foldM, forM, forM_)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Word (Word64)
import Lens.Micro ((^.))

import Singular.Registry.Bundle
import Singular.Registry.LedgerProvider
    ( ChainPoint (..)
    , InclusionStatus (..)
    )

-- | Why submitting a bundle was refused. None names a passphrase or a key.
data SubmitRefusal
    = -- | the bundle itself, refused by the signing step's own checks
      SubmitBundleRefused BundleRefusal
    | {- | a witness that verifies against no body of the bundle, carrying
      its public key
      -}
      SubmitWitnessForeignBody ByteString
    | -- | a witness for a key hash no transaction needs, carrying the key hash
      SubmitWitnessUnneededKey ByteString
    | {- | a key hash a transaction needs and no witness covers, carrying
      the key hash and the body's identity
      -}
      SubmitWitnessMissing ByteString ByteString
    | {- | a transaction not on the chain whose validity upper bound is at
      or before the tip slot, carrying its identity, the bound and the tip:
      rebuild the bundle
      -}
      SubmitBodyExpired ByteString Word64 Word64
    | -- | an input neither produced by an earlier body nor on the chain
      SubmitInputUnresolved TxIn
    deriving stock (Eq, Show)

-- | One line naming the refusal, carrying what it concerns and no secret.
renderSubmitRefusal :: SubmitRefusal -> String
renderSubmitRefusal = \case
    SubmitBundleRefused refusal -> renderBundleRefusal refusal
    SubmitWitnessForeignBody key ->
        "the witness carrying the public key "
            <> hexOf key
            <> " verifies against no transaction of the bundle"
    SubmitWitnessUnneededKey keyHash ->
        "the key hash "
            <> hexOf keyHash
            <> " needs no witness: no transaction of the bundle spends from it \
               \or names it as a required signer"
    SubmitWitnessMissing keyHash identity ->
        "the transaction "
            <> hexOf identity
            <> " needs a witness for the key hash "
            <> hexOf keyHash
            <> " and none was given"
    SubmitBodyExpired identity bound tip ->
        "the transaction "
            <> hexOf identity
            <> " is not on the chain and its validity upper bound "
            <> show bound
            <> " is at or before the tip slot "
            <> show tip
            <> ": rebuild the bundle"
    SubmitInputUnresolved reference ->
        "the input "
            <> renderTxIn reference
            <> " is produced by no earlier transaction of the bundle and is \
               \not on the chain"

{- | One step of the plan, in the bundle's order: send the body with
exactly its verified witnesses, or skip a transaction the chain already
holds.
-}
data PlanStep
    = -- | the body to send, its decoded transaction and verified witnesses
      PlanSend BundleTransaction ConwayTx [DetachedWitness]
    | {- | a transaction the chain holds, with its chain point and
      confirmations: not sent again
      -}
      PlanFound BundleTransaction ChainPoint Word64
    deriving stock (Eq, Show)

{- | The key hashes each transaction needs a witness for: its required
signers plus the payment key hashes of its input and collateral outputs.
A script credential adds nothing. Pure.
-}
neededKeys
    :: Bundle
    -> Map TxIn (TxOut ConwayEra)
    -> Either SubmitRefusal (Map ByteString (Set ByteString))
neededKeys bundle resolved = do
    entries <- forM (toList (bundleTransactions bundle)) $ \transaction -> do
        body <-
            first
                (bundleProblem transaction)
                (decodeTransactionEnvelope (bundleTxEnvelope transaction))
        spent <-
            mapM
                resolvedOutput
                ( Set.toList
                    ( body ^. bodyTxL . inputsTxBodyL
                        <> body ^. bodyTxL . collateralInputsTxBodyL
                    )
                )
        let signers =
                Set.fromList
                    [ hashToBytes (unKeyHash hash)
                    | hash <- toList (body ^. bodyTxL . reqSignerHashesTxBodyL)
                    ]
            payments =
                Set.fromList
                    [keyHash | out <- spent, Just keyHash <- [paymentKeyHashOf out]]
        pure (bundleTxIdentity transaction, Set.union signers payments)
    pure (Map.fromList entries)
  where
    resolvedOutput reference =
        case Map.lookup reference resolved of
            Nothing -> Left (SubmitInputUnresolved reference)
            Just out -> Right out
    paymentKeyHashOf out = case out ^. addrTxOutL of
        Addr _ (KeyHashObj hash) _ -> Just (hashToBytes (unKeyHash hash))
        _ -> Nothing
    bundleProblem transaction _ =
        SubmitBundleRefused
            ( BundleEnvelopeUndecodable
                (BC.unpack (B16.encode (bundleTxIdentity transaction)))
            )

{- | Each witness paired with the body it verifies against, by verifying
its signature over that body's identity — never by its file name. A
witness that verifies against no body is refused. Pure.
-}
matchWitnesses
    :: Bundle
    -> [DetachedWitness]
    -> Either SubmitRefusal (Map ByteString [DetachedWitness])
matchWitnesses bundle witnesses = do
    paired <-
        forM witnesses $ \witness ->
            case [ transaction
                 | transaction <- toList (bundleTransactions bundle)
                 , witnessVerifies witness transaction
                 ] of
                [transaction] -> Right (bundleTxIdentity transaction, [witness])
                _ -> Left (SubmitWitnessForeignBody (detachedKeyBytes witness))
    pure (Map.fromListWith (flip (++)) paired)

{- | The ordered plan: which transactions to send, with exactly their
verified witnesses, and which the chain already holds. Every check
first: a foreign witness, an unneeded or missing one, an unresolved
input, and an expired body are refused before the first send. Pure.
-}
planSubmission
    :: Bundle
    -> [DetachedWitness]
    -> Map TxIn (TxOut ConwayEra)
    -> Map ByteString InclusionStatus
    -> Word64
    -> Either SubmitRefusal (NonEmpty PlanStep)
planSubmission bundle witnesses resolved statuses tip = do
    let transactions = toList (bundleTransactions bundle)
    paired <- matchWitnesses bundle witnesses
    needed <- neededKeys bundle resolved
    -- every witness is for a key its transaction needs, and no key is
    -- witnessed twice: a second witness for a covered key is unneeded,
    -- whoever signed it — this fires before the missing check, so a lone
    -- stranger witness is refused as unneeded, not as an incomplete set
    forM_ (Map.toList paired) $ \(identity, ws) -> do
        let keysOfTx = Map.findWithDefault Set.empty identity needed
        _ <-
            foldM
                ( \covered witness ->
                    if Set.member (witnessKeyHash witness) keysOfTx
                        then
                            if Set.member (witnessKeyHash witness) covered
                                then Left (SubmitWitnessUnneededKey (witnessKeyHash witness))
                                else Right (Set.insert (witnessKeyHash witness) covered)
                        else Left (SubmitWitnessUnneededKey (witnessKeyHash witness))
                )
                Set.empty
                ws
        pure ()
    -- every key a transaction needs has a verified witness
    forM_ (Map.toList needed) $ \(identity, keys) ->
        forM_ (Set.toList keys) $ \keyHash ->
            case Map.findWithDefault [] identity paired of
                matching
                    | any (coversKey keyHash) matching -> pure ()
                    | otherwise -> Left (SubmitWitnessMissing keyHash identity)
    -- an expired body: not on the chain and the tip at or past its
    -- exclusive upper bound; one the chain holds never expires
    forM_ transactions $ \transaction -> do
        body <- decoded transaction
        case ( Map.lookup (bundleTxIdentity transaction) statuses
             , upperBoundOf body
             ) of
            (Just IncludedAt{}, _) -> pure ()
            (Just NotOnChain, Just bound)
                | tip >= bound ->
                    Left (SubmitBodyExpired (bundleTxIdentity transaction) bound tip)
            _ -> pure ()
    -- the ordered plan
    steps <-
        forM transactions $ \transaction -> do
            body <- decoded transaction
            case Map.lookup (bundleTxIdentity transaction) statuses of
                Just (IncludedAt point confirmations) ->
                    pure (PlanFound transaction point confirmations)
                _ ->
                    pure
                        ( PlanSend
                            transaction
                            body
                            (Map.findWithDefault [] (bundleTxIdentity transaction) paired)
                        )
    case steps of
        [] -> Left (SubmitBundleRefused (BundleField "transactions" "is empty"))
        (firstStep : restSteps) -> Right (firstStep :| restSteps)
  where
    decoded transaction =
        first
            ( \_ ->
                SubmitBundleRefused
                    ( BundleEnvelopeUndecodable
                        (BC.unpack (B16.encode (bundleTxIdentity transaction)))
                    )
            )
            (decodeTransactionEnvelope (bundleTxEnvelope transaction))

-- | Whether a detached witness carries the key a hash names.
coversKey :: ByteString -> DetachedWitness -> Bool
coversKey keyHash witness = witnessKeyHash witness == keyHash

{- | The payment key hash a detached witness's key carries, derived
through the ledger's own key hashing so it is the hash an address
names.
-}
witnessKeyHash :: DetachedWitness -> ByteString
witnessKeyHash witness =
    case rawDeserialiseVerKeyDSIGN (detachedKeyBytes witness) of
        Just verKey -> hashToBytes (unKeyHash (hashKey (VKey verKey)))
        Nothing -> ""

-- | A body's exclusive validity upper bound, when it has one.
upperBoundOf :: ConwayTx -> Maybe Word64
upperBoundOf body = case body ^. bodyTxL . vldtTxBodyL of
    ValidityInterval _ (SJust (SlotNo n)) -> Just n
    ValidityInterval _ SNothing -> Nothing

{- | Whether a detached witness's signature verifies over the body's
identity.
-}
witnessVerifies :: DetachedWitness -> BundleTransaction -> Bool
witnessVerifies witness transaction =
    case ( rawDeserialiseVerKeyDSIGN (detachedKeyBytes witness)
            :: Maybe (VerKeyDSIGN Ed25519DSIGN)
         , rawDeserialiseSigDSIGN (detachedSignatureBytes witness)
            :: Maybe (SigDSIGN Ed25519DSIGN)
         ) of
        (Just verKey, Just sig) ->
            either
                (const False)
                (const True)
                (verifyDSIGN () verKey (bundleTxIdentity transaction) sig)
        _ -> False

{- | An output reference as a refusal spells it: the identity in hex, a
@#@, the index.
-}
renderTxIn :: TxIn -> String
renderTxIn (TxIn key index) = hexOf (txIdBytes key) <> "#" <> show index

-- | The raw identity bytes of a transaction id.
txIdBytes :: TxId -> ByteString
txIdBytes (TxId h) = hashToBytes (extractHash h)

-- | Bytes as lowercase hex.
hexOf :: ByteString -> String
hexOf = BC.unpack . B16.encode
