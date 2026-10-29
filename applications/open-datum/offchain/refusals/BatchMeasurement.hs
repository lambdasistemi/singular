{-# LANGUAGE CPP #-}
{-# LANGUAGE TypeApplications #-}

-- | Test-only, offline evaluation of retained transaction and input bytes.
module BatchMeasurement (run, keep, readTransaction) where

import Cardano.Ledger.Alonzo.Plutus.Evaluate
    ( TransactionScriptFailure
    )
import Cardano.Ledger.Api.PParams (ppMaxTxExUnitsL, ppMaxTxSizeL)
import Cardano.Ledger.Api.Scripts.Data (getPlutusData)
import Cardano.Ledger.Api.Tx (bodyTxL, sizeTxF, witsTxL)
import Cardano.Ledger.Api.Tx.Body (feeTxBodyL, referenceInputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , coinTxOutL
    , datumTxOutL
    , referenceScriptTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes (Network (Testnet), StrictMaybe (..))
import Cardano.Ledger.Binary
    ( decCBOR
    , decodeFull'
    , decodeFullAnnotator
    , serialize'
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (PParams, eraProtVerLow, hashScript)
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Ledger (ConwayTx)
import Codec.Serialise (serialise)
import Control.Monad (forM_)
import Data.Aeson (eitherDecodeStrict', encode, object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as LBS
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Set qualified as Set
import Data.Text qualified as T
import Lens.Micro ((^.))
import Singular.Application.OpenDatum.Requests.Records
    ( RegistrationData (..)
    , decodeRegistration
    )
import Singular.Registry.Deployment (renderOutRef)
import Singular.Registry.Ledger (ConwayEra)
import Singular.Registry.LocalEvaluation
    ( EvaluationContext (..)
    , evaluateResolved
    )
import Singular.Registry.NetworkTime
    ( NetworkTimeManifest (..)
    , validateNetworkTime
    )
import Singular.State.Assemble (inlineDatumOf)
import Singular.State.Records (Change (..), decodeFoldRedeemer)
import System.Directory (copyFile, createDirectoryIfMissing)
import System.Exit (die)
import System.FilePath ((</>))
import System.IO (Handle, hFlush)

-- | Keep the signed body, its complete raw input extent, and actual node time.
keep
    :: FilePath -> FilePath -> ConwayTx -> [(TxIn, TxOut ConwayEra)] -> IO ()
keep destination timeDirectory tx inputs = do
    createDirectoryIfMissing False destination
    BS.writeFile
        (destination </> "transaction.cbor")
        (serialize' version tx)
    BS.writeFile
        (destination </> "inputs.cbor")
        (serialize' version inputs)
    createDirectoryIfMissing False (destination </> "time")
    forM_
        ["shelley-genesis.json", "era-history.cbor", "time-manifest.json"]
        $ \name ->
            copyFile (timeDirectory </> name) (destination </> "time" </> name)
  where
    version = eraProtVerLow @ConwayEra

{- | Evaluate exactly those bytes with the supplied recorded parameters.
The transaction's devnet time remains its own, bound by its captured manifest.
-}
run :: Handle -> [String] -> IO ()
run out [parametersPath, packet] = do
    rawParameters <- BS.readFile parametersPath
    protocol <-
        either (die . show) pure (decodeFull' version rawParameters)
    rawTx <- BS.readFile (packet </> "transaction.cbor")
    tx <- readTransaction (packet </> "transaction.cbor")
    inputs <-
        BS.readFile (packet </> "inputs.cbor")
            >>= either (die . show) pure . decodeFull' version
    manifest <-
        BS.readFile (packet </> "time/time-manifest.json")
            >>= either die pure . eitherDecodeStrict'
    genesis <- BS.readFile (packet </> "time/shelley-genesis.json")
    history <- BS.readFile (packet </> "time/era-history.cbor")
    time <-
        either (die . show) pure $
            validateNetworkTime
                (timeNetworkMagic manifest)
                manifest
                genesis
                history
    result <-
        either (die . show) pure $
            evaluateResolved (EvaluationContext protocol time) tx inputs
    units <-
        either (die . evaluationFailure) pure $
            sequence (Map.elems result)
    let memory = sum [toInteger n | ExUnits n _ <- units]
        steps = sum [toInteger n | ExUnits _ n <- units]
        ExUnits maximumMemory maximumSteps = protocol ^. ppMaxTxExUnitsL
        bytes = BS.length rawTx
        ledgerBytes = tx ^. sizeTxF
        Coin fee = tx ^. bodyTxL . feeTxBodyL
        Redeemers redeemers = tx ^. witsTxL . rdmrsTxWitsL
        changes =
            concatMap snd $
                mapMaybe
                    (decodeFoldRedeemer . getPlutusData . fst)
                    (Map.elems redeemers)
        limits =
            ["memory" :: T.Text | memory > toInteger maximumMemory]
                <> ["steps" | steps > toInteger maximumSteps]
                <> [ "serialized bytes"
                   | toInteger ledgerBytes > toInteger (protocol ^. ppMaxTxSizeL)
                   ]
        references = tx ^. bodyTxL . referenceInputsTxBodyL
        binding (reference, output) = case output ^. referenceScriptTxOutL of
            SJust script
                | Set.member reference references ->
                    Just
                        ( object
                            [ "output" .= renderOutRef reference
                            , "script" .= show (hashScript script)
                            ]
                        )
            _ -> Nothing
        changed change =
            object
                ( [ "pending" .= renderOutRef (changeRequest change)
                  , "key" .= show (changeKey change)
                  , "keyBytes" .= BS.length (changeKey change)
                  , "kind" .= case change of
                        Register{} -> "registration" :: T.Text
                        Terminate{} -> "termination"
                  ]
                    <> maybe [] (requestFacts change) (lookup (changeRequest change) inputs)
                )
        requestFacts change output =
            let Coin held = output ^. coinTxOutL
                deposit = case change of
                    Register{changeDeposit = amount} -> Just amount
                    Terminate{} -> Nothing
                registration = inlineDatumOf output >>= decodeRegistration Testnet
            in  [ "heldLovelace" .= held
                , "protectedDeposit" .= deposit
                , "folderTake" .= (held - fromMaybe 0 deposit)
                , "datumBytes" .= BS.length (serialize' version (output ^. datumTxOutL))
                , "initialDatum" .= fmap (show . rdInitialDatum) registration
                , "initialDatumBytes"
                    .= fmap (BL.length . serialise . rdInitialDatum) registration
                ]
    LBS.hPutStrLn out $
        encode $
            object
                [ "evaluator"
                    .= object
                        [ "cardano-ledger-core" .= (VERSION_cardano_ledger_core :: T.Text)
                        , "cardano-ledger-alonzo" .= (VERSION_cardano_ledger_alonzo :: T.Text)
                        , "cardano-ledger-binary" .= (VERSION_cardano_ledger_binary :: T.Text)
                        , "cardano-ledger-api" .= (VERSION_cardano_ledger_api :: T.Text)
                        , "entry"
                            .= ("Cardano.Ledger.Alonzo.Plutus.Evaluate.evalTxExUnits" :: T.Text)
                        ]
                , "parameters" .= (protocol :: PParams ConwayEra)
                , "memory" .= memory
                , "steps" .= steps
                , "serializedBytes" .= bytes
                , "ledgerBytes" .= ledgerBytes
                , "fee" .= fee
                , "purposes"
                    .= [ object
                            [ "purpose" .= show purpose
                            , "memory" .= toInteger m
                            , "steps" .= toInteger s
                            ]
                       | (purpose, Right (ExUnits m s)) <- Map.toAscList result
                       ]
                , "changes" .= map changed changes
                , "scriptReferences" .= mapMaybe binding inputs
                , "exceeded" .= limits
                ]
    hFlush out
  where
    version = eraProtVerLow @ConwayEra
run _ _ =
    die
        "usage: no-pin-refusals evaluate-batch PARAMETERS.cbor PACKET-DIRECTORY"

readTransaction :: FilePath -> IO ConwayTx
readTransaction path = do
    bytes <- BS.readFile path
    either (die . show) pure $
        decodeFullAnnotator
            (eraProtVerLow @ConwayEra)
            "retained batch"
            decCBOR
            (BL.fromStrict bytes)

evaluationFailure :: TransactionScriptFailure ConwayEra -> String
evaluationFailure problem = "target evaluation failed: " <> show problem
