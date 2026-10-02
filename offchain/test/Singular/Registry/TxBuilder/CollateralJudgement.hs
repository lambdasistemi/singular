{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.TxBuilder.CollateralJudgement
Description : What a script-running transaction must state about its fee and collateral
License     : Apache-2.0

One judgement for every builder whose transaction puts collateral at risk,
under the public preprod parameters: the transaction is funded and
collateralised by the output the caller meant, states its total collateral
at the protocol's percentage of its fee rounded up, returns the rest of that
output with its minimum ada, leaves every output its minimum, conserves
value, and pays the ledger's fee for the body as signed with the reference
scripts it reads. Every expected value is derived here from the parameters
and from what the caller says the transaction consumes; nothing is read
from the builder under judgement.
-}
module Singular.Registry.TxBuilder.CollateralJudgement
    ( Spend (..)
    , judgeCollateral
    , witnessAllowance
    ) where

import Data.Foldable (toList)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((^.))

import Cardano.Ledger.Api.Tx (bodyTxL, getMinFeeTx)
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , collateralReturnTxBodyL
    , feeTxBodyL
    , inputsTxBodyL
    , outputsTxBodyL
    , totalCollateralTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (TxOut, coinTxOutL, getMinCoinTxOut)
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.E2E.Setup (addKeyWitness, genesisSignKey)
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Ledger (ConwayEra)
import Singular.Registry.TxBuilder.BookingFixture (preprodParams)

-- | What a transaction consumes, as its caller knows it.
data Spend = Spend
    { spInputs :: [(TxIn, Integer)]
    -- ^ Every output it spends, with its lovelace
    , spFunding :: TxIn
    -- ^ The one that funds and collateralises it
    , spRefBytes :: Int
    -- ^ The bytes of reference scripts it reads
    }

{- | How far past the ledger's minimum a fee may sit: the witness the
estimate pads for, and nothing a declared fixed fee could hide in.
-}
witnessAllowance :: Integer
witnessAllowance = 1_000

lovelaceOf :: TxOut ConwayEra -> Integer
lovelaceOf o = let Coin c = o ^. coinTxOutL in c

-- | The findings against a transaction; none means it states what it owes.
judgeCollateral :: Spend -> ConwayTx -> [Text]
judgeCollateral spend tx =
    concat
        [ [ "the fee is "
                <> T.pack (show fee)
                <> " but the ledger charges "
                <> T.pack (show realMin)
                <> " for this body as signed, with its reference scripts"
          | fee < realMin || fee > realMin + witnessAllowance
          ]
        , [ "it spends "
                <> T.pack (show (Set.toList ins))
                <> ", not the expected "
                <> T.pack (show (map fst (spInputs spend)))
          | ins /= Set.fromList (map fst (spInputs spend))
          ]
        , [ "it is collateralised by "
                <> T.pack (show (Set.toList collateral))
                <> ", not by the expected "
                <> T.pack (show funding)
          | collateral /= Set.singleton funding
          ]
        , [ "total collateral is "
                <> T.pack (show total)
                <> " but "
                <> T.pack (show (ceilPct fee))
                <> " is required"
          | total /= SJust (Coin (ceilPct fee))
          ]
        , case ret of
            SNothing -> ["it declares no collateral return"]
            SJust r ->
                [ "the collateral return is "
                    <> T.pack (show (lovelaceOf r))
                    <> " but the output's remainder is "
                    <> T.pack (show (fundingValue - ceilPct fee))
                | lovelaceOf r /= fundingValue - ceilPct fee
                ]
                    ++ [ "the collateral return is under its minimum"
                       | Coin (lovelaceOf r) < getMinCoinTxOut preprodParams r
                       ]
        , [ "an output is under its minimum ada"
          | o <- toList (body ^. outputsTxBodyL)
          , Coin (lovelaceOf o) < getMinCoinTxOut preprodParams o
          ]
        , [ "value is not conserved: inputs "
                <> T.pack (show inputValue)
                <> " outputs+fee "
                <> T.pack (show (outValue + fee))
          | inputValue /= outValue + fee
          ]
        ]
  where
    body = tx ^. bodyTxL
    Coin fee = body ^. feeTxBodyL
    ins = body ^. inputsTxBodyL
    collateral = body ^. collateralInputsTxBodyL
    total = body ^. totalCollateralTxBodyL
    ret = body ^. collateralReturnTxBodyL
    funding = spFunding spend
    fundingValue = sum [l | (i, l) <- spInputs spend, i == funding]
    inputValue = sum (map snd (spInputs spend))
    outValue = sum (map lovelaceOf (toList (body ^. outputsTxBodyL)))
    Coin realMin =
        getMinFeeTx
            preprodParams
            (addKeyWitness genesisSignKey tx)
            (spRefBytes spend)
    ceilPct f = (f * 150 + 99) `div` 100
