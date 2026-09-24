{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Singular.Registry.TxBuilder.BootSpec
Description : A registry boots only by reference
License     : Apache-2.0

The state validator is fifteen kilobytes against a sixteen-kilobyte
transaction cap, so no transaction carries it inline: a boot resolves
it through a publication in the payer's wallet, and a wallet without
one is refused `StateValidatorNotPublished` before anything is built.

These rows run `bootTokenImpl` itself against a provider serving a
chosen wallet. Evaluation is the first thing the builder asks the node
for once it has a transaction, so the stub keeps the transaction it is
handed and stops there: a refused boot never reaches it, an accepted one
is read back from it. The reference input the control expects is the
output the fixture put in the wallet.
-}
module Singular.Registry.TxBuilder.BootSpec (spec) where

import Control.Exception (IOException, displayException, try)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Lens.Micro ((&), (.~), (^.))
import Test.Hspec

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.PParams (emptyPParams)
import Cardano.Ledger.Api.Tx (bodyTxL, witsTxL)
import Cardano.Ledger.Api.Tx.Body (referenceInputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out (TxOut, mkBasicTxOut, referenceScriptTxOutL)
import Cardano.Ledger.Api.Tx.Wits (scriptTxWitsL)
import Cardano.Ledger.BaseTypes (Network (Testnet), StrictMaybe (..))
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Ledger (ConwayTx)
import PlutusCore.Version (plcVersion110)
import PlutusLedgerApi.V3 (serialiseUPLC)
import UntypedPlutusCore qualified as UPLC

import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Ledger (Coin (..), ConwayEra)
import Singular.Registry.Provider (Provider (..))
import Singular.Registry.TxBuilder.Boot (
    BootRefusal (..),
    bootTokenImpl,
 )
import Singular.Registry.TxBuilder.Internal (
    addrFromKeyHashBytes,
    computeScriptHash,
    scriptFromBytes,
    txInToRef,
 )

spec :: Spec
spec = describe "a registry boots only by reference" $ do
    it "refuses a boot from a wallet holding no publication of the state validator, by name" $
        boot [seedUtxo, fundUtxo]
            `shouldThrow` (== StateValidatorNotPublished)

    it "refuses a boot from a wallet whose only publication is another script" $
        boot [seedUtxo, fundUtxo, (refIn, publication otherProgram)]
            `shouldThrow` (== StateValidatorNotPublished)

    it "names the repair in the refusal: publish the state validator first" $
        displayException StateValidatorNotPublished
            `shouldSatisfy` isInfixOf "publish the state validator first"

    it "boots from a wallet holding the publication, referencing it and carrying no script" $ do
        tx <- boot [seedUtxo, fundUtxo, (refIn, publication stateProgram)]
        tx ^. bodyTxL . referenceInputsTxBodyL `shouldBe` Set.singleton refIn
        Map.keys (tx ^. witsTxL . scriptTxWitsL) `shouldBe` []

{- | Run the builder against a wallet and return the transaction it
hands to evaluation. A refusal propagates; a builder that never asked
for evaluation fails the row.
-}
boot :: [(TxIn, TxOut ConwayEra)] -> IO ConwayTx
boot wallet = do
    kept <- newIORef Nothing
    let provider =
            Provider
                { queryUTxOs = \_ -> pure wallet
                , queryProtocolParams = pure emptyPParams
                , evaluateTx = \tx -> do
                    writeIORef kept (Just tx)
                    fail "evaluated"
                , posixMsToSlot = \_ -> fail "boot queries no slot"
                , posixMsCeilSlot = \_ -> fail "boot queries no slot"
                }
    -- Only the stub's IO error is absorbed: a 'BootRefusal' propagates
    -- to the row, and any earlier failure leaves nothing kept.
    _ <- try @IOException (bootTokenImpl cfg provider payer)
    readIORef kept >>= maybe (fail "the boot never reached evaluation") pure

-- | A well-formed PlutusV3 program, distinguished by its arity.
lambdas :: Int -> SBS.ShortByteString
lambdas n =
    serialiseUPLC
        ( UPLC.Program
            ()
            plcVersion110
            ( iterate
                (UPLC.LamAbs () (UPLC.DeBruijn 0))
                (UPLC.Var () (UPLC.DeBruijn 1))
                !! n
            )
        )

stateProgram, otherProgram :: SBS.ShortByteString
stateProgram = lambdas 1
otherProgram = lambdas 2

cfg :: CageConfig
cfg =
    CageConfig
        { cageScriptBytes = stateProgram
        , requestScriptBytes = stateProgram
        , cfgScriptHash = computeScriptHash stateProgram
        , cageSeed = txInToRef seedIn
        , defaultProcessTime = 30_000
        , defaultRetractTime = 30_000
        , defaultTip = Coin 1_000_000
        , cfgApplicationPolicy = SBS.empty
        , cfgActivePolicy = SBS.empty
        , cfgAbsentPolicy = SBS.empty
        , cfgTerminalPolicy = SBS.empty
        , cfgConsumerScript = SBS.empty
        , network = Testnet
        }

outRef :: Char -> TxIn
outRef c =
    either (error . ("BootSpec fixture: " <>)) id $
        parseOutRef (T.pack (replicate 64 c <> "#0"))

seedIn, fundIn, refIn :: TxIn
seedIn = outRef '1'
fundIn = outRef '2'
refIn = outRef '3'

payer :: Addr
payer = addrFromKeyHashBytes Testnet (BS.replicate 28 0x5b)

adaAt :: Integer -> TxOut ConwayEra
adaAt n = mkBasicTxOut payer (MaryValue (Coin n) mempty)

seedUtxo, fundUtxo :: (TxIn, TxOut ConwayEra)
seedUtxo = (seedIn, adaAt 5_000_000)
fundUtxo = (fundIn, adaAt 100_000_000)

-- | A reference output at the payer carrying the given script.
publication :: SBS.ShortByteString -> TxOut ConwayEra
publication bytes =
    adaAt 20_000_000
        & referenceScriptTxOutL .~ SJust (scriptFromBytes "published" bytes)
