{- |
Module      : Singular.Registry.Node.Funding
Description : The funding floor a run must clear before it starts
License     : Apache-2.0

The one place the pre-run funding check lives: what the funding wallet
must hold before the first transaction is built, the diagnostic that
names the address, what is required, what is there, and the faucet
step, and the rendering of lovelace amounts that diagnostic reads.
-}
module Singular.Registry.Node.Funding
    ( -- * Funding
      FundingFloor (..)
    , defaultFundingFloor
    , checkFunding
    ) where

import Data.Map.Strict qualified as Map
import Lens.Micro ((^.))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx.Out (valueTxOutL)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Singular.Registry.Ledger (Coin (..))
import Singular.Registry.Node.Options (die)
import Singular.Registry.Node.Wallet (bech32Address)
import Singular.Registry.Provider qualified as Cage

{- | What the funding wallet must hold before the first transaction is
built. A floor, not a guarantee: it catches the empty and the
nearly-empty wallet at the start of a run rather than inside a balance
exception halfway through one.
-}
data FundingFloor = FundingFloor
    { floorTotal :: Integer
    -- ^ Total lovelace the address must hold
    , floorCollateral :: Integer
    -- ^ Lovelace in one ada-only UTxO, to serve as collateral
    }
    deriving (Eq, Show)

-- | 100 ada held, with 5 ada of it in an ada-only output.
defaultFundingFloor :: FundingFloor
defaultFundingFloor =
    FundingFloor
        { floorTotal = 100_000_000
        , floorCollateral = 5_000_000
        }

{- | Refuse to start when the funding wallet cannot pay, naming the
address, what is required, what is there, and the faucet step.
-}
checkFunding :: Cage.Provider IO -> Addr -> FundingFloor -> IO ()
checkFunding prov addr fl = do
    utxos <- Cage.withView prov (`Cage.viewUTxOsAt` addr)
    let values = map (\(_, out) -> out ^. valueTxOutL) utxos
        total = sum [c | MaryValue (Coin c) _ <- values]
        adaOnly = [c | MaryValue (Coin c) (MultiAsset m) <- values, Map.null m]
        bestCollateral = if null adaOnly then 0 else maximum adaOnly
    if total >= floorTotal fl && bestCollateral >= floorCollateral fl
        then pure ()
        else
            die . unlines $
                [ "the funding wallet cannot pay for this run."
                , "  address            : " <> bech32Address addr
                , "  lovelace held      : "
                    <> ada total
                    <> " across "
                    <> show (length utxos)
                    <> " UTxO(s)"
                , "  lovelace required  : " <> ada (floorTotal fl)
                , "  ada-only UTxO held : "
                    <> ada bestCollateral
                    <> " (the collateral input)"
                , "  collateral required: " <> ada (floorCollateral fl)
                , "  Fund this address, then rerun. On preprod the faucet is"
                , "    https://docs.cardano.org/cardano-testnets/tools/faucet"
                , "  It pays a single output; send one self-payment \
                  \afterwards so the"
                , "  wallet also holds an ada-only output to spend as \
                  \collateral."
                ]

-- | Lovelace as @N lovelace (X.YYYYYY ada)@.
ada :: Integer -> String
ada l =
    show l
        <> " lovelace ("
        <> show (l `div` 1_000_000)
        <> "."
        <> pad (show (l `mod` 1_000_000))
        <> " ada)"
  where
    pad s = replicate (6 - length s) '0' <> s
