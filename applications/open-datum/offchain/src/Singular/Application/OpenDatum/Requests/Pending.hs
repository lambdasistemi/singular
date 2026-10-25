{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Application.OpenDatum.Requests.Pending
Description : Return a pending registration by time: reclaim and cleanup
License     : Apache-2.0

A pending registration that nobody folds is spent by time. Inside the reclaim
window the refund address takes the whole request back; once the window has
ended anyone returns the deposit to the refund address and keeps the rest.
Both burn the approval the registration holds.
-}
module Singular.Application.OpenDatum.Requests.Pending
    ( buildReclaim
    , buildCleanup
    ) where

import Control.Exception (throwIO)
import Control.Monad (when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Map.Strict qualified as Map
import Lens.Micro ((^.))

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.Tx.Out (addrTxOutL, coinTxOutL, valueTxOutL)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Keys (KeyHash (..))
import Cardano.Ledger.Mary.Value
    ( AssetName
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID
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
    , tipSlot
    , validityFromTip
    )
import Singular.Application.OpenDatum.Requests.Records
    ( AsData (..)
    , MintAction (..)
    , RegistrationData (..)
    , SpendAction (..)
    , approvalNameOf
    , decodeRegistration
    , mintRedeemer
    , spendRedeemer
    )
import Singular.Application.OpenDatum.Requests.Refusal
    ( Operation (..)
    , Refusal (..)
    )
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
import Singular.Registry.SessionIO
    ( ceilingSlot
    , floorSlot
    , slotStart
    )

{- | A pending registration read from the chain: the output, the
registration its datum carries and the approval token it holds.
-}
data Held = Held
    { heldOutput :: TxOut ConwayEra
    , heldRegistration :: RegistrationData
    , heldApproval :: AssetName
    }

{- | Spend a pending registration inside its reclaim window: the whole request
value goes to the refund address, which signs; the approval is burned. The
payer is the refund address, whose one signature funds the transaction and
authorises the reclaim, and collects the change.
-}
buildReclaim
    :: Session NoWitness IO
    -> RequestScript
    -> TxIn
    -- ^ The pending registration
    -> Addr
    -- ^ The payer
    -> IO (Either Refusal ConwayTx)
buildReclaim session script pending payerAddress = runExceptT $ do
    held <- ExceptT (readPending session script pending)
    let registration = heldRegistration held
    refundKey <- case rdRefundAddress registration of
        Addr _ (KeyHashObj key) _ -> pure key
        _ -> throwE RefundAddressIsScript
    case payerAddress of
        Addr _ (KeyHashObj key) _
            | key == refundKey -> pure ()
            | otherwise -> throwE PayerIsNotRefundAddress
        _ -> throwE PayerIsNotAKey
    payer <- ExceptT (resolvePayer session payerAddress)
    now <- lift (tipSlot session)
    opens <- lift (ceilingSlot session (rdProcessDeadline registration))
    closes <- lift (floorSlot session (rdReclaimEnd registration))
    when (now < opens) $ throwE (WindowNotOpen Reclaim)
    upper <-
        lift (validityFromTip session now closes)
            >>= maybe (throwE (WindowClosed Reclaim)) pure
    scriptOutputs <- ExceptT (referenceOutputs session script)
    let Coin request = heldOutput held ^. coinTxOutL
        KeyHash refundHash = refundKey
        funding = payerFunding payer
    ExceptT $
        assembleTransaction
            session
            [funding, (pending, heldOutput held)]
            scriptOutputs
            payerAddress
            ( do
                _ <- Tx.spendScript pending (AsData (spendRedeemer OwnerReclaim))
                burnApproval script held
                useScript script
                _ <-
                    Tx.payTo
                        (rdRefundAddress registration)
                        (MaryValue (Coin request) mempty)
                Tx.requireSignature (KeyHash refundHash)
                Tx.validFrom now
                Tx.validTo upper
                Tx.collateral (fst funding)
            )

{- | Spend a pending registration after its reclaim window: the deposit goes
to the refund address, the rest of the request value to the payer; the
approval is burned. Anyone may build it.
-}
buildCleanup
    :: Session NoWitness IO
    -> RequestScript
    -> TxIn
    -- ^ The pending registration
    -> Addr
    -- ^ The payer
    -> IO (Either Refusal ConwayTx)
buildCleanup session script pending payerAddress = runExceptT $ do
    held <- ExceptT (readPending session script pending)
    let registration = heldRegistration held
    payer <- ExceptT (resolvePayer session payerAddress)
    now <- lift (tipSlot session)
    opens <- lift (ceilingSlot session (rdReclaimEnd registration))
    when (now < opens) $ throwE (WindowNotOpen Cleanup)
    nowMs <- lift (slotStart session now)
    span' <- lift (floorSlot session (nowMs + cleanupSpan))
    upper <-
        lift (validityFromTip session now span')
            >>= maybe
                (throwE (BuildFailed "no validity interval at the tip is usable"))
                pure
    scriptOutputs <- ExceptT (referenceOutputs session script)
    let funding = payerFunding payer
    ExceptT $
        assembleTransaction
            session
            [funding, (pending, heldOutput held)]
            scriptOutputs
            payerAddress
            ( do
                _ <- Tx.spendScript pending (AsData (spendRedeemer ExpiredCleanup))
                burnApproval script held
                useScript script
                _ <-
                    Tx.payTo
                        (rdRefundAddress registration)
                        (MaryValue (Coin (rdDeposit registration)) mempty)
                Tx.validFrom now
                Tx.validTo upper
                Tx.collateral (fst funding)
            )

-- | How long a cleanup stays valid from the tip, in milliseconds.
cleanupSpan :: Integer
cleanupSpan = 3_600_000

-- | Burn the approval a pending registration holds.
burnApproval :: RequestScript -> Held -> Tx.TxBuild q e ()
burnApproval script held =
    Tx.mint
        (requestPolicy script)
        (Map.singleton (heldApproval held) (-1))
        (AsData (mintRedeemer [ApprovalBurn]))

{- | The pending registration at an output of the chain: an output at the
address of the script that holds the approval its datum commits, with the
registration inline. Anything else is no pending registration.
-}
readPending
    :: Session NoWitness IO
    -> RequestScript
    -> TxIn
    -> IO (Either Refusal Held)
readPending session script pending =
    readOutputs session (AtTxIn pending) >>= \case
        Left (MissingOutput _) -> pure (Left (PendingNotFound pending))
        Left failure -> throwIO failure
        Right [(_, output)] -> pure (shaped output)
        Right _ -> pure (Left (PendingNotFound pending))
  where
    declined = Left (NotAPendingRegistration pending)
    shaped output = case output ^. addrTxOutL of
        Addr net (ScriptHashObj hash) _
            | hash == requestScriptHash script -> do
                registration <-
                    maybe declined Right $
                        inlineDatumOf output >>= decodeRegistration net
                approval <- maybe declined Right (approvalNameOf registration)
                if holdsOnly (requestPolicy script) approval output
                    then Right (Held output registration approval)
                    else declined
        _ -> declined

-- | The output holds this token once and nothing but ADA besides.
holdsOnly :: PolicyID -> AssetName -> TxOut ConwayEra -> Bool
holdsOnly policy name output =
    let MaryValue _ (MultiAsset assets) = output ^. valueTxOutL
    in  assets == Map.singleton policy (Map.singleton name 1)
