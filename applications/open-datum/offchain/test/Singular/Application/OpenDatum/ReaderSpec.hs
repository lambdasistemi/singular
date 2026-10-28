{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Application.OpenDatum.ReaderSpec
Description : Registry reading over a history produced by the current builders
License     : Apache-2.0

Creation, registration and termination are built and applied in order. Both
compiled scripts judge every booking and fold. The reader reconstructs that
history through its provider session; no terminal trie is supplied to it.
-}
module Singular.Application.OpenDatum.ReaderSpec (spec) where

import Control.Monad (forM_)
import Control.Tracer (nullTracer)
import Data.Aeson
    ( Key
    , Value (..)
    , eitherDecodeStrict'
    , encode
    , object
    , toJSON
    , (.=)
    )
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BL
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC
import Singular.Application.OpenDatum.CommandRunSpec (captured)
import Singular.Application.OpenDatum.Root (runPackagedOpenDatumVia)
import Singular.Application.OpenDatum.Value qualified as Host
import Singular.CLI.Root (runPackagedVia)
import Singular.CLI.Session (Env (..))
import Singular.Registry.Address (renderRegistryAddress)
import Singular.Registry.Capabilities (Capabilities (..))
import System.Exit (ExitCode (..))
import Test.Hspec

import Cardano.Crypto.Hash (hashToBytes)
import Cardano.Ledger.Api.Tx.Out (datumTxOutL, valueTxOutL)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Mary.Value (MaryValue (..), PolicyID (..))

import Singular.Application.OpenDatum.CreationWorld
import Singular.Application.OpenDatum.Reader qualified as App
import Singular.Application.OpenDatum.RequestHoldingSpec
    ( withHoldingIn
    )
import Singular.Application.OpenDatum.RequestWorld
    ( expectBuilt
    , inlineDatum
    , network
    , outputRef
    )
import Singular.Application.OpenDatum.Requests.Fold
    ( openDatumApplication
    )
import Singular.Application.OpenDatum.Requests.Holding
    ( buildBookTermination
    )
import Singular.Application.OpenDatum.Requests.Records
    ( ProtectedControl (..)
    , decodeLiveDatum
    )
import Singular.Application.OpenDatum.Requests.Script
    ( requestPolicy
    , requestScriptHash
    )
import Singular.Reader qualified as R
import Singular.Registry.ContractTable
    ( ApplicationIdentity (..)
    , ContractTable
    , applicationOf
    , parseContractTable
    )
import Singular.Registry.Evidence (Evidenced (..))
import Singular.Registry.Ledger (ConwayEra, Root (..), TxOut)
import Singular.Registry.LedgerProvider qualified as LP
import Singular.Registry.PlainJson (PayloadView (..), payloadView)
import Singular.Registry.TrieState
    ( RegistryIdentity (..)
    , StatePolicyId (..)
    )
import Singular.Registry.TxBuilder.Internal (mkInlineDatum)
import Singular.State.Fold (buildRegistrationFold)
import Singular.State.Lineage (registryAsset)
import Singular.State.Preimage (activeTokenName)
import Singular.State.Records (decodeStateDatum)

spec :: Spec
spec = do
    historySpec
    refinementSpec
    commandSpec

historySpec :: Spec
historySpec = describe "reader absence follows the public history" $ do
    forM_
        [ ("terminal", "a live key", R.Terminal)
        , ("never registered", "unused key", R.NeverRegistered)
        ]
        $ \(label, key, conclude) ->
            it
                ( "reads "
                    <> label
                    <> " only against the state reached by registration and termination"
                )
                $ withHoldingIn newCreation
                $ \world registry reference _ -> do
                    booking <- withSession world $ \session ->
                        expectBuilt
                            =<< buildBookTermination
                                session
                                (crRequest world)
                                reference
                                (crBooker world)
                    judge world booking >>= (`shouldSatisfy` everyScriptAccepts)
                    applyTx world booking
                    let (policy, _) = requiredAsset registry
                        requestIndex = holderIndex policy (activeTokenName registry "a live key") booking
                    foldTx <- withSession world $ \session -> do
                        app <-
                            expectBuilt =<< openDatumApplication session (crRequest world) network
                        expectBuilt
                            =<< buildRegistrationFold
                                session
                                (crState world)
                                app
                                registry
                                [outputRef booking requestIndex]
                                (crFolder world)
                    judge world foldTx >>= (`shouldSatisfy` everyScriptAccepts)
                    applyTx world foldTx
                    (code, document) <- commandRead False world registry key ["--json"]
                    code `shouldBe` ExitSuccess
                    documentField "answer" document
                        `shouldBe` Just
                            ( String
                                (if label == "terminal" then "terminal" else "never-registered")
                            )
                    (appCode, appDocument) <-
                        commandRead True world registry key ["--json"]
                    appCode `shouldBe` ExitSuccess
                    documentField "answer" appDocument
                        `shouldBe` documentField "answer" document
                    table <- tableFor world registry
                    withSession world $ \session -> do
                        state <- selectedState session registry
                        let asked = R.ReaderRequest (LP.sessionNetwork session) registry key
                        seen <- newIORef ([] :: [T.Text])
                        let note label' action = modifyIORef' seen (<> [label']) >> action
                            observed =
                                session
                                    { LP.servedNetwork = note "network" (LP.servedNetwork session)
                                    , LP.outputs = \query ->
                                        note
                                            ( if query == LP.HoldingAsset (requiredAsset registry)
                                                then "state"
                                                else "active"
                                            )
                                            (LP.outputs session query)
                                    , LP.history = \asset range -> note "history" (LP.history session asset range)
                                    }
                        R.readNeutralKeyFromSession observed table asked
                            `shouldReturn` conclude state
                        readIORef seen
                            `shouldReturn` ["network", "active", "state", "history"]
    it
        "keeps missing or truncated replay history unavailable beside a complete unused-key control"
        $ withHoldingIn newCreation
        $ \world registry _ _ -> do
            table <- tableFor world registry
            withSession world $ \session -> do
                state <- selectedState session registry
                let asked = R.ReaderRequest (LP.sessionNetwork session) registry "unused key"
                    failure =
                        LP.HistoryReadFailure
                            (LP.BackendReadFailure "history page incomplete")
                    absent = session{LP.history = \_ _ -> pure (Left failure)}
                    truncated =
                        session
                            { LP.history = \asset range ->
                                fmap
                                    (fmap (const (LP.HistoryStream (pure (Left failure)))))
                                    (LP.history session asset range)
                            }
                R.readNeutralKeyFromSession session table asked
                    `shouldReturn` R.NeverRegistered state
                forM_ [absent, truncated] $ \broken ->
                    R.readNeutralKeyFromSession broken table asked
                        >>= ( `shouldSatisfy`
                                \case
                                    R.Unavailable R.TrieRead (R.Failed why) -> T.isInfixOf "history page incomplete" why
                                    _ -> False
                            )

-- | Read the selected output and its datum from the provider independently.
selectedState
    :: LP.Session w IO -> RegistryIdentity -> IO R.ReaderState
selectedState session registry = do
    pairs <-
        LP.outputs session (LP.HoldingAsset (requiredAsset registry))
            >>= either (fail . show) (pure . value)
    case pairs of
        [pair@(_, output)] -> case inlineDatum output >>= decodeStateDatum of
            Just root -> pure (R.ReaderState pair (Root root))
            _ -> fail "state output has no root"
        _ -> fail "state output is not unique"

requiredAsset :: RegistryIdentity -> LP.Asset
requiredAsset registry =
    fromMaybe (error "invalid registry identity") (registryAsset registry)

-- | Application identities are obtained from the compiled validators in this world.
tableFor :: Creation -> RegistryIdentity -> IO ContractTable
tableFor world (RegistryIdentity (StatePolicyId policy) _) =
    either (fail . T.unpack) pure $
        parseContractTable $
            BL.toStrict $
                encode $
                    object ["rows" .= ([] :: [Value]), "applications" .= [release]]
  where
    PolicyID (ScriptHash application) = requestPolicy (crRequest world)
    ScriptHash script = requestScriptHash (crRequest world)
    release =
        ApplicationIdentity
            policy
            (hashToBytes application)
            (hashToBytes script)
            []
            []

refinementSpec :: Spec
refinementSpec = describe "application reader refinement" $ do
    it "reads a live holding through the shared neutral adapter" $
        withHoldingIn newCreation $ \world registry reference _ -> do
            table <- tableFor world registry
            withSession world $ \session -> do
                let request = R.ReaderRequest (LP.sessionNetwork session) registry "a live key"
                App.readKey session table request
                    >>= ( `shouldSatisfy`
                            \case
                                App.Live (found, _) control _ ->
                                    found == reference
                                        && controlRegistry control == registry
                                        && controlKey control == "a live key"
                                _ -> False
                        )
    it
        "reads the current holding wire and its protected control and payload"
        $ withHoldingIn newCreation
        $ \world registry reference output -> do
            table <- tableFor world registry
            withSession world $ \session -> do
                let request = R.ReaderRequest (LP.sessionNetwork session) registry "a live key"
                    RegistryIdentity (StatePolicyId policy) _ = registry
                    release = applicationOf table policy
                    pair = (reference, output)
                (deposit, payload) <- case inlineDatum output of
                    Just (PLC.Constr 2 [PLC.Constr 0 [_, _, _, _, PLC.I amount], body]) -> pure (amount, body)
                    _ -> fail "producer did not write the current live wire"
                let (activePolicy, _) = requiredAsset registry
                    control =
                        ProtectedControl
                            registry
                            (activePolicy, activeTokenName registry "a live key")
                            "a live key"
                            (controllerOf (crBooker world))
                            deposit
                    expected = App.Live pair control payload
                App.refineReaderAnswer request release (R.Active pair)
                    `shouldBe` expected
                App.readKey session table request `shouldReturn` expected
                let malformed =
                        [ PLC.I 0
                        , PLC.Constr 0 []
                        , PLC.Constr 2 [PLC.I 0, payload]
                        , case inlineDatum output of
                            Just
                                (PLC.Constr 2 [PLC.Constr 0 [reg, asset, key, controller, _], body]) ->
                                    PLC.Constr
                                        2
                                        [ PLC.Constr
                                            0
                                            [reg, asset, key, controller, PLC.I (lovelace output + 1)]
                                        , body
                                        ]
                            _ -> error "unreachable current holding"
                        ]
                forM_ malformed $ \datum ->
                    App.refineReaderAnswer
                        request
                        release
                        (R.Active (reference, output & datumTxOutL .~ mkInlineDatum datum))
                        `shouldBe` App.Refused R.ConflictingEvidence
                bindings <- case inlineDatum output of
                    Just
                        (PLC.Constr 2 [PLC.Constr 0 [reg, asset, _, controller, amount], body]) -> do
                            let live fields = PLC.Constr 2 [PLC.Constr 0 fields, body]
                            pure
                                [ live [reg, asset, PLC.B "different key", controller, amount]
                                , live [reg, asset, PLC.B "a live key", controller, PLC.I (-1)]
                                , case reg of
                                    PLC.Constr 0 [policyData, _] ->
                                        live
                                            [ PLC.Constr 0 [policyData, PLC.B "another registry"]
                                            , asset
                                            , PLC.B "a live key"
                                            , controller
                                            , amount
                                            ]
                                    _ -> error "invalid produced registry"
                                , case asset of
                                    PLC.Constr 0 [policyData, _] ->
                                        live
                                            [ reg
                                            , PLC.Constr 0 [policyData, PLC.B "another asset"]
                                            , PLC.B "a live key"
                                            , controller
                                            , amount
                                            ]
                                    _ -> error "invalid produced asset"
                                ]
                    _ -> fail "no current live datum"
                forM_ bindings $ \datum ->
                    App.refineReaderAnswer
                        request
                        release
                        (R.Active (reference, output & datumTxOutL .~ mkInlineDatum datum))
                        `shouldBe` App.Refused R.ConflictingEvidence
                App.refineReaderAnswer request Nothing (R.Active pair)
                    `shouldBe` App.Refused (R.UnknownStatePolicy policy)
    it
        "recognises the termination booking's exact two tokens and empty datum"
        $ withHoldingIn newCreation
        $ \world registry reference _ -> do
            booking <- withSession world $ \session ->
                expectBuilt
                    =<< buildBookTermination
                        session
                        (crRequest world)
                        reference
                        (crBooker world)
            judge world booking >>= (`shouldSatisfy` everyScriptAccepts)
            applyTx world booking
            table <- tableFor world registry
            let (policy, _) = requiredAsset registry
                index = holderIndex policy (activeTokenName registry "a live key") booking
            output <-
                maybe
                    (fail "no termination output")
                    pure
                    (outputAtIndex booking index)
            withSession world $ \session -> do
                let request = R.ReaderRequest (LP.sessionNetwork session) registry "a live key"
                    RegistryIdentity (StatePolicyId policyBytes) _ = registry
                    release = applicationOf table policyBytes
                    pair = (outputRef booking index, output)
                App.refineReaderAnswer request release (R.Active pair)
                    `shouldBe` App.PendingTermination pair
                App.readKey session table request
                    `shouldReturn` App.PendingTermination pair
                App.refineReaderAnswer
                    request
                    release
                    (R.Active (fst pair, output & datumTxOutL .~ mkInlineDatum (PLC.I 0)))
                    `shouldBe` App.Refused R.ConflictingEvidence
    it "retains neutral state answers, refusals and unavailable reads" $
        withHoldingIn newCreation $ \world registry _ _ -> do
            table <- tableFor world registry
            withSession world $ \session -> do
                state <- selectedState session registry
                let request = R.ReaderRequest (LP.sessionNetwork session) registry "unused key"
                    RegistryIdentity (StatePolicyId policy) _ = registry
                    release = applicationOf table policy
                    reasons =
                        [ R.Missing
                        , R.Failed "offline"
                        , R.Incomplete "partial"
                        , R.StateNotFound
                        , R.StateNotRecognized
                        , R.TrieRootMismatch
                        ]
                    refusals =
                        [ R.ConflictingEvidence
                        , R.WrongNetwork (LP.Network 1) (LP.Network 42)
                        , R.UnknownStatePolicy policy
                        , R.ForeignStatePolicy policy (BS.replicate 28 0)
                        ]
                forM_
                    [ (R.Terminal state, App.Terminal state)
                    , (R.NeverRegistered state, App.NeverRegistered state)
                    ]
                    $ \(neutral, refined) ->
                        App.refineReaderAnswer request release neutral `shouldBe` refined
                forM_ [R.NetworkRead, R.ActiveOutputsRead, R.StateRead, R.TrieRead] $ \readName ->
                    forM_ reasons $ \reason ->
                        App.refineReaderAnswer request release (R.Unavailable readName reason)
                            `shouldBe` App.Unavailable readName reason
                forM_ refusals $ \reason ->
                    App.refineReaderAnswer request release (R.Refused reason)
                        `shouldBe` App.Refused reason

lovelace :: TxOut ConwayEra -> Integer
lovelace output = let MaryValue (Coin amount) _ = output ^. valueTxOutL in amount

commandSpec :: Spec
commandSpec = describe "inspect through the packaged application command" $ do
    it
        "shows the control, protected deposit and plain payload of a produced live holding" $
        withHoldingIn newCreation $ \world registry _ output -> do
            let protected = inlineDatum output >>= decodeLiveDatum
            (_, payload) <-
                maybe (fail "builder produced no live datum") pure protected
            (code, document) <-
                commandRead True world registry "a live key" ["--json"]
            code `shouldBe` ExitSuccess
            documentField "answer" document `shouldBe` Just (String "live")
            documentField "payload" document
                `shouldBe` Just (viewJson (payloadView payload))
            documentField "payloadSchema" document
                `shouldBe` Just (String "plain")
            documentField "deposit" document
                `shouldBe` fmap (toJSON . controlDeposit . fst) protected
            documentField "control" document
                `shouldSatisfy` maybe False (\case Object _ -> True; _ -> False)
    it
        "shows pending termination after booking, while the neutral command still answers active" $
        withHoldingIn newCreation $ \world registry reference _ -> do
            booking <- withSession world $ \session ->
                expectBuilt
                    =<< buildBookTermination
                        session
                        (crRequest world)
                        reference
                        (crBooker world)
            judge world booking >>= (`shouldSatisfy` everyScriptAccepts)
            applyTx world booking
            (code, document) <-
                commandRead True world registry "a live key" ["--json"]
            code `shouldBe` ExitSuccess
            documentField "answer" document
                `shouldBe` Just (String "pending-termination")
            (neutralCode, neutralDocument) <-
                commandRead False world registry "a live key" ["--json"]
            neutralCode `shouldBe` ExitSuccess
            documentField "answer" neutralDocument
                `shouldBe` Just (String "active")
            documentField "datum" neutralDocument `shouldBe` Just Null

-- | The command uses the history the builders produced; no conclusion is injected.
commandRead
    :: Bool
    -> Creation
    -> RegistryIdentity
    -> BS.ByteString
    -> [String]
    -> IO (ExitCode, Value)
commandRead application world registry key extra = do
    address <-
        maybe
            (fail "registry has no address")
            pure
            (renderRegistryAddress 42 (requiredAsset registry))
    let provider _ =
            Env
                { envTracer = nullTracer
                , envSource = "builder fixture"
                , envLoadRelease = \_ _ -> fail "inspect read a blueprint"
                , envReads = \_ use ->
                    use
                        Capabilities
                            { capReads =
                                ( network
                                , LP.LedgerProvider
                                    { LP.acquire = \_ action -> Right <$> withSession world action
                                    , LP.submitTx = \_ _ -> fail "inspect submitted"
                                    }
                                )
                            , capSubmit = \_ -> fail "inspect submitted"
                            , capConfirm = \_ -> fail "inspect confirmed"
                            , capFacts = pure []
                            , capTrace = pure []
                            }
                , envWrites = \_ _ -> fail "inspect opened a writer"
                }
        line =
            (if application then ["inspect"] else ["registry", "inspect"])
                <> [ "--registry"
                   , T.unpack address
                   , "--koios-url"
                   , "http://fixture.invalid"
                   , "--key-hex"
                   , T.unpack (TE.decodeUtf8 (B16.encode key))
                   ]
                <> extra
        run = if application then runPackagedOpenDatumVia else runPackagedVia
    (code, out, err) <-
        captured (run provider Host.openDatumApplication (pure Nothing) line [])
    document <-
        either
            (fail . (<> "; stdout=" <> show out <> "; stderr=" <> show err))
            pure
            (eitherDecodeStrict' out)
    pure (code, document)

documentField :: Key -> Value -> Maybe Value
documentField key (Object fields) = KM.lookup key fields
documentField _ _ = Nothing
