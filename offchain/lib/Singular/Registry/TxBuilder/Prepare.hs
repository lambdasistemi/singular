{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Registry.TxBuilder.Prepare
Description : One preparation transaction that funds a command's wallet
License     : Apache-2.0

When no output of the payer's wallet can fund a command (every output
carries tokens or a reference script beside the ada, or none holds
enough), the command spends one transaction first that puts the ada the
command needs into an output of its own. This module is the pure builder
of that transaction: selection and body from explicit inputs, priced by
the ledger's own balancing, never a typed constant.

A preparation spends the fewest spendable outputs it needs, largest
first; an output carrying a reference script is never spent, while any
other output, token-carrying or not, may be. It makes the funding output
as its first output — ada only, holding exactly the requirement, so the
journal reads it back as the transaction's first output — and returns
everything else the spent outputs held, tokens included, in one remainder
output at the payer's address at or above the ledger minimum for its
assets. The fee is the ledger's price of the built body, found by the
same balancing the other builders use ('Cardano.Tx.Balance.balanceTx',
which iterates the fee to its fixpoint and appends the change), not a
typed number. The transaction carries no scripts, so it needs no
collateral, and the one signing key it assumes is priced into the fee.

'planPreparation' judges the whole thing before anything is signed: it
returns the balanced transaction with its funding reference and fee, or
a 'PrepareError' naming the requirement, the best fee balancing measured,
the remainder floor, what the wallet may spend and its largest output. A
wallet whose spendable ada cannot cover preparation plus command is
refused from that error, before anything is submitted. An exact cover —
spent equals funding plus fee to the lovelace, leaving no remainder — is
refused the same way: the balancer always appends a change output, and a
zero-ada one is not a valid output. Real wallets never land on it; the
boundary spec pins the behaviour around it.
-}
module Singular.Registry.TxBuilder.Prepare
    ( PrepareError (..)
    , Preparation (..)
    , planPreparation
    , spendableOuts
    , spendableHeld
    ) where

import Control.Monad (unless, when)
import Data.Foldable (toList)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Lens.Micro ((&), (.~), (^.))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (bodyTxL, mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , inputsTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    , reqSignerHashesTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , coinTxOutL
    , getMinCoinTxOut
    , mkBasicTxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..), TxIx (..))
import Cardano.Ledger.Core (PParams)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Balance
    ( BalanceError (..)
    , BalanceResult (..)
    , balanceTx
    )
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Ledger (Coin (..), ConwayEra)
import Singular.Registry.TxBuilder.Internal.Identity
    ( addrKeyHashBytes
    , addrWitnessKeyHash
    )

-- | Why no preparation can be planned: what shortfall the wallet leaves.
data PrepareError
    = PrepareShortfall
    { prepareRequired :: Integer
    -- ^ The funding the command needs.
    , prepareFee :: Maybe Integer
    {- ^ The best fee balancing measured, if any attempt balanced far
    enough to price one; 'Nothing' when no spendable output exists.
    -}
    , prepareRemainderMin :: Integer
    -- ^ The ledger minimum for returning everything the wallet holds.
    , prepareHeld :: Integer
    -- ^ What the wallet may spend, in total lovelace.
    , prepareLargest :: Integer
    -- ^ The largest spendable output, in lovelace.
    }
    deriving (Show, Eq)

-- | A planned preparation: the balanced transaction and what it makes.
data Preparation = Preparation
    { prepSpent :: [(TxIn, TxOut ConwayEra)]
    -- ^ The spent outputs: the fewest largest-first that cover it.
    , prepTx :: ConwayTx
    -- ^ The balanced transaction to sign and submit as built.
    , prepFunding :: TxIn
    -- ^ The made funding output: this transaction's first output.
    , prepFee :: Integer
    -- ^ The ledger's fee for the built body.
    , prepFundingCoin :: Integer
    -- ^ What the funding output holds: exactly the requirement.
    , prepRemainderCoin :: Integer
    -- ^ What the remainder output holds: at or above its minimum.
    }
    deriving (Show, Eq)

{- | What the wallet may spend: every output carrying no reference script,
token-carrying or not. Reference-script outputs are never spent: a
transaction may not both spend an output and reference it.
-}
spendableOuts
    :: [(TxIn, TxOut ConwayEra)] -> [(TxIn, TxOut ConwayEra)]
spendableOuts utxos =
    [u | u@(_, o) <- utxos, o ^. referenceScriptTxOutL == SNothing]

-- | What the wallet may spend, in total lovelace.
spendableHeld :: [(TxIn, TxOut ConwayEra)] -> Integer
spendableHeld utxos =
    sum [c | (_, o) <- spendableOuts utxos, let Coin c = o ^. coinTxOutL]

{- | Plan one preparation transaction that makes an ada-only output holding
the requirement: the fewest largest-first spendable outputs that cover it,
balanced by the ledger's own fee. Returns the balanced transaction or the
shortfall, before anything is signed or submitted.
-}
planPreparation
    :: PParams ConwayEra
    -> Addr
    -> Integer
    -- ^ The funding the command needs.
    -> [(TxIn, TxOut ConwayEra)]
    -> Either PrepareError Preparation
planPreparation pp payerAddr required wallet = go prefixes Nothing
  where
    spendable = sortOn (Down . (^. coinTxOutL) . snd) (spendableOuts wallet)
    prefixes = [take k spendable | k <- [1 .. length spendable]]
    go [] best = Left (shortfall best)
    go (spent : rest) best = case attempt spent of
        Right prep -> Right prep
        Left fee -> go rest (combineFee best fee)
    combineFee Nothing y = y
    combineFee x Nothing = x
    combineFee (Just a) (Just b) = Just (max a b)
    shortfall best =
        PrepareShortfall
            required
            best
            remainderMinAll
            (spendableHeld wallet)
            ( case spendable of
                [] -> 0
                (_, o) : _ -> let Coin c = o ^. coinTxOutL in c
            )
    -- The ledger minimum for returning everything the wallet holds.
    remainderMinAll =
        let tokens =
                foldl'
                    (<>)
                    mempty
                    [ m
                    | (_, o) <- spendableOuts wallet
                    , let MaryValue _ (MultiAsset m) = o ^. valueTxOutL
                    ]
            Coin c =
                getMinCoinTxOut
                    pp
                    (mkBasicTxOut payerAddr (MaryValue (Coin 0) (MultiAsset tokens)))
        in  c
    attempt spent = case balanceTx pp spent [] payerAddr (unsigned spent) of
        Left err -> Left (feeOfError err)
        Right balanced -> checkBalanced spent balanced
    unsigned :: [(TxIn, TxOut ConwayEra)] -> ConwayTx
    unsigned spent =
        mkBasicTx $
            mkBasicTxBody
                & inputsTxBodyL .~ Set.fromList (map fst spent)
                & outputsTxBodyL
                    .~ StrictSeq.singleton
                        (mkBasicTxOut payerAddr (MaryValue (Coin required) mempty))
                & feeTxBodyL .~ Coin 0
                & reqSignerHashesTxBodyL
                    .~ Set.singleton (addrWitnessKeyHash (addrKeyHashBytes payerAddr))
    feeOfError = \case
        InsufficientFee (Coin f) _ -> Just f
        FeeNotConverged -> Nothing
        CollateralShortfall _ _ -> Nothing
    checkBalanced spent (BalanceResult tx changeIndex) = do
        let body = tx ^. bodyTxL
            outs = toList (body ^. outputsTxBodyL)
            Coin fee = body ^. feeTxBodyL
        when (changeIndex /= 1 || length outs /= 2) (Left Nothing)
        case outs of
            [fundOut, changeOut] -> do
                let Coin fundCoin = fundOut ^. coinTxOutL
                    MaryValue _ (MultiAsset fundMA) = fundOut ^. valueTxOutL
                when
                    ( fundCoin /= required
                        || fundOut ^. referenceScriptTxOutL /= SNothing
                        || not (Map.null fundMA)
                    )
                    (Left Nothing)
                let Coin changeCoin = changeOut ^. coinTxOutL
                    MaryValue _ (MultiAsset changeMA) = changeOut ^. valueTxOutL
                    Coin changeMin = getMinCoinTxOut pp changeOut
                when (changeCoin <= 0 || changeCoin < changeMin) (Left (Just fee))
                let (Coin inAda, inMA) = sumsOver (map snd spent)
                unless (inAda == required + fee + changeCoin && inMA == changeMA) $
                    Left Nothing
                Right
                    Preparation
                        { prepSpent = spent
                        , prepTx = tx
                        , prepFunding = TxIn (txIdTx tx) (TxIx 0)
                        , prepFee = fee
                        , prepFundingCoin = required
                        , prepRemainderCoin = changeCoin
                        }
            _ -> Left Nothing
    sumsOver = foldl' addOut (Coin 0, mempty)
    addOut
        :: (Coin, Map.Map PolicyID (Map.Map AssetName Integer))
        -> TxOut ConwayEra
        -> (Coin, Map.Map PolicyID (Map.Map AssetName Integer))
    addOut (Coin a, ma) o =
        let MaryValue (Coin c) (MultiAsset m) = o ^. valueTxOutL
        in  (Coin (a + c), ma <> m)
