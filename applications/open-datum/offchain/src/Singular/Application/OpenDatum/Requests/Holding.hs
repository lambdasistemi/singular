{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Application.OpenDatum.Requests.Holding
Description : Controller-authorized changes to a live holding
License     : Apache-2.0

An update reads the live holding through the session, checks its protected
control and the payer's payment key, and recreates it with a new payload.
Construction returns an unsigned transaction; the command owns signing and
submission. No mutable resource outlives the session supplied by the caller.
-}
module Singular.Application.OpenDatum.Requests.Holding
    ( buildUpdate
    , buildBookTermination
    ) where

import Control.Exception (throwIO)
import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.ByteString (ByteString)
import Data.Map.Strict qualified as Map
import Lens.Micro ((^.))
import PlutusCore.Data qualified as PLC

import Cardano.Crypto.Hash (hashToBytes)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.Tx.Out (addrTxOutL, valueTxOutL)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Keys (KeyHash (..))
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    , MultiAsset (..)
    )
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Application.OpenDatum.Requests.Assemble
    ( Payer (..)
    , assembleTransaction
    , inlineDatumOf
    , readOutputs
    , resolvePayer
    )
import Singular.Application.OpenDatum.Requests.Records
    ( AsData (..)
    , MintAction (..)
    , ProtectedControl (..)
    , SpendAction (..)
    , decodeLiveDatum
    , mintRedeemer
    , spendRedeemer
    )
import Singular.Application.OpenDatum.Requests.Refusal (Refusal (..))
import Singular.Application.OpenDatum.Requests.Script
    ( RequestScript
    , referenceOutputs
    , requestPolicy
    , requestScriptHash
    , useScript
    )
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (ConwayEra, TxOut)
import Singular.Registry.LedgerProvider
    ( OutputQuery (..)
    , ReadFailure (..)
    , Session
    )
import Singular.Registry.TrieState
    ( RegistryIdentity
    )
import Singular.State.Lineage (registryAsset)
import Singular.State.Preimage
    ( activeTokenName
    , approvalName
    , terminationPreimage
    )

-- | The chain output and the protected control an update must preserve.
data Holding = Holding
    { holdingOutput :: TxOut ConwayEra
    , holdingControl :: PLC.Data
    , holdingController :: ByteString
    , holdingRegistry :: RegistryIdentity
    , holdingKey :: ByteString
    , holdingDeposit :: Integer
    }

{- | Update a live holding with any payload. The payer's payment key must be
its controller. All non-ADA assets and the protected control are preserved;
the output keeps its value, raised to the ledger minimum when necessary.
-}
buildUpdate
    :: Session NoWitness IO
    -> RequestScript
    -> TxIn
    -- ^ The live holding
    -> PLC.Data
    -- ^ The new payload
    -> Addr
    -- ^ The controller's payer address for funding, collateral and change
    -> IO (Either Refusal ConwayTx)
buildUpdate session script reference payload payerAddress = runExceptT $ do
    held <- ExceptT (readHolding session script reference)
    payer <- ExceptT (resolvePayer session payerAddress)
    let KeyHash key = payerKey payer
    unless (hashToBytes key == holdingController held) $
        throwE PayerIsNotController
    references <- ExceptT (referenceOutputs session script)
    let funding = payerFunding payer
        before = holdingOutput held
        datum = PLC.Constr 2 [holdingControl held, payload]
    ExceptT
        $ assembleTransaction
            session
            [funding, (reference, before)]
            references
            payerAddress
        $ do
            index <-
                Tx.payTo'
                    (before ^. addrTxOutL)
                    (before ^. valueTxOutL)
                    (AsData datum)
            _ <-
                Tx.spendScript
                    reference
                    (AsData (spendRedeemer (LiveUpdate (toInteger index))))
            useScript script
            Tx.requireSignature (payerKey payer)
            Tx.collateral (fst funding)

{- | Book permanent termination. The controller funds a minimum-ADA request
holding exactly its active token and one new approval, with no datum. The
protected deposit is donated before script evaluation and balancing.
-}
buildBookTermination
    :: Session NoWitness IO
    -> RequestScript
    -> TxIn
    -> Addr
    -> IO (Either Refusal ConwayTx)
buildBookTermination session script reference payerAddress = runExceptT $ do
    held <- ExceptT (readHolding session script reference)
    payer <- ExceptT (resolvePayer session payerAddress)
    let KeyHash key = payerKey payer
    unless (hashToBytes key == holdingController held) $
        throwE PayerIsNotController
    references <- ExceptT (referenceOutputs session script)
    let registry = holdingRegistry held
        active = activeTokenName registry (holdingKey held)
        approval = approvalName (terminationPreimage (holdingKey held) registry)
        funding = payerFunding payer
        before = holdingOutput held
    (activePolicy, _) <-
        maybe
            (throwE (NotALiveHolding reference))
            pure
            (registryAsset registry)
    let tokens =
            MultiAsset (Map.singleton activePolicy (Map.singleton active 1))
                <> MultiAsset
                    (Map.singleton (requestPolicy script) (Map.singleton approval 1))
    ExceptT
        $ assembleTransaction
            session
            [funding, (reference, before)]
            references
            payerAddress
        $ do
            index <- Tx.payTo (before ^. addrTxOutL) (MaryValue (Coin 0) tokens)
            _ <-
                Tx.spendScript
                    reference
                    (AsData (spendRedeemer (TerminationBook (toInteger index))))
            Tx.mint
                (requestPolicy script)
                (Map.singleton approval 1)
                (AsData (mintRedeemer [BookTermination reference (toInteger index)]))
            Tx.donateToTreasury (Coin (holdingDeposit held))
            useScript script
            Tx.requireSignature (payerKey payer)
            Tx.collateral (fst funding)

-- | A live holding of this application; provider faults retain their identity.
readHolding
    :: Session NoWitness IO
    -> RequestScript
    -> TxIn
    -> IO (Either Refusal Holding)
readHolding session script reference =
    readOutputs session (AtTxIn reference) >>= \case
        Left (MissingOutput _) -> pure (Left (HoldingNotFound reference))
        Left failure -> throwIO failure
        Right [(_, output)] ->
            pure $ maybe (Left (NotALiveHolding reference)) Right (decode output)
        Right _ -> pure (Left (HoldingNotFound reference))
  where
    decode output = do
        case output ^. addrTxOutL of
            Addr _ (ScriptHashObj hash) _ | hash == requestScriptHash script -> Just ()
            _ -> Nothing
        datum@(PLC.Constr 2 [control, _]) <- inlineDatumOf output
        (protected, _) <- decodeLiveDatum datum
        let registry = controlRegistry protected
            key = controlKey protected
            deposit = controlDeposit protected
            expected = activeTokenName registry key
            MaryValue (Coin lovelace) (MultiAsset assets) = output ^. valueTxOutL
        (statePolicy, _) <- registryAsset registry
        unless
            (controlActiveAsset protected == (statePolicy, expected))
            Nothing
        unless (lovelace >= deposit) Nothing
        unless
            ((Map.lookup statePolicy assets >>= Map.lookup expected) == Just 1)
            Nothing
        pure
            ( Holding
                output
                control
                (controlController protected)
                registry
                key
                deposit
            )
