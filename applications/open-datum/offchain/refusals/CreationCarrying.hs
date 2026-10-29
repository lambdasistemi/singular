{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : CreationCarrying
Description : Measure creation forms with the real builders and the development node
License     : Apache-2.0

This test tool never changes a production builder or command. It composes the
ordinary genesis and application configuration builders with their public
script-source choices. Creating reference outputs cannot make those outputs
inputs of the same transaction: that form also attaches both witnesses.
Every built form is signed and submitted once to the development node. A node
acceptance, followed by confirmation, is required before a form can fit.
-}
module CreationCarrying (run) where

import Cardano.Binary (serialize')
import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body (feeTxBodyL)
import Cardano.Ledger.Api.Tx.Out
    ( coinTxOutL
    , getMinCoinTxOut
    , mkBasicTxOut
    , referenceScriptTxOutL
    )
import Cardano.Ledger.BaseTypes (Inject (..), StrictMaybe (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (PParams, Script, hashScript)
import Cardano.Ledger.Mary.Value (PolicyID (..))
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)
import Control.Monad (forM, forM_, unless, when)
import Control.Tracer (nullTracer)
import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy.Char8 qualified as BL
import Data.Map.Strict qualified as Map
import Lens.Micro ((&), (.~), (^.))
import Numeric (showHex)
import System.Exit (die)
import System.IO (Handle, hFlush)
import Text.Read (readMaybe)

import Singular.Application.OpenDatum.Registration (openDatumHost)
import Singular.Application.OpenDatum.Requests.Records
    ( RequestParameters (..)
    )
import Singular.Application.OpenDatum.Requests.Script
    ( requestScriptFromBlueprint
    )
import Singular.CLI.State (Host (..))
import Singular.CLI.Steps (scriptSource)
import Singular.Registry.Blueprint (loadBlueprint)
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Deployment (renderOutRef)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (ConwayEra, TxOut)
import Singular.Registry.LedgerProvider (SubmitResult (..))
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.SessionIO qualified as Services
import Singular.Registry.Signing (signTx, signedTx)
import Singular.Registry.Terminal (withReads)
import Singular.Registry.Wallet (Wallet (..), loadWallet)
import Singular.State.Assemble (Payer (..), resolvePayer)
import Singular.State.Genesis (buildGenesis)
import Singular.State.Publication
    ( Publication (..)
    , References (..)
    , planNextReference
    )
import Singular.State.Script
    ( ScriptSource (..)
    , StateScript (..)
    , referenceOutputs
    , stateScriptFromBlueprint
    )

-- | Explicit development-network flags, matching the other test harnesses.
run :: Handle -> [String] -> IO ()
run out flags = do
    url <- need "--koios-url"
    timeDirectory <- need "--network-time"
    magicText <- need "--network-magic"
    key <- need "--wallet-skey"
    blueprintFile <- need "--blueprint"
    outputDirectory <- need "--output-directory"
    magic <-
        maybe (die "network magic is not a number") pure (readMaybe magicText)
    unless
        (magic == 42)
        (die "creation measurement requires the development network")
    wallet <- loadWallet magic key
    blueprint <- loadBlueprint blueprintFile >>= either die pure
    application <- either die pure (requestScriptFromBlueprint blueprint)
    state <-
        either
            die
            pure
            (stateScriptFromBlueprint blueprint (PolicyID (hashScript application)))
    let settings = ProviderSettings url magic Nothing (Just timeDirectory)
    withReads nullTracer nullTracer settings $ \caps -> do
        publications <- publishMissing caps wallet [state, application]
        forms <- forM choices $ \(name, attachState, attachApplication, carryOutputs) ->
            Services.withLatest (capReads caps) $ \session -> do
                protocol <- Services.parameters session
                found <-
                    planNextReference [] session (walletAddr wallet) [state, application]
                        >>= either (fail . show) pure
                unless
                    (nothingPublished found)
                    (fail "the live publication setup changed")
                let sources =
                        [(hash, reference) | (hash, (reference, _)) <- referencesLive found]
                    stateSource = if attachState then Attached else scriptSource state sources
                    applicationSource =
                        if attachApplication
                            then Attached
                            else scriptSource application sources
                    host =
                        openDatumHost (RequestParameters 3000000 1000000 60000 180000 60000)
                payer <-
                    resolvePayer session (walletAddr wallet) >>= either (fail . show) pure
                let seed = fst (payerFunding payer)
                applicationReferences <-
                    referenceOutputs session application applicationSource
                        >>= either (fail . show) pure
                (tx, _) <-
                    buildGenesis
                        session
                        (StateScript state stateSource)
                        seed
                        (walletAddr wallet)
                        applicationReferences
                        ( \registry -> do
                            hostCreation host [(application, applicationSource)] seed registry
                            when carryOutputs $
                                forM_
                                    [state, application]
                                    (Tx.output . holder protocol (walletAddr wallet))
                        )
                        >>= either (fail . show) pure
                evaluated <- Services.evaluateTx session tx
                let signed = signTx (walletSignKey wallet) tx
                    bytes = serialize' (signedTx signed)
                BS.writeFile (outputDirectory <> "/" <> name <> ".cbor") bytes
                node <- submit caps (signedTx signed) (capSubmit caps signed)
                let measured =
                        object
                            [ "form" .= name
                            , "stateSource" .= sourceText stateSource
                            , "applicationSource" .= sourceText applicationSource
                            , "createsReferenceOutputs" .= carryOutputs
                            , "seed" .= renderOutRef seed
                            , "signedTransactionCBOR" .= hex bytes
                            , "sizeBytes" .= BS.length bytes
                            , "feeLovelace" .= (tx ^. bodyTxL . feeTxBodyL)
                            , "protocolParameters" .= protocol
                            , "evaluation"
                                .= [ evaluation purpose result
                                   | (purpose, result) <- Map.toAscList evaluated
                                   ]
                            , "node" .= node
                            ]
                BL.writeFile
                    (outputDirectory <> "/" <> name <> ".json")
                    (encode measured)
                pure measured
        BL.hPutStrLn
            out
            ( encode
                ( object
                    [ "schema" .= ("creation-carrying-v1" :: String)
                    , "publications" .= publications
                    , "forms" .= forms
                    ]
                )
            )
        hFlush out
  where
    need name = maybe (die ("missing " <> name)) pure (flag name flags)

-- | The two mixed directions are distinct experiments.
choices :: [(String, Bool, Bool, Bool)]
choices =
    [ ("referenced", False, False, False)
    , ("witnesses", True, True, False)
    , ("reference-outputs", True, True, True)
    , ("state-witness", True, False, False)
    , ("application-witness", False, True, False)
    ]

sourceText :: ScriptSource -> String
sourceText Attached = "witness"
sourceText (Referenced _) = "live reference output"

flag :: String -> [String] -> Maybe String
flag name (key : value : rest)
    | name == key = Just value
    | otherwise = flag name (value : rest)
flag _ _ = Nothing

hex :: BS.ByteString -> String
hex =
    concatMap
        ( \byte ->
            let digits = showHex byte ""
            in  replicate (2 - length digits) '0' <> digits
        )
        . BS.unpack

nothingPublished :: References -> Bool
nothingPublished references = case referencesPublication references of
    Nothing -> True
    Just _ -> False

{- | Live copies are prerequisites only for forms that read them. Publication
uses the unchanged sequential production builder and is reported separately.
-}
publishMissing
    :: Capabilities NoWitness IO
    -> Wallet
    -> [Script ConwayEra]
    -> IO [Value]
publishMissing caps wallet scripts = do
    next <- Services.withLatest (capReads caps) $ \session ->
        planNextReference [] session (walletAddr wallet) scripts
            >>= either (fail . show) pure
    case referencesPublication next of
        Nothing -> pure []
        Just publication -> do
            let signed = signTx (walletSignKey wallet) (publicationTx publication)
            accepted <- capSubmit caps signed
            answer <- case accepted of
                SubmitAccepted identity -> do
                    capConfirm caps (signedTx signed)
                    pure
                        ( object
                            ["outcome" .= ("accepted" :: String), "transaction" .= show identity]
                        )
                other ->
                    fail
                        ("prerequisite publication did not succeed; no retry: " <> show other)
            remaining <- publishMissing caps wallet scripts
            pure (answer : remaining)

submit
    :: Capabilities NoWitness IO -> ConwayTx -> IO SubmitResult -> IO Value
submit caps tx action =
    action >>= \case
        SubmitAccepted identity -> do
            capConfirm caps tx
            pure
                ( object
                    ["outcome" .= ("accepted" :: String), "transaction" .= show identity]
                )
        SubmitRefused why ->
            pure
                ( object
                    [ "outcome" .= ("refused" :: String)
                    , "reason" .= why
                    , "transaction" .= show (txIdTx tx)
                    ]
                )
        other ->
            fail ("node submission did not yield a ledger answer: " <> show other)

holder
    :: PParams ConwayEra -> Addr -> Script ConwayEra -> TxOut ConwayEra
holder protocol address script =
    probe & coinTxOutL .~ getMinCoinTxOut protocol probe
  where
    probe =
        mkBasicTxOut address (inject (Coin 1000000000))
            & referenceScriptTxOutL .~ SJust script

evaluation
    :: (Show purpose, Show failure)
    => purpose -> Either failure ExUnits -> Value
evaluation purpose result =
    object
        [ "purpose" .= show purpose
        , "result" .= case result of
            Left failure -> object ["failure" .= show failure]
            Right (ExUnits memory steps) -> object ["memory" .= memory, "steps" .= steps]
        ]
