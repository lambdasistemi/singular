{- |
Module      : Singular.CLI.Outlay
Description : What a command puts out of the caller's wallet, measured from the bodies it built
License     : Apache-2.0

A write command spends lovelace three ways: the fee of each transaction,
the request's bond it locks until the fold settles it, and the collateral a
failing script would forfeit. The first two are measured here from the
transaction the command is about to submit and from the network's own
parameters; the fold that follows a booking cannot exist until the booking
confirms, so it is bounded from those parameters instead: no fold may cost
more than a transaction of the maximum size carrying the maximum execution
units and the reference scripts it reads. An allowance the caller approved is
judged against the total before anything is submitted.
-}
module Singular.CLI.Outlay
    ( Outlay (..)
    , bookingOutlay
    , updateOutlay
    , outlayTotal
    , withinAllowance
    , collateralOf
    , collateralOfFee
    ) where

import Data.Foldable (toList)
import Data.Maybe (fromMaybe)
import Lens.Micro ((^.))

import Cardano.Ledger.Api.PParams (ppCollateralPercentageL)
import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , outputsTxBodyL
    , totalCollateralTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (TxOut, coinTxOutL)
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Ledger (ConwayEra, PParams)
import Singular.Registry.Lifecycle (protocolFeeReserve)

-- | What one command puts out, in lovelace.
data Outlay = Outlay
    { outlayFee :: Integer
    -- ^ The fee of the transaction the command submits first
    , outlayBond :: Integer
    -- ^ The request's bond the booking locks; none for an update
    , outlayFoldBound :: Integer
    -- ^ The most the fold that follows a booking may cost; none for an update
    }
    deriving stock (Eq, Show)

-- | The whole of it.
outlayTotal :: Outlay -> Integer
outlayTotal o = outlayFee o + outlayBond o + outlayFoldBound o

{- | A booking: its own fee, the bond its request output locks (output
zero), and the bound on the fold that follows, from the parameters and the
reference outputs the fold reads.
-}
bookingOutlay
    :: PParams ConwayEra -> [(TxIn, TxOut ConwayEra)] -> ConwayTx -> Outlay
bookingOutlay pp refs booking =
    Outlay
        { outlayFee = feeOf booking
        , outlayBond = case toList (booking ^. bodyTxL . outputsTxBodyL) of
            request : _ -> let Coin c = request ^. coinTxOutL in c
            [] -> 0
        , outlayFoldBound = let Coin c = protocolFeeReserve pp refs in c
        }

-- | An update: its fee alone.
updateOutlay :: ConwayTx -> Outlay
updateOutlay tx =
    Outlay{outlayFee = feeOf tx, outlayBond = 0, outlayFoldBound = 0}

-- | Whether an outlay is inside an approved allowance; no allowance approves any.
withinAllowance :: Maybe Integer -> Outlay -> Bool
withinAllowance allowance o = maybe True (outlayTotal o <=) allowance

feeOf :: ConwayTx -> Integer
feeOf tx = let Coin f = tx ^. bodyTxL . feeTxBodyL in f

-- | The collateral the protocol requires for a fee: its percentage, rounded up.
collateralOfFee :: PParams ConwayEra -> Integer -> Integer
collateralOfFee pp fee =
    (fee * toInteger (pp ^. ppCollateralPercentageL) + 99) `div` 100

{- | The collateral a transaction states, and the most a fee of this size
could ever forfeit: the total it declares, or else the protocol's percentage
of its fee rounded up.
-}
collateralOf :: PParams ConwayEra -> ConwayTx -> Integer
collateralOf pp tx =
    fromMaybe
        (collateralOfFee pp (feeOf tx))
        (declared (tx ^. bodyTxL . totalCollateralTxBodyL))
  where
    declared (SJust (Coin c)) = Just c
    declared SNothing = Nothing
