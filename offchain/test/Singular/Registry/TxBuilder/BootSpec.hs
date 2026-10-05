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
chosen wallet. The accepted boot uses real local evaluation over synthetic cost material
and exact wallet outputs, then its completed body is inspected. A refused
boot never builds a transaction. The reference input the control expects is the
output the fixture put in the wallet.
-}
module Singular.Registry.TxBuilder.BootSpec (spec) where

import Control.Exception
    ( ErrorCall (..)
    , displayException
    , try
    )
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Either (isRight)
import Data.Foldable (toList)
import Data.IORef (modifyIORef, newIORef, readIORef)
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Lens.Micro ((&), (.~), (^.))
import Test.Hspec

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (bodyTxL, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( inputsTxBodyL
    , referenceInputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , mkBasicTxOut
    , referenceScriptTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits (scriptTxWitsL)
import Cardano.Ledger.BaseTypes (Network (Testnet), StrictMaybe (..))
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Ledger (ConwayTx)
import PlutusCore.MkPlc (mkConstant)
import PlutusCore.Version (plcVersion110)
import PlutusLedgerApi.V3 (serialiseUPLC)
import Singular.Registry.SyntheticLedger (withSyntheticCosts)
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.TxBuilder.BookingFixture (preprodParams)
import UntypedPlutusCore qualified as UPLC

import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Ledger (Coin (..), ConwayEra)
import Singular.Registry.Provider (Provider, View (..))
import Singular.Registry.StubView (servingView, stubView)
import Singular.Registry.TxBuilder.Boot
    ( BootRefusal (..)
    , bootTokenImpl
    )
import Singular.Registry.TxBuilder.Edges
    ( publishRefScript
    , publishRefScriptReserving
    , publishStateRefReserving
    )
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , computeScriptHash
    , scriptFromBytes
    , txInToRef
    )

spec :: Spec
spec = do
    bootsByReference
    publicationBeforeBoot

bootsByReference :: Spec
bootsByReference = describe "a registry boots only by reference" $ do
    it
        "refuses a boot from a wallet holding no publication of the state validator, by name"
        $ boot [seedUtxo, fundUtxo]
            `shouldThrow` (== StateValidatorNotPublished)

    it
        "refuses a boot from a wallet whose only publication is another script"
        $ boot [seedUtxo, fundUtxo, (refIn, publication otherProgram)]
            `shouldThrow` (== StateValidatorNotPublished)

    it
        "names the repair in the refusal: publish the state validator first"
        $ displayException StateValidatorNotPublished
            `shouldSatisfy` isInfixOf "publish the state validator first"

    it
        "boots from a wallet holding the publication, referencing it and carrying no script"
        $ do
            tx <- boot [seedUtxo, fundUtxo, (refIn, publication stateProgram)]
            tx ^. bodyTxL . referenceInputsTxBodyL `shouldBe` Set.singleton refIn
            Map.keys (tx ^. witsTxL . scriptTxWitsL) `shouldBe` []

{- | The reference publication a create makes before its boot (#299). The
create chooses its seed first — the output the boot will consume, the
configuration's 'cageSeed', from which the registry's state asset name is
derived — so the publication must fund itself from any other ada-only
output. Each row runs the real builder against a chosen wallet and reads
back exactly what it handed to the submission callback.
-}
publicationBeforeBoot :: Spec
publicationBeforeBoot = describe "the reference publication before a boot" $ do
    it
        "never spends the boot's seed, even when it is the largest output"
        $ do
            txInToRef seedIn `shouldBe` cageSeed cfg
            (submitted, result) <-
                publish
                    (reservingScript (Set.singleton seedIn))
                    [bigSeed, alternative]
            map spent submitted `shouldBe` [[fundIn]]
            result `shouldSatisfy` isRight

    it
        "without a reservation funds from the largest ada-only output, as before"
        $ do
            (legacy, _) <- publish legacyScript [bigSeed, alternative]
            (unreserved, _) <-
                publish (reservingScript Set.empty) [bigSeed, alternative]
            map spent legacy `shouldBe` [[seedIn]]
            map spent unreserved `shouldBe` [[seedIn]]

    it
        "refuses before submitting when every ada-only output is reserved"
        $ do
            (submitted, result) <-
                publish (reservingScript (Set.singleton seedIn)) [bigSeed]
            map spent submitted `shouldBe` []
            case result of
                Left (ErrorCall why) -> why `shouldSatisfy` isInfixOf "no ada-only output"
                Right _ -> expectationFailure "the publication spent the reserved seed"

    it
        "reuses a state validator already published, submitting nothing"
        $ do
            (submitted, result) <-
                publish
                    (reservingState (Set.singleton seedIn))
                    [bigSeed, alternative, (refIn, publication stateProgram)]
            map spent submitted `shouldBe` []
            either (Left . show) (Right . fst) result `shouldBe` Right refIn

    it
        "publishes the state validator from outside the reservation when none is published"
        $ do
            (submitted, _) <-
                publish (reservingState (Set.singleton seedIn)) [bigSeed, alternative]
            map spent submitted `shouldBe` [[fundIn]]
  where
    bigSeed = (seedIn, adaAt 900_000_000)
    alternative = (fundIn, adaAt 50_000_000)
    script = scriptFromBytes "published" stateProgram
    legacyScript p s a = publishRefScript p s a script
    reservingScript reserved p s a = publishRefScriptReserving reserved p s a script
    reservingState reserved = publishStateRefReserving reserved cfg
    spent tx = toList (tx ^. bodyTxL . inputsTxBodyL)

{- | Run a publication against a wallet. The submission callback keeps every
transaction it is handed and returns it as signed; a refusal is returned,
not rethrown, so a row can require that nothing was submitted.
-}
publish
    :: (Provider IO -> (ConwayTx -> IO ConwayTx) -> Addr -> IO a)
    -> [(TxIn, TxOut ConwayEra)]
    -> IO ([ConwayTx], Either ErrorCall a)
publish run wallet = do
    kept <- newIORef []
    let provider =
            servingView
                stubView
                    { viewUTxOsAt = \_ -> pure wallet
                    }
        submit tx = do
            modifyIORef kept (<> [tx])
            pure tx
    result <- try (run provider submit payer)
    submitted <- readIORef kept
    pure (submitted, result)

{- | Run the builder against exact wallet outputs and synthetic ledger
material, returning its completed transaction. A refusal propagates.
-}
boot :: [(TxIn, TxOut ConwayEra)] -> IO ConwayTx
boot wallet =
    let provider =
            stubView
                { viewUTxOsAt = \_ -> pure wallet
                , viewProtocolParams = withSyntheticCosts preprodParams
                , viewTimeContext = pure syntheticTime
                , viewResolvedOutputs = \wanted ->
                    pure
                        [ (reference, output)
                        | (reference, output) <- wallet
                        , reference `Set.member` wanted
                        ]
                }
    in  bootTokenImpl cfg provider payer

-- | A well-formed PlutusV3 program, distinguished by its arity.
lambdas :: Int -> SBS.ShortByteString
lambdas n =
    serialiseUPLC
        ( UPLC.Program
            ()
            plcVersion110
            ( iterate
                (UPLC.LamAbs () (UPLC.DeBruijn 0))
                (mkConstant () ())
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
