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
import Data.ByteString.Short qualified as SBS
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
    ( AssetName (..)
    , MaryValue (..)
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
    , SpendAction (..)
    , spendRedeemer
    )
import Singular.Application.OpenDatum.Requests.Refusal (Refusal (..))
import Singular.Application.OpenDatum.Requests.Script
    ( RequestScript
    , referenceOutputs
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
    ( RegistryIdentity (..)
    , StatePolicyId (..)
    )
import Singular.State.Lineage (registryAsset)
import Singular.State.Preimage (activeTokenName)

-- | The chain output and the protected control an update must preserve.
data Holding = Holding
    { holdingOutput :: TxOut ConwayEra
    , holdingControl :: PLC.Data
    , holdingController :: ByteString
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

{- | A live holding of this application; provider faults retain their identity.
| Build the controller's termination booking, funded by the payer.
-}
buildBookTermination
    :: Session NoWitness IO
    -> RequestScript
    -> TxIn
    -> Addr
    -> IO (Either Refusal ConwayTx)
buildBookTermination _ _ _ _ = pure (Left (BuildFailed "termination booking unavailable"))

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
        PLC.Constr 2 [control, _] <- inlineDatumOf output
        PLC.Constr
            0
            [ PLC.Constr 0 [PLC.B policy, PLC.B name]
                , PLC.Constr 0 [PLC.B activePolicy, PLC.B activeName]
                , PLC.B key
                , PLC.B controller
                , PLC.I deposit
                ] <-
            pure control
        let registry =
                RegistryIdentity (StatePolicyId policy) (AssetName (SBS.toShort name))
            expected@(AssetName expectedBytes) = activeTokenName registry key
            MaryValue (Coin lovelace) (MultiAsset assets) = output ^. valueTxOutL
        (statePolicy, _) <- registryAsset registry
        unless
            (activePolicy == policy && activeName == SBS.fromShort expectedBytes)
            Nothing
        unless (deposit >= 0 && lovelace >= deposit) Nothing
        unless
            ((Map.lookup statePolicy assets >>= Map.lookup expected) == Just 1)
            Nothing
        pure (Holding output control controller)
