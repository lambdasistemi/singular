{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.InspectSpec
Description : A reader asks the packaged command for a key without a signer
License     : Apache-2.0

The provider supplies ledger observations, not reader conclusions. These are
command-boundary fixtures, not evidence of a connected ledger lifecycle.
-}
module Singular.CLI.InspectSpec (spec) where

import Cardano.Crypto.Hash (hashFromBytes)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.Tx.Out (datumTxOutL, mkBasicTxOut)
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    , MultiAsset (..)
    )
import Control.Monad (forM_)
import Control.Tracer (Tracer)
import Data.Aeson
    ( Value (..)
    , eitherDecodeStrict'
    , object
    , toJSON
    , (.=)
    )
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Char8 qualified as BC
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((&), (.~))
import PlutusCore.Data qualified as PLC
import Singular.CLI.Command (parseCommand)
import Singular.CLI.CommandRunSpec
    ( capabilities
    , captured
    , envOf
    , withRig
    )
import Singular.CLI.Root (runPackagedVia)
import Singular.CLI.Session (Env (..))
import Singular.CLI.Trace (Trace)
import Singular.Registry.Address (renderRegistryAddress)
import Singular.Registry.Application (neutralApplication)
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.ContractTable
    ( ApplicationIdentity (..)
    , applicationRows
    , loadContractTable
    )
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Evidence (Evidenced (..))
import Singular.Registry.LedgerProvider qualified as LP
import Singular.Registry.StubSession (stubSession)
import Singular.Registry.TrieState
    ( RegistryIdentity (..)
    , StatePolicyId (..)
    )
import Singular.Registry.TxBuilder.Internal (mkInlineDatum)
import Singular.State.Lineage (registryAsset)
import Singular.State.Preimage (activeTokenName, stateTokenName)
import System.Exit (ExitCode (..))
import Test.Hspec

spec :: Spec
spec = describe "inspect a registry key without a signer" $ do
    it
        "describes machine output, query work and exit statuses in the command's own help"
        $ withReader
        $ \_ provider _ _ -> do
            (code, out, _) <-
                captured
                    ( runPackagedVia
                        provider
                        neutralApplication
                        (pure Nothing)
                        ["registry", "inspect", "--help"]
                        []
                    )
            code `shouldBe` ExitSuccess
            BC.unpack out `shouldContain` "--json"
            BC.unpack out `shouldContain` "--query-work"
    it
        "runs the neutral reader and prints its active datum and published application as JSON"
        $ withReader
        $ \line provider identity seen -> do
            parseCommand (line <> ["--json"])
                `shouldSatisfy` either (const False) (const True)
            (code, out, _) <-
                captured
                    ( runPackagedVia
                        provider
                        neutralApplication
                        (pure Nothing)
                        (line <> ["--json"])
                        []
                    )
            code `shouldBe` ExitSuccess
            document <- either fail pure (eitherDecodeStrict' out)
            field "answer" document `shouldBe` Just (String "active")
            field "application" document `shouldBe` Just (toJSON identity)
            field "datum" document `shouldBe` Just (object ["int" .= (7 :: Int)])
            readIORef seen `shouldReturn` ["network", "asset"]
    it "prints a readable answer by default" $
        withReader $ \line provider _ _ -> do
            (code, out, _) <-
                captured
                    (runPackagedVia provider neutralApplication (pure Nothing) line [])
            code `shouldBe` ExitSuccess
            BC.unpack out `shouldContain` "active"
            BC.unpack out `shouldContain` "Application policy:"
            BC.unpack out `shouldContain` "Datum:"
            (eitherDecodeStrict' out :: Either String Value)
                `shouldSatisfy` either (const True) (const False)
    it
        "reports per-read work and totals from multiple provider trace pages, excluding other sessions"
        $ withReader
        $ \line provider _ _ -> do
            (code, out, _) <-
                captured
                    ( runPackagedVia
                        provider
                        neutralApplication
                        (pure Nothing)
                        (line <> ["--json", "--query-work"])
                        []
                    )
            code `shouldBe` ExitSuccess
            document <- either fail pure (eitherDecodeStrict' out)
            field "queryWork" document
                `shouldBe` Just
                    ( object
                        [ "reads" .= object ["network" .= work 1 1 13, "asset" .= work 2 3 29]
                        , "total" .= work 3 4 42
                        ]
                    )
    it
        "returns an unavailable answer rather than a parse refusal when a provider read fails"
        $ withReader
        $ \line provider _ _ -> do
            let failed tracer =
                    (provider tracer)
                        { envReads = \_ _ -> ioError (userError "provider disconnected")
                        }
            (code, out, _) <-
                captured
                    ( runPackagedVia
                        failed
                        neutralApplication
                        (pure Nothing)
                        (line <> ["--json"])
                        []
                    )
            code `shouldBe` ExitFailure 1
            document <- either fail pure (eitherDecodeStrict' out)
            field "answer" document `shouldBe` Just (String "unavailable")
            field "reason" document
                `shouldSatisfy` maybe
                    False
                    (\v -> "provider disconnected" `T.isInfixOf` T.pack (show v))
    forM_ ["--wallet-skey", "--vault", "--wallet-address"] $ \flag ->
        it ("refuses the signer setting " <> flag <> " before reading it") $
            withReader $ \line _ _ _ ->
                parseCommand (line <> [flag, "unread-file"])
                    `shouldSatisfy` either (const True) (const False)
  where
    field key (Object o) = KM.lookup key o
    field _ _ = Nothing
    work calls rows bytes =
        object
            [ "calls" .= (calls :: Int)
            , "rows" .= (rows :: Int)
            , "bytes" .= (bytes :: Int)
            ]

withReader
    :: ( [String]
         -> (Tracer IO Trace -> Env)
         -> ApplicationIdentity
         -> IORef [Text]
         -> IO a
       )
    -> IO a
withReader use = withRig $ \rig -> do
    table <- loadContractTable >>= either (fail . T.unpack) pure
    identity <- case applicationRows table of
        one : _ -> pure one
        [] -> fail "packaged release table has no application"
    reference <-
        either fail pure (parseOutRef (T.replicate 64 "a" <> "#0"))
    let registry =
            RegistryIdentity
                (StatePolicyId (appliedStatePolicy identity))
                (stateTokenName reference)
    asset <-
        maybe
            (fail "registry asset is malformed")
            pure
            (registryAsset registry)
    script <-
        maybe
            (fail "application script is malformed")
            pure
            (hashFromBytes (applicationScript identity))
    address <-
        maybe
            (fail "registry address cannot be rendered")
            pure
            (renderRegistryAddress 42 asset)
    seen <- newIORef []
    let note label action = modifyIORef' seen (<> [label]) >> action
        (policy, _) = asset
        active = activeTokenName registry "my-key"
        holding =
            mkBasicTxOut
                (Addr Testnet (ScriptHashObj (ScriptHash script)) StakeRefNull)
                ( MaryValue
                    (Coin 5000000)
                    (MultiAsset (Map.singleton policy (Map.singleton active 1)))
                )
                & datumTxOutL .~ mkInlineDatum (PLC.I 7)
        session =
            stubSession
                { LP.servedNetwork =
                    note "network" (pure (Right (Evidenced (LP.Network 42) Nothing)))
                , LP.outputs = \query -> note "asset" $ case query of
                    LP.HoldingAsset asked
                        | asked == (policy, active) ->
                            pure (Right (Evidenced [(reference, holding)] Nothing))
                    _ -> fail "inspect made an unexpected output query"
                }
        provider _ =
            (envOf rig)
                { envReads = \_ k ->
                    k
                        ( (capabilities rig)
                            { capReads =
                                ( LP.Network 42
                                , LP.LedgerProvider
                                    { LP.acquire = \_ action -> Right <$> action session
                                    , LP.submitTx = \_ _ -> fail "inspect submitted a transaction"
                                    }
                                )
                            , capTrace =
                                pure
                                    [ exchange "raw-builder-fixture" "network" 1 1 13
                                    , exchange "raw-builder-fixture" "asset" 1 1 11
                                    , exchange "raw-builder-fixture" "asset" 1 2 18
                                    , exchange "another-session" "asset" 99 99 99
                                    ]
                            }
                        )
                }
        line =
            [ "registry"
            , "inspect"
            , "--registry"
            , T.unpack address
            , "--koios-url"
            , "http://fixture.invalid"
            , "--key"
            , "my-key"
            ]
    use line provider identity seen
  where
    exchange session call calls rows bytes =
        object
            [ "kind" .= ("raw-exchange" :: Text)
            , "session" .= (session :: Text)
            , "call" .= (call :: Text)
            , "work"
                .= object
                    [ "calls" .= (calls :: Int)
                    , "rows" .= (rows :: Int)
                    , "bytes" .= (bytes :: Int)
                    ]
            ]
