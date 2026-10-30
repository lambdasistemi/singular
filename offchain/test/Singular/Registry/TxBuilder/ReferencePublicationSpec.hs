{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.TxBuilder.ReferencePublicationSpec
Description : Reference publications preserve the reserved seed
License     : Apache-2.0

The retained publication builders fund from outside the reserved seed and
reuse a live publication without submitting. These are builder-level
checks against a synthetic wallet, not ledger acceptance.
-}
module Singular.Registry.TxBuilder.ReferencePublicationSpec (spec) where

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (EraTx (bodyTxL))
import Cardano.Ledger.Api.Tx.Body (EraTxBody (inputsTxBodyL))
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , mkBasicTxOut
    , referenceScriptTxOutL
    )
import Cardano.Ledger.BaseTypes
    ( Network (Testnet)
    , StrictMaybe (SJust)
    )
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Ledger (ConwayTx)
import Control.Exception (ErrorCall (ErrorCall), try)
import Data.ByteString qualified as BS (replicate)
import Data.ByteString.Short qualified as SBS
    ( ShortByteString
    , empty
    )
import Data.Either (isRight)
import Data.Foldable (toList)
import Data.IORef (modifyIORef, newIORef, readIORef)
import Data.List (isInfixOf)
import Data.Set qualified as Set (empty, singleton)
import Data.Text qualified as T (pack)
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.MkPlc (mkConstant)
import PlutusCore.Version (plcVersion110)
import PlutusLedgerApi.V3 (serialiseUPLC)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (Coin (..), ConwayEra)
import Singular.Registry.LedgerProvider (LedgerProvider)
import Singular.Registry.LedgerProvider qualified as LedgerProvider
    ( Network
    )
import Singular.Registry.StubSession
    ( servingSession
    , stubSession
    , withAddressOutputs
    , withTime
    )
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , computeScriptHash
    , scriptFromBytes
    , txInToRef
    )
import Singular.Registry.TxBuilder.Publication
    ( publishRefScript
    , publishRefScriptReserving
    , publishStateRefReserving
    )
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldSatisfy
    )
import UntypedPlutusCore qualified as UPLC
    ( DeBruijn (DeBruijn)
    , Program (Program)
    , Term (LamAbs)
    )

spec :: Spec
spec = do
    referencePublication

{- | The reference publication a create makes before its boot (#299). The
create chooses its seed first — the output the boot will consume, the
configuration's 'cageSeed', from which the registry's state asset name is
derived — so the publication must fund itself from any other ada-only
output. Each row runs the real builder against a chosen wallet and reads
back exactly what it handed to the submission callback.
-}
referencePublication :: Spec
referencePublication = describe "reference publication with a reserved seed" $ do
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
    :: ( (LedgerProvider.Network, LedgerProvider NoWitness IO)
         -> (ConwayTx -> IO ConwayTx)
         -> Addr
         -> IO a
       )
    -> [(TxIn, TxOut ConwayEra)]
    -> IO ([ConwayTx], Either ErrorCall a)
publish run wallet = do
    kept <- newIORef []
    let provider =
            servingSession
                ( withAddressOutputs (\_ -> pure wallet) $
                    withTime (pure syntheticTime) stubSession
                )
        submit tx = do
            modifyIORef kept (<> [tx])
            pure tx
    result <- try (run provider submit payer)
    submitted <- readIORef kept
    pure (submitted, result)

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

stateProgram :: SBS.ShortByteString
stateProgram = lambdas 1

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

-- | A reference output at the payer carrying the given script.
publication :: SBS.ShortByteString -> TxOut ConwayEra
publication bytes =
    adaAt 20_000_000
        & referenceScriptTxOutL .~ SJust (scriptFromBytes "published" bytes)
