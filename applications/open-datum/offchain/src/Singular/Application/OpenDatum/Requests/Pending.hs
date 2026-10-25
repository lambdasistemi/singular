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

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Application.OpenDatum.Requests.Refusal (Refusal (..))
import Singular.Application.OpenDatum.Requests.Script (RequestScript)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.LedgerProvider (Session)

{- | Spend a pending registration inside its reclaim window: the whole request
value goes to the refund address, which signs; the approval is burned. The
payer funds the transaction and collects the change.
-}
buildReclaim
    :: Session NoWitness IO
    -> RequestScript
    -> TxIn
    -- ^ The pending registration
    -> Addr
    -- ^ The payer
    -> IO (Either Refusal ConwayTx)
buildReclaim _ _ _ _ = pure (Left (BuildFailed "not built"))

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
buildCleanup _ _ _ _ = pure (Left (BuildFailed "not built"))
