{- |
Module      : Conformance.Run.Wallet
Description : Split out of Conformance.Run (#263); see that module's header
License     : Apache-2.0
-}
module Conformance.Run.Wallet (largestWalletUtxo, secondWallet, fundWallet, collateralPot, collateralPotWithChange, consolidateFunding, consolidateWallet, atticAddr, carveSeed) where

import Conformance.Run.Submit
import Conformance.Run.Environment
import Conformance.Run.Observe

import Control.Concurrent (threadDelay)
import Data.ByteString qualified as BS
import Data.IORef (readIORef, writeIORef)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((&), (.~), (^.))

import Cardano.Ledger.Address (Addr (..))

import Cardano.Ledger.Api.Tx (
    mkBasicTx,
    mkBasicTxBody,
    txIdTx,
 )
import Cardano.Ledger.Api.Tx.Body (
    feeTxBodyL,
    inputsTxBodyL,
    outputsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    coinTxOutL,
    getMinCoinTxOut,
    mkBasicTxOut,
 )
import Cardano.Ledger.BaseTypes (
    Network (..),
    TxIx (..),
 )
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (TxIn (..))

import Singular.Registry.Ledger (
    Coin (..),
    ConwayEra,
    TxOut,
 )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.TxBuilder.Internal (addrFromKeyHashBytes)
import Cardano.Node.Client.E2E.Setup (
    addKeyWitness,
    enterpriseAddr,
    keyHashFromSignKey,
    mkSignKey,
    Ed25519DSIGN,
    SignKeyDSIGN,
 )
import Cardano.Node.Client.Submitter (
    SubmitResult (..),
    Submitter (..),
 )

import Conformance.Mirror (
    emit,
    failWith,
    require,
 )

{- | The largest wallet UTxO: ample funds for boot, which spends
only the seed and one more input. First-in-query-order would be
dust after a session of folds.
-}
largestWalletUtxo :: Cage.Provider IO -> IO (TxIn, TxOut ConwayEra)
largestWalletUtxo prov = do
    utxos <- Cage.queryUTxOs prov genesisAddr
    -- #157: a spent approval is not burned at the fold, so it returns to
    -- the funder and rides in the wallet. Fee and collateral inputs are
    -- taken from an ada-only output, which is what the ledger requires of
    -- collateral and what the hand model asserts of its funder.
    case sortOn (Down . (^. coinTxOutL) . snd) (filter (adaOnlyOut . snd) utxos) of
        [] -> failWith "genesis wallet has no ada-only UTxO; cannot fund"
        u : _ -> pure u


{- | The second wallet: a key derived from a fixed seed (like the
genesis key), funded by a plain split of the largest genesis UTxO.
CG19's second request is owned (and funded) by it.
-}
secondWallet :: Env -> IO (SignKeyDSIGN Ed25519DSIGN, Addr)
secondWallet env = do
    existing <- readIORef (envKey2 env)
    case existing of
        Just w -> pure w
        Nothing -> do
            let sk = mkSignKey "conformance-second-key-seed-000001"
                addr = enterpriseAddr (keyHashFromSignKey sk)
            fundWallet env addr 12_000_000
            writeIORef (envKey2 env) (Just (sk, addr))
            pure (sk, addr)


fundWallet :: Env -> Addr -> Integer -> IO ()
fundWallet env addr amount = do
    let prov = envProv env
    (funderIn, funderOut) <- largestWalletUtxo prov
    let Coin avail = funderOut ^. coinTxOutL
        fee = 200_000
        change = avail - amount - fee
    require
        ("wallet funding: funder too small (" <> show avail <> ")")
        (change > amount)
    let body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton funderIn
                & outputsTxBodyL
                    .~ StrictSeq.fromList
                        [ mkBasicTxOut addr (MaryValue (Coin amount) mempty)
                        , mkBasicTxOut
                            genesisAddr
                            (MaryValue (Coin change) mempty)
                        ]
                & feeTxBodyL .~ Coin fee
    _ <- submitWithGenesis (envSubmit env) (mkBasicTx body)
    pure ()


{- | A small dedicated collateral pot for one refusing transaction:
on phase-2 failure the whole collateral is taken, so the collateral
is a split-off 5 ADA output — never the 30 ADA funder the CG05
shape once used. The pot is a pure collateral input (never a
regular input), ada-only and key-witnessed.
-}
collateralPot :: Env -> IO TxIn
collateralPot env = fst <$> collateralPotWithChange env


collateralPotWithChange :: Env -> IO (TxIn, (TxIn, TxOut ConwayEra))
collateralPotWithChange env = do
    let prov = envProv env
    (funderIn, funderOut) <- largestWalletUtxo prov
    let Coin avail = funderOut ^. coinTxOutL
        pot = 5_000_000
        fee = 200_000
        change = avail - pot - fee
    require "collateral pot: funder too small" (change > pot)
    let body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton funderIn
                & outputsTxBodyL
                    .~ StrictSeq.fromList
                        [ mkBasicTxOut
                            genesisAddr
                            (MaryValue (Coin pot) mempty)
                        , mkBasicTxOut
                            genesisAddr
                            (MaryValue (Coin change) mempty)
                        ]
                & feeTxBodyL .~ Coin fee
    tx <- submitWithGenesis (envSubmit env) (mkBasicTx body)
    -- The fresh change output is the next fold's exact ada-only funder.
    -- Carry its outref directly: a node query immediately after the split
    -- can still expose the consumed predecessor.
    let potIn = TxIn (txIdTx tx) (TxIx 0)
        changeIn = TxIn (txIdTx tx) (TxIx 1)
    let awaitVisible 0 = failWith "collateral split is not yet visible in wallet UTxOs"
        awaitVisible n = do
            utxos <- Cage.queryUTxOs prov genesisAddr
            if all (`elem` map fst utxos) [potIn, changeIn]
                then pure ()
                else threadDelay 1_000_000 >> awaitVisible (n - 1)
    awaitVisible (30 :: Int)
    pure (potIn, (changeIn, mkBasicTxOut genesisAddr
        (MaryValue (Coin change) mempty)))


consolidateFunding :: Env -> IO ()
consolidateFunding env = consolidateWallet (envProv env) (envSubmit env)


-- | The sweep, before there is an `Env` to carry: a CA session designates
-- its canonical seed during construction, and a sweep after that would
-- spend the very output CA01 boots from.
consolidateWallet :: Cage.Provider IO -> Submitter IO -> IO ()
consolidateWallet prov submit = do
    utxos <- Cage.queryUTxOs prov genesisAddr
    let spendable = filter (not . carriesRefScript . snd) utxos
        dirty = filter (not . adaOnlyOut . snd) spendable
        clean = filter (adaOnlyOut . snd) spendable
    if length spendable < 2 && null dirty
        then pure ()
        else do
            pp <- Cage.queryProtocolParams prov
            let total = sum [outCoin o | (_, o) <- spendable]
                assets =
                    foldr
                        (\(_, o) acc -> mergeAssets acc (rawAssets o))
                        Map.empty
                        dirty
                fee = 1_000_000
                atticProbe c =
                    mkBasicTxOut atticAddr (MaryValue (Coin c) (MultiAsset assets))
                Coin atticFirst = getMinCoinTxOut @ConwayEra pp (atticProbe 0)
                atticAda =
                    if Map.null assets
                        then 0
                        else
                            let Coin c = getMinCoinTxOut @ConwayEra pp (atticProbe atticFirst)
                             in c
                fundingAda = total - fee - atticAda
                outs =
                    mkBasicTxOut genesisAddr (MaryValue (Coin fundingAda) mempty)
                        : [atticProbe atticAda | not (Map.null assets)]
                body =
                    mkBasicTxBody
                        & inputsTxBodyL .~ Set.fromList (map fst spendable)
                        & outputsTxBodyL .~ StrictSeq.fromList outs
                        & feeTxBodyL .~ Coin fee
                signed = addKeyWitness genesisSignKey (mkBasicTx body)
            require
                ("consolidateFunding: wallet too small: " <> show fundingAda)
                (fundingAda > 5_000_000)
            result <- submitTxResilient submit signed
            case result of
                Submitted _ -> do
                    awaitTx signed
                    emit
                        "funding"
                        ( show (length clean)
                            <> " ada-only and "
                            <> show (length dirty)
                            <> " approval-bearing outputs swept; funding is one \
                               \output of "
                            <> show fundingAda
                            <> " lovelace"
                        )
                Rejected reason ->
                    failWith
                        ( "consolidateFunding refused: "
                            <> T.unpack (TE.decodeUtf8Lenient reason)
                        )


{- | Where spent approvals go.

A fold returns the approval it consumed to the booker, which in this
harness is the funding wallet, and the library builders pick their extra
input and their collateral by position: one small token-bearing output is
enough to make a boot unfundable. The harness moves them aside. Nothing
reads them again — an approval is spent evidence, and the rows assert
nothing about where it rests.
-}
atticAddr :: Addr
atticAddr = addrFromKeyHashBytes Testnet (BS.replicate 28 0xaa)


{- | Carve a small ada-only output to seed a cage with.

A boot consumes its seed, so seeding from the largest output strands the
session's funding in a registry: what is left is whatever small change
happened to be lying about, and the next builder that needs collateral
finds too little. Carving the seed leaves the consolidated output where it
is.
-}
carveSeed :: Env -> IO TxIn
carveSeed env = do
    let prov = envProv env
    (funderIn, funderOut) <- largestWalletUtxo prov
    let Coin avail = funderOut ^. coinTxOutL
        seed = 20_000_000
        fee = 1_000_000
        change = avail - seed - fee
    require "carveSeed: funder too small to carve a seed" (change > seed)
    let body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton funderIn
                & outputsTxBodyL
                    .~ StrictSeq.fromList
                        [ mkBasicTxOut genesisAddr (MaryValue (Coin seed) mempty)
                        , mkBasicTxOut genesisAddr (MaryValue (Coin change) mempty)
                        ]
                & feeTxBodyL .~ Coin fee
        signed = addKeyWitness genesisSignKey (mkBasicTx body)
    result <- submitTxResilient (envSubmit env) signed
    case result of
        Submitted _ -> awaitTx signed
        Rejected reason ->
            failWith
                ( "carveSeed refused: "
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                )
    pure (TxIn (txIdTx signed) (TxIx 0))
