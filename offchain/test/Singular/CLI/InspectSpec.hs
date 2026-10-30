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
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Version (versionBranch)
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
import Singular.CLI.Version (releaseTag)
import Singular.Registry.Address (renderRegistryAddress)
import Singular.Registry.Application (neutralApplication)
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.ContractTable
    ( ApplicationIdentity (..)
    , ContractTable
    , Contracts (..)
    , Installed (..)
    , Serving (..)
    , applicationRows
    , contractsOf
    , loadContractTable
    , releaseUrl
    , servingLines
    , servingOf
    , tableRows
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

import Paths_singular_registry (version)

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
                        { envReaderReads = \_ _ -> ioError (userError "provider disconnected")
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
    it "knows the release it belongs to as the package's own tag" $
        releaseTag
            `shouldBe` ( "v"
                            <> T.intercalate
                                "."
                                (map (T.pack . show) (take 3 (versionBranch version)))
                       )
    it
        "names the release that serves a registry of an earlier contract, without reading the chain"
        $ withTable
        $ \table -> do
            let earlier = [(hash, tags) | (hash, tags) <- tableRows table, not (null tags)]
            length earlier `shouldSatisfy` (> 1)
            forM_ earlier $ \(hash, tags) -> do
                let said = servingLines (ServedByEarlier (NE.fromList tags))
                (code, out, asked) <- inspectPolicy True hash
                code `shouldBe` ExitFailure 2
                asked `shouldBe` ["network"]
                document <- either fail pure (eitherDecodeStrict' out)
                field "answer" document `shouldBe` Just (String "refused")
                field "refusal" document
                    `shouldBe` Just (String "unknown-state-policy")
                field "guidance" document `shouldBe` Just (toJSON said)
                (_, printed, _) <- inspectPolicy False hash
                forM_ said $ \line' ->
                    BC.unpack printed `shouldContain` T.unpack line'
                servingOf table (Installed releaseTag []) hash
                    `shouldBe` ServedByEarlier (NE.fromList tags)
                said `shouldSatisfy` any (T.isInfixOf (releaseUrl (last tags)))
    it
        "says no release is known, and names none, for contracts no row holds"
        $ withTable
        $ \table -> do
            let unknown =
                    [ hash
                    | byte <- [0 .. 255]
                    , let hash = BS.replicate 28 byte
                    , contractsOf table hash == NoKnownRelease
                    ]
            unknown `shouldSatisfy` (not . null)
            forM_ (take 3 unknown) $ \hash -> do
                (code, out, asked) <- inspectPolicy True hash
                code `shouldBe` ExitFailure 2
                asked `shouldBe` ["network"]
                document <- either fail pure (eitherDecodeStrict' out)
                field "refusal" document
                    `shouldBe` Just (String "unknown-state-policy")
                field "guidance" document
                    `shouldBe` Just (toJSON (servingLines UnknownContract))
                BC.unpack out `shouldNotContain` "releases/tag"
    it "adds no guidance for a registry the installed release serves" $
        withReader $ \line provider _ _ -> do
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
            field "guidance" document `shouldBe` Nothing
  where
    field key (Object o) = KM.lookup key o
    field _ _ = Nothing
    work calls rows bytes =
        object
            [ "calls" .= (calls :: Int)
            , "rows" .= (rows :: Int)
            , "bytes" .= (bytes :: Int)
            ]

withTable :: (ContractTable -> IO a) -> IO a
withTable use = loadContractTable >>= either (fail . T.unpack) use

{- | Inspect a registry of this state policy over a provider that serves only
its network: the reader refuses before it reads any output. The names of the
provider's reads are returned beside the output.
-}
inspectPolicy
    :: Bool -> BS.ByteString -> IO (ExitCode, BS.ByteString, [Text])
inspectPolicy json policy = withRig $ \rig -> do
    reference <-
        either fail pure (parseOutRef (T.replicate 64 "a" <> "#0"))
    let registry =
            RegistryIdentity
                (StatePolicyId policy)
                (stateTokenName reference)
    asset <-
        maybe
            (fail "registry asset is malformed")
            pure
            (registryAsset registry)
    address <-
        maybe
            (fail "registry address cannot be rendered")
            pure
            (renderRegistryAddress 42 asset)
    seen <- newIORef []
    let note label action = modifyIORef' seen (<> [label]) >> action
        session =
            stubSession
                { LP.servedNetwork =
                    note "network" (pure (Right (Evidenced (LP.Network 42) Nothing)))
                , LP.outputs = \_ -> note "outputs" (fail "inspect asked for outputs")
                }
        provider _ =
            (envOf rig)
                { envReads = \_ _ -> fail "inspect opened builder startup"
                , envReaderReads = \_ k ->
                    k
                        ( (capabilities rig)
                            { capReads =
                                ( LP.Network 42
                                , LP.LedgerProvider
                                    { LP.acquire = \_ action -> Right <$> action session
                                    , LP.submitTx = \_ _ -> fail "inspect submitted a transaction"
                                    }
                                )
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
                <> ["--json" | json]
    (code, out, _) <-
        captured
            (runPackagedVia provider neutralApplication (pure Nothing) line [])
    asked <- readIORef seen
    pure (code, out, asked)

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
                & datumTxOutL
                    .~ mkInlineDatum (PLC.I 7)
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
                { envReads = \_ _ -> fail "inspect opened builder startup"
                , envReaderReads = \_ k ->
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
