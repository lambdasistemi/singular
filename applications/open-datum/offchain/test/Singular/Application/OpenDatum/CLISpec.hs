{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.OpenDatum.CLISpec
Description : Command parsing before file, node or key access
License     : Apache-2.0

The command parser reads explicit arguments and settings. Library seed,
journal and recovery checks live in "Singular.Application.OpenDatum.LibraryStateSpec".
-}
module Singular.Application.OpenDatum.CLISpec (spec) where

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.BaseTypes (Network (Mainnet, Testnet))
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Keys (coerceKeyRole)
import Cardano.Ledger.Mary.Value (PolicyID (PolicyID))
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson (Value (String))
import Data.ByteString qualified as BS (pack, replicate)
import Data.ByteString.Base16 qualified as B16 (encode)
import Data.ByteString.Char8 qualified as BC (pack)
import Data.ByteString.Short qualified as SBS (fromShort)
import Data.Either (fromLeft, isRight)
import Data.List (findIndex, isInfixOf, isPrefixOf, tails)
import Data.Text qualified as T (Text, pack, unpack)
import Data.Text.Encoding qualified as TE (decodeUtf8)
import Singular.Application.OpenDatum.Build
    ( DepositRefusal (..)
    , minimumDeposit
    )
import Singular.Application.OpenDatum.Command
    ( CLIError
        ( BadValue
        , DepositRefused
        , MissingFlag
        , PreviewTakesNoKey
        , RemovedSetting
        , SigningKeyNotAccepted
        , UnknownCommand
        , UnsafeSettings
        , UnsupportedFlag
        )
    , CreateArgs
        ( CreateArgs
        , createBlueprint
        , createMode
        , createPreview
        , createProcessTime
        , createReceipt
        , createRetractTime
        , createSaveStateTokenTo
        , createSeed
        , createStateDir
        )
    , EntryArgs
        ( EntryArgs
        , entryAccess
        , entryBlueprint
        , entryDeposit
        , entryDocument
        , entryFold
        , entryFund
        , entryKey
        , entryMaxOutlay
        , entryMode
        , entryPayloadSchema
        , entryReceipt
        , entryStateDir
        )
    , EntryMode (Preview, Submit)
    , FoldArgs
        ( FoldArgs
        , foldAccess
        , foldBlueprint
        , foldFund
        , foldMaxOutlay
        , foldReceipt
        , foldRequest
        , foldStateDir
        , foldWrite
        )
    , InspectArgs (inspectKey, inspectOutputsAt, inspectProvider)
    , Key (Key)
    , OpenDatumCommand
        ( OpenCreate
        , OpenFold
        , OpenHelp
        , OpenInsert
        , OpenInspect
        , OpenTerminate
        , OpenUpdate
        )
    , ProviderSettings
        ( ProviderSettings
        , providerTimeDirectory
        , providerTokenFile
        )
    , RegistryAccess (..)
    , Signer (SignerExternal, SignerKeyFile, SignerVault)
    , WriteSettings
        ( WriteSettings
        , writeConfirmTimeout
        , writeProvider
        , writeSigner
        )
    , keyFlags
    , maxKeyBytes
    , openDatumHelp
    , openDatumUsage
    , parseOpenDatumCommand
    , parseOpenDatumCommandWithEnvironment
    , renderCLIError
    )
import Singular.Application.OpenDatum.StateTokenFixture (token)
import Singular.Application.OpenDatum.Value (Mode (..))
import Singular.CLI.Registry (keyFields, parseEnterpriseAddress)
import Singular.Registry.Deployment (parseOutRef, renderOutRef)
import Singular.Registry.Ledger (AssetName (AssetName))
import Singular.Registry.PlainJson (PayloadSchema (..))
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , scriptHashBytes
    )
import Singular.Registry.Wallet (bech32Address)
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldNotBe
    , shouldNotSatisfy
    , shouldSatisfy
    )

spec :: Spec
spec = describe "singular registry commands" $ do
    commandLine
    payloadSchemaRows
    externalSignerRows
    vaultSignerRows

-- ---------------------------------------------------------
-- The command line
-- ---------------------------------------------------------

provider :: [String]
provider =
    [ "--koios-url"
    , "http://127.0.0.1:8080/api/v1"
    , "--network-magic"
    , "42"
    ]

wallet :: [String]
wallet = ["--wallet-skey", "/keys/payment.skey"]

-- | The actor directory, the release and the registry's state token.
reg :: [String]
reg = createReg <> ["--state-token", T.unpack tokenSpelling]

-- | A create names no state token: it makes one.
createReg :: [String]
createReg = ["--state-dir", "/srv/reg", "--blueprint", "/srv/plutus.json"]

-- | The state token as a person copies it from the registry's page.
tokenSpelling :: T.Text
tokenSpelling =
    let (PolicyID policy, AssetName name) = token
    in  hexText (scriptHashBytes policy)
            <> "."
            <> hexText (SBS.fromShort name)
  where
    hexText = TE.decodeUtf8 . B16.encode

-- | What a command parsed with @reg@ acts on.
access :: RegistryAccess
access = RegistryAccess{accessToken = token}

commandLine :: Spec
commandLine = describe "the command line" $ do
    it "answers help at the top and under the program name" $
        forM_ [["--help"], ["open-datum", "--help"], []] $ \args ->
            case parseOpenDatumCommand args of
                Right (OpenHelp page) ->
                    page `shouldSatisfy` isInfixOf "Usage: open-datum"
                other -> expectationFailure ("not help: " <> show other)
    it "names the six commands and only them in its openDatumUsage" $ do
        forM5
            [ "create"
            , "insert"
            , "update"
            , "terminate"
            , "fold"
            , "inspect"
            ]
            $ \c ->
                openDatumUsage `shouldSatisfy` isInfixOf ("open-datum " <> c)
        openDatumUsage `shouldNotSatisfy` isInfixOf "registry delete"
    it "refuses a command it does not support" $
        parseOpenDatumCommand ["open-datum", "delete"]
            `shouldSatisfy` isLeftWith isUnknown
    it "reads a create with its seed, wallet and provider" $
        parseOpenDatumCommand
            ( ["open-datum", "create", "--seed", seedText]
                <> createReg
                <> provider
                <> wallet
            )
            `shouldBe` Right
                ( OpenCreate
                    Open
                    CreateArgs
                        { createStateDir = Just "/srv/reg"
                        , createBlueprint = "/srv/plutus.json"
                        , createMode = Submit writeSettings
                        , createSeed = Just seedText
                        , createPreview = False
                        , createReceipt = Nothing
                        , createSaveStateTokenTo = Nothing
                        , createProcessTime = 600_000
                        , createRetractTime = 300_000
                        }
                )
    describe "registry creation windows" $ do
        it "accepts positive integer windows in milliseconds" $
            forM_ [("1", "1"), ("120000", "30000"), ("600000", "300000")] $
                \(processing, retracting) ->
                    parseOpenDatumCommand
                        ( ["open-datum", "create", "--seed", seedText]
                            <> ["--process-time", processing, "--retract-time", retracting]
                            <> createReg
                            <> provider
                            <> wallet
                        )
                        `shouldSatisfy` either (const False) (const True)
        it "retains both chosen values and defaults only the omitted window" $ do
            let windows extra =
                    fmap
                        ( \case
                            OpenCreate _ a -> Just (createProcessTime a, createRetractTime a)
                            _ -> Nothing
                        )
                        ( parseOpenDatumCommand
                            ( ["open-datum", "create", "--seed", seedText]
                                <> createReg
                                <> provider
                                <> wallet
                                <> extra
                            )
                        )
            windows [] `shouldBe` Right (Just (600_000, 300_000))
            windows ["--process-time", "120000", "--retract-time", "30000"]
                `shouldBe` Right (Just (120_000, 30_000))
            windows ["--process-time=1"] `shouldBe` Right (Just (1, 300_000))
            windows ["--retract-time=1"] `shouldBe` Right (Just (600_000, 1))
            windows ["--process-time=999999999999999999999999999999"]
                `shouldBe` Right (Just (999_999_999_999_999_999_999_999_999_999, 300_000))
        it
            "refuses creation windows on later commands instead of ignoring them"
            $ forM_
                [ "insert"
                , "update"
                , "terminate"
                , "fold"
                , "inspect"
                ]
            $ \command ->
                forM_ ["--process-time", "--retract-time"] $ \flag ->
                    parseOpenDatumCommand
                        (["open-datum", command, flag, "1"] <> reg <> provider <> wallet)
                        `shouldBe` Left
                            ( BadValue
                                flag
                                "is an open-datum create flag: windows are fixed for the life of a registry"
                            )
        forM_ ["--process-time", "--retract-time"] $ \flag -> do
            it
                ("refuses non-positive and non-integer " <> flag <> " before effects")
                $ forM_ ["0", "-1", "1.5", "lots", "", "1e3"]
                $ \argument ->
                    parseOpenDatumCommand
                        ( ["open-datum", "create", "--seed", seedText, flag, argument]
                            <> createReg
                            <> provider
                            <> wallet
                        )
                        `shouldBe` Left
                            (BadValue flag "needs a positive integer number of milliseconds")
            it ("refuses a missing " <> flag <> " value") $
                parseOpenDatumCommand
                    ( ["open-datum", "create", "--seed", seedText]
                        <> createReg
                        <> provider
                        <> wallet
                        <> [flag]
                    )
                    `shouldBe` Left (BadValue flag "needs a value")
    it "reads an insert with its payload and the default deposit" $
        parseOpenDatumCommand
            ( ["open-datum", "insert", "--key", "key", "--payload", "/p.json"]
                <> reg
                <> provider
                <> wallet
            )
            `shouldBe` Right
                ( OpenInsert
                    EntryArgs
                        { entryStateDir = Just "/srv/reg"
                        , entryAccess = access
                        , entryBlueprint = "/srv/plutus.json"
                        , entryMode = Submit writeSettings
                        , entryKey = Key "key"
                        , entryDocument = Just "/p.json"
                        , entryPayloadSchema = PlainSchema
                        , entryDeposit = Just minimumDeposit
                        , entryFund = Nothing
                        , entryMaxOutlay = Nothing
                        , entryReceipt = Nothing
                        , entryFold = False
                        }
                )
    it "reads --deposit on an insert, at the minimum and above it"
        $ forM_
            [ ("2000000", 2_000_000)
            , ("2000001", 2_000_001)
            , ("35000000", 35_000_000)
            ]
        $ \(argument, lovelace) ->
            fmap
                ( \case
                    OpenInsert e -> entryDeposit e
                    _ -> Nothing
                )
                ( parseOpenDatumCommand
                    ( ["open-datum", "insert", "--key", "key", "--payload", "/p.json"]
                        <> ["--deposit", argument]
                        <> reg
                        <> provider
                        <> wallet
                    )
                )
                `shouldBe` Right (Just lovelace)
    it "refuses a deposit that is not an integer, or is below the minimum" $ do
        let insertWith argument =
                parseOpenDatumCommand
                    ( ["open-datum", "insert", "--key", "key", "--payload", "/p.json"]
                        <> ["--deposit", argument]
                        <> reg
                        <> provider
                        <> wallet
                    )
        forM_ ["two", "2e6", "2.5", "", "0x10", "+2000000"] $ \argument ->
            insertWith argument `shouldBe` Left (DepositRefused DepositNotInteger)
        insertWith "1999999"
            `shouldBe` Left (DepositRefused (DepositBelowMinimum 1_999_999))
        insertWith "-5"
            `shouldBe` Left (DepositRefused (DepositBelowMinimum (-5)))
        insertWith "0"
            `shouldBe` Left (DepositRefused (DepositBelowMinimum 0))
        renderCLIError (DepositRefused (DepositBelowMinimum 1_999_999))
            `shouldSatisfy` isInfixOf "below the minimum of 2000000 lovelace"
    it "takes --deposit from an insert only"
        $ forM_
            [ ["open-datum", "update", "--payload", "/p.json"]
            , ["open-datum", "terminate"]
            ]
        $ \command ->
            parseOpenDatumCommand
                ( command
                    <> ["--key", "key", "--deposit", "2000000"]
                    <> reg
                    <> provider
                    <> wallet
                )
                `shouldBe` Left
                    ( BadValue
                        "--deposit"
                        "is an open-datum insert flag: only insert sets a deposit"
                    )
    it
        "no longer reads the flag that carried a hand-built envelope, on any command"
        $ forM_ commands
        $ \line ->
            parseOpenDatumCommand (line <> [removedFlag, "/e.json"])
                `shouldBe` Left (BadValue removedFlag "is not a flag singular reads")
    it "refuses an insert without its payload" $
        parseOpenDatumCommand
            (["open-datum", "insert", "--key", "key"] <> reg <> provider <> wallet)
            `shouldBe` Left (MissingFlag "--payload")
    it "reads an update with its payload, and refuses one without" $ do
        parseOpenDatumCommand
            ( ["open-datum", "update", "--key", "key", "--payload", "/p.json"]
                <> reg
                <> provider
                <> wallet
            )
            `shouldSatisfy` \case
                Right (OpenUpdate e) -> entryDocument e == Just "/p.json"
                _ -> False
        parseOpenDatumCommand
            (["open-datum", "update", "--key", "key"] <> reg <> provider <> wallet)
            `shouldSatisfy` isLeftWith isMissing
    it "reads --key as text and --key-hex as base16, to the same key" $
        forM_ keyCommands $ \command -> do
            let keyOf extra = fmap commandKey (parseOpenDatumCommand (command <> extra))
            keyOf ["--key", "alice"] `shouldBe` Right (Key "alice")
            keyOf ["--key-hex", "616c696365"] `shouldBe` Right (Key "alice")
            keyOf ["--key-hex", "616c696365"] `shouldBe` keyOf ["--key", "alice"]
            keyOf ["--key-hex=616c696365"] `shouldBe` Right (Key "alice")
    it "takes a hex-looking --key as the text it spells" $
        forM_ keyCommands $ \command ->
            fmap commandKey (parseOpenDatumCommand (command <> ["--key", "6b65"]))
                `shouldBe` Right (Key "6b65")
    it "reads --key text as its UTF-8 bytes" $
        fmap
            commandKey
            (parseOpenDatumCommand (insertCommand <> ["--key", "caf\233"]))
            `shouldBe` Right (Key (BS.pack [0x63, 0x61, 0x66, 0xc3, 0xa9]))
    it "refuses --key-hex that is not base16, naming it" $
        forM_ keyCommands $ \command -> do
            parseOpenDatumCommand (command <> ["--key-hex", "zz"])
                `shouldSatisfy` refusedWith "--key-hex is not base16"
            parseOpenDatumCommand (command <> ["--key-hex", "abc"])
                `shouldSatisfy` refusedWith "--key-hex is not base16"
    it "refuses an empty key, as text and as hex, naming it" $
        forM_ keyCommands $ \command -> do
            parseOpenDatumCommand (command <> ["--key", ""])
                `shouldSatisfy` refusedWith "--key is empty"
            parseOpenDatumCommand (command <> ["--key-hex", ""])
                `shouldSatisfy` refusedWith "--key is empty"
    it
        "accepts a key of exactly 32 bytes and refuses 33, in either spelling"
        $ forM_ keyCommands
        $ \command -> do
            let at n = replicate n 'a'
                hexAt n = replicate (2 * n) 'a'
            fmap
                commandKey
                (parseOpenDatumCommand (command <> ["--key", at maxKeyBytes]))
                `shouldBe` Right (Key (BC.pack (at maxKeyBytes)))
            fmap
                commandKey
                (parseOpenDatumCommand (command <> ["--key-hex", hexAt maxKeyBytes]))
                `shouldSatisfy` either (const False) (const True)
            parseOpenDatumCommand (command <> ["--key", at (maxKeyBytes + 1)])
                `shouldSatisfy` refusedWith "at most 32 bytes"
            parseOpenDatumCommand
                (command <> ["--key-hex", hexAt (maxKeyBytes + 1)])
                `shouldSatisfy` refusedWith "at most 32 bytes"
    it "counts the bytes of a text key, not its characters" $
        -- 17 two-byte characters are 34 bytes
        parseOpenDatumCommand
            (insertCommand <> ["--key", concat (replicate 17 "\233")])
            `shouldSatisfy` refusedWith "at most 32 bytes"
    it
        "refuses a --key the terminal's encoding could not decode, never reading it as text"
        $
        -- the runtime hands undecodable argument bytes over as lone surrogates
        parseOpenDatumCommand (insertCommand <> ["--key", "caf\xDCC3\xDCA9"])
            `shouldSatisfy` refusedWith "run under a UTF-8 locale"
    it "takes the key once, by --key or by --key-hex" $
        forM_ keyCommands $ \command -> do
            parseOpenDatumCommand
                (command <> ["--key", "alice", "--key-hex", "616c696365"])
                `shouldSatisfy` refusedWith "--key-hex excludes --key"
            parseOpenDatumCommand command `shouldBe` Left (MissingFlag "--key")
    it "refuses a bad key before it asks for a provider or a wallet" $
        parseOpenDatumCommand
            (["open-datum", "insert", "--key-hex", "zz"] <> reg)
            `shouldSatisfy` refusedWith "--key-hex is not base16"
    it "shows a receipt's key as hex and, when it is UTF-8, as text" $ do
        keyFields "alice"
            `shouldBe` [ ("key", Aeson.String "616c696365")
                       , ("keyText", Aeson.String "alice")
                       ]
        keyFields (BS.pack [0xff, 0x00])
            `shouldBe` [("key", Aeson.String "ff00")]
    it "refuses a signing key on inspect" $
        parseOpenDatumCommand
            (["open-datum", "inspect", "--key", "key"] <> reg <> provider <> wallet)
            `shouldBe` Left SigningKeyNotAccepted
    it "refuses a write with a partial provider and wallet setting" $
        parseOpenDatumCommand
            ( ["open-datum", "insert", "--key", "key"]
                <> reg
                <> ["--koios-url", "http://127.0.0.1:8080/api/v1"]
            )
            `shouldSatisfy` isLeftWith (unsafeMentions "partially configured")
    it
        "reads a confirmation timeout on a write and refuses one that is not seconds"
        $ do
            let insert extra =
                    parseOpenDatumCommand
                        ( ["open-datum", "insert", "--key", "key", "--payload", "/p.json"]
                            <> reg
                            <> provider
                            <> wallet
                            <> extra
                        )
            fmap
                ( \case
                    OpenInsert EntryArgs{entryMode = Submit w} -> writeConfirmTimeout w
                    _ -> Nothing
                )
                (insert ["--confirm-timeout", "0"])
                `shouldBe` Right (Just 0)
            insert ["--confirm-timeout", "soon"]
                `shouldBe` Left (BadValue "--confirm-timeout" "is not a whole number of seconds")
    foldRows
    removedVerbsRows
    outputsAtRows
    preview
    it "refuses a write against mainnet" $
        parseOpenDatumCommand
            ( ["open-datum", "insert", "--key", "key"]
                <> reg
                <> ["--koios-url", "/s", "--network-magic", "764_824_073"]
                <> wallet
            )
            `shouldSatisfy` isLeftWith (unsafeMentions "764_824_073")
    it "refuses a write with no provider configuration" $
        parseOpenDatumCommand
            (["open-datum", "insert", "--key", "key"] <> reg)
            `shouldSatisfy` isLeftWith isUnsafe
    it "names a missing state token when no directory is given" $
        parseOpenDatumCommand
            ( ["open-datum", "inspect", "--key", "key", "--blueprint", "b"]
                <> provider
            )
            `shouldBe` Left (MissingFlag "--state-token")
    it
        "reads --registry as an address, and says of a path that --registry once named --state-dir"
        $ do
            forM5 [["--registry", "/srv/reg"], ["--registry=/srv/reg"]] $ \extra ->
                case parseOpenDatumCommand
                    ( ["open-datum", "inspect", "--key", "key", "--blueprint", "b"]
                        <> extra
                        <> provider
                    ) of
                    Left (BadValue "--registry" why) -> do
                        why `shouldSatisfy` isInfixOf "not an address"
                        why `shouldSatisfy` isInfixOf "--state-dir"
                    other ->
                        expectationFailure
                            ("not refused as a word that is not an address: " <> show other)
            parseOpenDatumCommand
                ( [ "open-datum"
                  , "inspect"
                  , "--key"
                  , "key"
                  , "--blueprint"
                  , "b"
                  , "--state-dir"
                  , "/srv/reg"
                  ]
                    <> provider
                    <> ["--state-token", T.unpack tokenSpelling]
                )
                `shouldSatisfy` either (const False) (const True)
    it
        "reads sole-provider settings over the full nonempty command extent"
        $ do
            length commands `shouldBe` 6
            forM5 commands $ \line ->
                parseOpenDatumCommand line
                    `shouldSatisfy` either (const False) (const True)
    it "refuses every obsolete backend selector before command effects" $
        forM5 (commands <> [[], ["--help"]]) $ \line -> do
            forM5 ["koios", "node", "indexer", "nodes", ""] $ \value -> do
                parseOpenDatumCommand (line <> ["--backend", value])
                    `shouldBe` Left (RemovedSetting "--backend")
                parseOpenDatumCommand (line <> ["--backend=" <> value])
                    `shouldBe` Left (RemovedSetting "--backend")
            parseOpenDatumCommand (line <> ["--backend"])
                `shouldBe` Left (RemovedSetting "--backend")
    it
        "refuses obsolete socket flags and environment settings before command effects"
        $ forM5 (commands <> [[], ["--help"]])
        $ \line -> do
            parseOpenDatumCommand
                (line <> ["--node-socket", "/obsolete/node.socket"])
                `shouldBe` Left (RemovedSetting "--node-socket")
            parseOpenDatumCommand
                (line <> ["--node-socket=/obsolete/node.socket"])
                `shouldBe` Left (RemovedSetting "--node-socket")
            parseOpenDatumCommand (line <> ["--node-socket"])
                `shouldBe` Left (RemovedSetting "--node-socket")
            parseOpenDatumCommandWithEnvironment
                [("SINGULAR_NODE_SOCKET", "/obsolete/node.socket")]
                line
                `shouldBe` Left (RemovedSetting "SINGULAR_NODE_SOCKET")
            parseOpenDatumCommandWithEnvironment
                [("SINGULAR_NODE_SOCKET", "")]
                line
                `shouldBe` Left (RemovedSetting "SINGULAR_NODE_SOCKET")
    it
        "carries a token-file path and pinned-time directory without reading either"
        $ do
            let extra =
                    [ "--koios-token-file"
                    , "/not-read/token"
                    , "--network-time"
                    , "/not-read/time"
                    ]
            forM5 commands $ \line -> case parseOpenDatumCommand (line <> extra) of
                Right command -> do
                    let settings = settingsOf command
                    providerTokenFile settings `shouldBe` Just "/not-read/token"
                    providerTimeDirectory settings `shouldBe` Just "/not-read/time"
                Left failure -> expectationFailure (show failure)
    it "refuses the numeric mainnet magic before reading a signing key" $
        parseOpenDatumCommand
            ( ["open-datum", "insert", "--key", "key"]
                <> reg
                <> ["--koios-url", "https://unused", "--network-magic", "764824073"]
                <> wallet
            )
            `shouldSatisfy` isLeftWith (unsafeMentions "mainnet")
  where
    -- Spelled apart: no line of the tree names the removed flag.
    removedFlag = "--" <> "envelope"
    commands =
        [ ["open-datum", "create", "--seed", seedText]
            <> createReg
            <> provider
            <> wallet
        , ["open-datum", "insert", "--key", "key", "--payload", "/p.json"]
            <> reg
            <> provider
            <> wallet
        , ["open-datum", "update", "--key", "key", "--payload", "/p.json"]
            <> reg
            <> provider
            <> wallet
        , ["open-datum", "terminate", "--key", "key"]
            <> reg
            <> provider
            <> wallet
        , ["open-datum", "fold"] <> reg <> provider <> wallet
        , ["open-datum", "inspect", "--key", "key"] <> reg <> provider
        ]
    forM5 xs f = mapM_ f xs
    settingsOf = \case
        OpenCreate _ CreateArgs{createMode = Submit settings} -> writeProvider settings
        OpenInsert args -> entrySettings args
        OpenUpdate args -> entrySettings args
        OpenTerminate args -> entrySettings args
        OpenFold args -> writeProvider (foldWrite args)
        OpenInspect args -> inspectProvider args
        other -> error ("provider settings were not exercised: " <> show other)
    entrySettings args = case entryMode args of
        Submit settings -> writeProvider settings
        Preview settings _ -> settings
    preview = previewRows
    foldRows = foldCommandRows
    writeSettings =
        WriteSettings
            { writeProvider =
                ProviderSettings "http://127.0.0.1:8080/api/v1" 42 Nothing Nothing
            , writeSigner = SignerKeyFile "/keys/payment.skey"
            , writeConfirmTimeout = Nothing
            }
    isUnknown = \case UnknownCommand _ -> True; _ -> False
    refusedWith needle = \case
        Left e -> needle `isInfixOf` renderCLIError e
        Right _ -> False
    commandKey = \case
        OpenInsert e -> entryKey e
        OpenUpdate e -> entryKey e
        OpenTerminate e -> entryKey e
        OpenInspect i -> inspectKey i
        other -> error ("not a key command: " <> show other)
    insertCommand =
        ["open-datum", "insert", "--payload", "/p.json"]
            <> reg
            <> provider
            <> wallet
    keyCommands =
        [ insertCommand
        , ["open-datum", "update", "--payload", "/p.json"]
            <> reg
            <> provider
            <> wallet
        , ["open-datum", "terminate"] <> reg <> provider <> wallet
        , ["open-datum", "inspect"] <> reg <> provider
        ]
    isMissing = \case MissingFlag _ -> True; _ -> False
    isUnsafe = \case UnsafeSettings _ -> True; _ -> False
    unsafeMentions s = \case
        UnsafeSettings m -> s `isInfixOf` m
        _ -> False

isLeftWith :: (e -> Bool) -> Either e a -> Bool
isLeftWith p = either p (const False)

seedText :: String
seedText = replicate 64 'b' <> "#1"

{- | The external signer (#642 slice 1): an address with its bundle file
names the signer of each write, the shared reader refuses the mixtures,
previews and inspect refuse the bundle file, and create keeps the
registry's create behaviour. Every address here is produced from a key
hash, never typed.
-}
externalSignerRows :: Spec
externalSignerRows = describe "the external signer" $ do
    let payerHash = BS.replicate 28 0x5a
        addrOf = addrFromKeyHashBytes
        textOf net h = bech32Address (addrOf net h)
        address = textOf Testnet payerHash
        bundle = ["--bundle", "run.bundle"]
        named = ["--wallet-address", address]
        signerOf = \case
            OpenInsert EntryArgs{entryMode = Submit w} -> Just (writeSigner w)
            OpenUpdate EntryArgs{entryMode = Submit w} -> Just (writeSigner w)
            OpenTerminate EntryArgs{entryMode = Submit w} -> Just (writeSigner w)
            OpenFold FoldArgs{foldWrite = w} -> Just (writeSigner w)
            _ -> Nothing
        entryBase name extra =
            ["open-datum", name, "--key", "key"] <> extra <> reg <> provider
        writes =
            [ entryBase "insert" ["--payload", "/p.json"]
            , entryBase "update" ["--payload", "/p.json"]
            , entryBase "terminate" []
            , ["open-datum", "fold"] <> reg <> provider
            ]
        withArgs base extra = parseOpenDatumCommand (base <> extra)
    it "reads the address with the bundle file as each write's signer" $
        forM_ writes $ \base -> do
            let parsed = withArgs base (named <> bundle)
            parsed `shouldSatisfy` either (const False) (const True)
            fmap signerOf parsed
                `shouldBe` Right (Just (SignerExternal (T.pack address) "run.bundle"))
    it
        "reads the external signer on an insert or a terminate that also folds"
        $ do
            let insertBase = entryBase "insert" ["--payload", "/p.json"]
                terminateBase = entryBase "terminate" []
            fmap
                signerOf
                (parseOpenDatumCommand (insertBase <> named <> bundle <> ["--fold"]))
                `shouldBe` Right (Just (SignerExternal (T.pack address) "run.bundle"))
            fmap
                (\case OpenInsert e -> entryFold e; _ -> False)
                (parseOpenDatumCommand (insertBase <> named <> bundle <> ["--fold"]))
                `shouldBe` Right True
            fmap
                signerOf
                (parseOpenDatumCommand (terminateBase <> named <> bundle <> ["--fold"]))
                `shouldBe` Right (Just (SignerExternal (T.pack address) "run.bundle"))
            fmap
                (\case OpenTerminate e -> entryFold e; _ -> False)
                (parseOpenDatumCommand (terminateBase <> named <> bundle <> ["--fold"]))
                `shouldBe` Right True
    it
        "refuses an address without its bundle file, naming the bundle as required"
        $ forM_ writes
        $ \base ->
            withArgs base named
                `shouldBe` Left
                    ( BadValue
                        "--bundle"
                        ( "is required with --wallet-address: the run's transactions are "
                            <> "written to the bundle for signing elsewhere"
                        )
                    )
    it "refuses a bundle file without an address" $
        forM_ writes $
            \base ->
                withArgs base bundle
                    `shouldBe` Left
                        ( BadValue
                            "--bundle"
                            "is meaningless without --wallet-address: name the signer too"
                        )
    it "refuses the bundle file on every preview" $ do
        let previewNode =
                [ "--koios-url"
                , "http://127.0.0.1:8080/api/v1"
                , "--network-magic"
                , "1"
                ]
            refused =
                BadValue
                    "--bundle"
                    "cannot be used with --preview: a preview signs and writes nothing"
        parseOpenDatumCommand
            ( entryBase "insert" ["--payload", "/p.json", "--preview"]
                <> previewNode
                <> named
                <> bundle
            )
            `shouldBe` Left refused
        parseOpenDatumCommand
            ( entryBase "update" ["--payload", "/p.json", "--preview"]
                <> previewNode
                <> named
                <> bundle
            )
            `shouldBe` Left refused
        parseOpenDatumCommand
            (entryBase "terminate" ["--preview"] <> previewNode <> named <> bundle)
            `shouldBe` Left refused
        parseOpenDatumCommand
            ( [ "open-datum"
              , "create"
              , "--preview"
              , "--state-dir"
              , "/srv/reg"
              , "--blueprint"
              , "/srv/plutus.json"
              ]
                <> previewNode
                <> named
                <> bundle
            )
            `shouldBe` Left refused
    it "refuses the bundle file on inspect, by name" $
        parseOpenDatumCommand
            (["open-datum", "inspect", "--key", "key"] <> reg <> provider <> bundle)
            `shouldBe` Left
                ( BadValue
                    "--bundle"
                    ( "is not accepted by open-datum inspect: it reads, and takes the "
                        <> "address only to locate a journal"
                    )
                )
    it
        "reads the external signer on create as the registry's create does"
        $ do
            let create extra =
                    parseOpenDatumCommand
                        ( [ "open-datum"
                          , "create"
                          , "--state-dir"
                          , "/srv/reg"
                          , "--blueprint"
                          , "/srv/plutus.json"
                          ]
                            <> provider
                            <> extra
                        )
                signerOfCreate = \case
                    Right (OpenCreate _ CreateArgs{createMode = Submit w}) -> Just (writeSigner w)
                    _ -> Nothing
            signerOfCreate (create (named <> bundle))
                `shouldBe` Just (SignerExternal (T.pack address) "run.bundle")
            create named
                `shouldBe` Left
                    ( BadValue
                        "--bundle"
                        ( "is required with --wallet-address: the run's transactions are "
                            <> "written to the bundle for signing elsewhere"
                        )
                    )
    it
        "groups the vault, the external signer and the key file, in that order, on each write's usage"
        $ forM_ ["create", "insert", "update", "terminate", "fold"]
        $ \verb ->
            usageOf verb
                `shouldSatisfy` isInfixOf
                    "--vault FILE [--passphrase-fd N] | --wallet-address ADDR --bundle FILE | --wallet-skey FILE"

{- | The vault signer (#642 slice 3): the vault file, with the descriptor its
passphrase is read from, names the signer of each of the five writes, read
by the shared reader the registry's parser reads; the mixtures are its to
refuse; every preview and inspect refuse both flags by name; each write's
usage prints its vault line beside its key-file and external lines.
-}
vaultSignerRows :: Spec
vaultSignerRows = describe "the vault signer" $ do
    let payerHash = BS.replicate 28 0x5a
        address = bech32Address (addrFromKeyHashBytes Testnet payerHash)
        vault = ["--vault", "alice.vault"]
        withFd = vault <> ["--passphrase-fd", "3"]
        signerOf = \case
            OpenInsert EntryArgs{entryMode = Submit w} -> Just (writeSigner w)
            OpenUpdate EntryArgs{entryMode = Submit w} -> Just (writeSigner w)
            OpenTerminate EntryArgs{entryMode = Submit w} -> Just (writeSigner w)
            OpenFold FoldArgs{foldWrite = w} -> Just (writeSigner w)
            OpenCreate _ CreateArgs{createMode = Submit w} -> Just (writeSigner w)
            _ -> Nothing
        entryBase name extra =
            ["open-datum", name, "--key", "key"] <> extra <> reg <> provider
        createBase =
            [ "open-datum"
            , "create"
            , "--state-dir"
            , "/srv/reg"
            , "--blueprint"
            , "/srv/plutus.json"
            ]
                <> provider
        writes =
            [ entryBase "insert" ["--payload", "/p.json"]
            , entryBase "update" ["--payload", "/p.json"]
            , entryBase "terminate" []
            , ["open-datum", "fold"] <> reg <> provider
            , createBase
            ]
        previewNode =
            [ "--koios-url"
            , "http://127.0.0.1:8080/api/v1"
            , "--network-magic"
            , "1"
            ]
        previews =
            [ entryBase "insert" ["--payload", "/p.json", "--preview"]
                <> previewNode
            , entryBase "update" ["--payload", "/p.json", "--preview"]
                <> previewNode
            , entryBase "terminate" ["--preview"] <> previewNode
            , [ "open-datum"
              , "create"
              , "--preview"
              , "--state-dir"
              , "/srv/reg"
              , "--blueprint"
              , "/srv/plutus.json"
              ]
                <> previewNode
            ]
        withArgs base extra = parseOpenDatumCommand (base <> extra)
        refusedBy flag = \case
            Left (BadValue f _) -> f == flag
            _ -> False
    it
        "reads the vault, alone or with its descriptor, as each of the five writes' signer"
        $ forM_ writes
        $ \base -> do
            fmap signerOf (withArgs base vault)
                `shouldBe` Right (Just (SignerVault "alice.vault" Nothing))
            fmap signerOf (withArgs base withFd)
                `shouldBe` Right (Just (SignerVault "alice.vault" (Just 3)))
    it "reads the vault on an insert or a terminate that also folds"
        $ forM_
            [ entryBase "insert" ["--payload", "/p.json"]
            , entryBase "terminate" []
            ]
        $ \base ->
            fmap signerOf (withArgs base (withFd <> ["--fold"]))
                `shouldBe` Right (Just (SignerVault "alice.vault" (Just 3)))
    it
        "refuses a vault beside a key file or an address, the shared reader's refusal"
        $ forM_ writes
        $ \base -> do
            withArgs base (vault <> ["--wallet-skey", "/k"])
                `shouldSatisfy` refusedBy "--vault"
            withArgs
                base
                (vault <> ["--wallet-address", address, "--bundle", "run.bundle"])
                `shouldSatisfy` refusedBy "--vault"
    it "refuses a descriptor without a vault, by name" $
        forM_ writes $ \base ->
            withArgs base ["--passphrase-fd", "3"]
                `shouldSatisfy` refusedBy "--passphrase-fd"
    it
        "refuses the vault and its descriptor on every preview, naming each"
        $ forM_ previews
        $ \base -> do
            withArgs base (["--wallet-address", address] <> vault)
                `shouldBe` Left
                    ( BadValue
                        "--vault"
                        "cannot be used with --preview: a preview signs and writes nothing"
                    )
            withArgs base ["--wallet-address", address, "--passphrase-fd", "3"]
                `shouldBe` Left
                    ( BadValue
                        "--passphrase-fd"
                        "cannot be used with --preview: a preview signs and writes nothing"
                    )
    it "refuses the vault and its descriptor on inspect, naming each" $ do
        let inspectBase = ["open-datum", "inspect", "--key", "key"] <> reg <> provider
        parseOpenDatumCommand (inspectBase <> vault)
            `shouldBe` Left
                ( BadValue
                    "--vault"
                    ( "is not accepted by open-datum inspect: it reads, and takes the "
                        <> "address only to locate a journal"
                    )
                )
        parseOpenDatumCommand (inspectBase <> ["--passphrase-fd", "3"])
            `shouldBe` Left
                ( BadValue
                    "--passphrase-fd"
                    ( "is not accepted by open-datum inspect: it reads, and takes the "
                        <> "address only to locate a journal"
                    )
                )
    it
        "lists the vault route before the key file on each write's usage"
        $ forM_ ["create", "insert", "update", "terminate", "fold"]
        $ \verb ->
            let usage = usageOf verb
                at needle = findIndex (isPrefixOf needle) (tails usage)
            in  ((<) <$> at "--vault" <*> at "--wallet-skey") `shouldBe` Just True

-- ---------------------------------------------------------
-- A creator's seed and directory
-- ---------------------------------------------------------

-- ---------------------------------------------------------
-- The read-only preparation route
-- ---------------------------------------------------------

{- | @--preview@ names the caller by a public address and holds no key: the
parse refuses a key before anything is read, and the address is checked
against the network and for being an enterprise address. The addresses
are produced here from key hashes, never typed.
-}
previewRows :: Spec
previewRows = describe "--preview" $ do
    let payerHash = BS.replicate 28 0x5a
        strangerHash = BS.replicate 28 0x7b
        addrOf = addrFromKeyHashBytes
        textOf net h = bech32Address (addrOf net h)
        baseAddr = case addrOf Testnet payerHash of
            Addr net (KeyHashObj k) _ ->
                Addr net (KeyHashObj k) (StakeRefBase (KeyHashObj (coerceKeyRole k)))
            other -> other
        previewNode magic =
            [ "--koios-url"
            , "http://127.0.0.1:8080/api/v1"
            , "--network-magic"
            , magic
            ]
        insertPreview extra =
            parseOpenDatumCommand
                ( [ "open-datum"
                  , "insert"
                  , "--preview"
                  , "--key"
                  , "key"
                  , "--payload"
                  , "/p.json"
                  ]
                    <> reg
                    <> extra
                )
    it "reads a preview as a provider and a public address, with no key" $
        insertPreview
            (previewNode "1" <> ["--wallet-address", textOf Testnet payerHash])
            `shouldBe` Right
                ( OpenInsert
                    EntryArgs
                        { entryStateDir = Just "/srv/reg"
                        , entryAccess = access
                        , entryBlueprint = "/srv/plutus.json"
                        , entryMode =
                            Preview
                                (ProviderSettings "http://127.0.0.1:8080/api/v1" 1 Nothing Nothing)
                                (textOf Testnet payerHash)
                        , entryKey = Key "key"
                        , entryDocument = Just "/p.json"
                        , entryPayloadSchema = PlainSchema
                        , entryDeposit = Just minimumDeposit
                        , entryFund = Nothing
                        , entryMaxOutlay = Nothing
                        , entryReceipt = Nothing
                        , entryFold = False
                        }
                )
    it
        "reads --deposit on an insert preview, and refuses one below the minimum"
        $ do
            let address = ["--wallet-address", textOf Testnet payerHash]
                depositOf = \case
                    OpenInsert e -> entryDeposit e
                    _ -> Nothing
            fmap
                depositOf
                (insertPreview (previewNode "1" <> address <> ["--deposit", "3000000"]))
                `shouldBe` Right (Just 3_000_000)
            insertPreview (previewNode "1" <> address <> ["--deposit", "1999999"])
                `shouldBe` Left (DepositRefused (DepositBelowMinimum 1_999_999))
    it "refuses a signing key beside --preview before anything is read" $
        insertPreview
            ( previewNode "1"
                <> ["--wallet-address", textOf Testnet payerHash]
                <> wallet
            )
            `shouldBe` Left PreviewTakesNoKey
    it "names a missing address, and a missing provider" $ do
        insertPreview (previewNode "1")
            `shouldBe` Left (MissingFlag "--wallet-address")
        insertPreview ["--wallet-address", textOf Testnet payerHash]
            `shouldBe` Left (MissingFlag "--koios-url")
    it
        "reads the funding output and the allowance a write or a preview may use"
        $ do
            let funded = replicate 64 '3' <> "#1"
                parsed =
                    insertPreview
                        ( previewNode "1"
                            <> ["--wallet-address", textOf Testnet payerHash]
                            <> ["--fund-input", funded, "--max-outlay", "12000000"]
                        )
            fmap
                ( \case
                    OpenInsert a -> (fmap renderOutRef (entryFund a), entryMaxOutlay a)
                    _ -> (Nothing, Nothing)
                )
                parsed
                `shouldBe` Right (Just (T.pack funded), Just 12_000_000)
            insertPreview
                (previewNode "1" <> ["--wallet-address", "x", "--fund-input", "nope"])
                `shouldSatisfy` isLeftWith (\case BadValue "--fund-input" _ -> True; _ -> False)
            insertPreview
                (previewNode "1" <> ["--wallet-address", "x", "--max-outlay", "0"])
                `shouldSatisfy` isLeftWith (\case BadValue "--max-outlay" _ -> True; _ -> False)
    it "reads a create preview for a public address with an optional seed" $ do
        let create extra =
                parseOpenDatumCommand
                    ( ["open-datum", "create", "--preview"]
                        <> createReg
                        <> previewNode "1"
                        <> extra
                    )
        fmap
            ( \case
                OpenCreate _ a -> Just (createMode a, createPreview a, createSeed a)
                _ -> Nothing
            )
            (create ["--wallet-address", textOf Testnet payerHash])
            `shouldBe` Right
                ( Just
                    ( Preview
                        (ProviderSettings "http://127.0.0.1:8080/api/v1" 1 Nothing Nothing)
                        (textOf Testnet payerHash)
                    , True
                    , Nothing
                    )
                )
        create
            ["--wallet-address", textOf Testnet payerHash, "--wallet-skey", "/k"]
            `shouldBe` Left PreviewTakesNoKey
    it "refuses an address on a command that signs" $ do
        parseOpenDatumCommand
            ( ["open-datum", "insert", "--key", "key", "--payload", "/p.json"]
                <> reg
                <> provider
                <> wallet
                <> ["--wallet-address", textOf Testnet payerHash]
            )
            `shouldSatisfy` isLeftWith (\case BadValue "--wallet-address" _ -> True; _ -> False)
    describe
        "a spending constraint a command does not enforce is refused, never ignored"
        $ do
            let funded = replicate 64 '3' <> "#1"
                create extra =
                    parseOpenDatumCommand
                        ( ["open-datum", "create", "--seed", funded]
                            <> createReg
                            <> provider
                            <> wallet
                            <> extra
                        )
                inspect extra =
                    parseOpenDatumCommand
                        (["open-datum", "inspect", "--key", "key"] <> reg <> provider <> extra)
                terminate extra =
                    parseOpenDatumCommand
                        ( ["open-datum", "terminate", "--key", "key"]
                            <> reg
                            <> provider
                            <> wallet
                            <> extra
                        )
            it "refuses a create that states a maximum outlay or a funding input" $ do
                create ["--max-outlay", "1"]
                    `shouldBe` Left (UnsupportedFlag "--max-outlay" "create")
                create ["--fund-input", funded]
                    `shouldBe` Left (UnsupportedFlag "--fund-input" "create")
                create ["--fund-input", funded, "--max-outlay", "1"]
                    `shouldSatisfy` isLeftWith (\case UnsupportedFlag _ "create" -> True; _ -> False)
            it "refuses them on an inspect too" $ do
                inspect ["--max-outlay", "1"]
                    `shouldBe` Left (UnsupportedFlag "--max-outlay" "inspect")
                inspect ["--fund-input", funded]
                    `shouldBe` Left (UnsupportedFlag "--fund-input" "inspect")
            it
                "still reads them on the commands that enforce them, and a create without them"
                $ do
                    fmap
                        (\case OpenTerminate a -> entryMaxOutlay a; _ -> Nothing)
                        (terminate ["--max-outlay", "1"])
                        `shouldBe` Right (Just 1)
                    create [] `shouldSatisfy` either (const False) (const True)
                    inspect [] `shouldSatisfy` either (const False) (const True)
    describe "the public address" $ do
        it "round-trips a payment key hash for each network" $ do
            parseEnterpriseAddress 1 (textOf Testnet payerHash)
                `shouldBe` Right (addrOf Testnet payerHash)
            parseEnterpriseAddress 764_824_073 (textOf Mainnet payerHash)
                `shouldBe` Right (addrOf Mainnet payerHash)
        it "tells two callers apart" $
            parseEnterpriseAddress 1 (textOf Testnet payerHash)
                `shouldNotBe` parseEnterpriseAddress 1 (textOf Testnet strangerHash)
        it "refuses another network's address" $ do
            parseEnterpriseAddress 1 (textOf Mainnet payerHash)
                `shouldSatisfy` isLeftContaining "another network"
            parseEnterpriseAddress 764_824_073 (textOf Testnet payerHash)
                `shouldSatisfy` isLeftContaining "another network"
        it "refuses an address that carries a stake part" $
            parseEnterpriseAddress 1 (bech32Address baseAddr)
                `shouldSatisfy` isLeftContaining "enterprise"
        it "refuses text that is not an address, and a corrupted checksum" $ do
            parseEnterpriseAddress 1 "not an address"
                `shouldSatisfy` isLeftContaining "not bech32"
            let text = textOf Testnet payerHash
                corrupted = init text <> (if last text == 'q' then "p" else "q")
            parseEnterpriseAddress 1 corrupted
                `shouldSatisfy` isLeftContaining "not bech32"
  where
    isLeftContaining needle = \case
        Left why -> needle `isInfixOf` why
        Right _ -> False

-- ---------------------------------------------------------
-- Booking and folding as separate commands
-- ---------------------------------------------------------

foldCommandRows :: Spec
foldCommandRows = describe "booking and folding as separate commands" $ do
    let fold extra =
            parseOpenDatumCommand
                (["open-datum", "fold"] <> reg <> provider <> wallet <> extra)
        insertWith extra =
            parseOpenDatumCommand
                ( ["open-datum", "insert", "--key", "6b6579", "--payload", "/p.json"]
                    <> reg
                    <> provider
                    <> wallet
                    <> extra
                )
        terminateWith extra =
            parseOpenDatumCommand
                ( ["open-datum", "terminate", "--key", "6b6579"]
                    <> reg
                    <> provider
                    <> wallet
                    <> extra
                )
        outRef n = either error id (parseOutRef (T.pack (replicate 64 n <> "#1")))
        refusesBadValue flag = \case
            Left (BadValue name _) -> name == flag
            _ -> False
        refusesNaming flag word = \case
            Left (BadValue name why) -> name == flag && word `isInfixOf` why
            _ -> False
        writes =
            WriteSettings
                { writeProvider =
                    ProviderSettings "http://127.0.0.1:8080/api/v1" 42 Nothing Nothing
                , writeSigner = SignerKeyFile "/keys/payment.skey"
                , writeConfirmTimeout = Nothing
                }
    it
        "reads a fold with its registry, provider and wallet and nothing else"
        $ fold []
            `shouldBe` Right
                ( OpenFold
                    FoldArgs
                        { foldStateDir = Just "/srv/reg"
                        , foldAccess = access
                        , foldBlueprint = "/srv/plutus.json"
                        , foldWrite = writes
                        , foldRequest = Nothing
                        , foldFund = Nothing
                        , foldMaxOutlay = Nothing
                        , foldReceipt = Nothing
                        }
                )
    it
        "reads the request, the funding output, the outlay and the receipt a fold names"
        $ fold
            [ "--request"
            , replicate 64 'a' <> "#0"
            , "--fund-input"
            , replicate 64 'c' <> "#1"
            , "--max-outlay"
            , "3000000"
            , "--receipt"
            , "/r.json"
            ]
            `shouldBe` Right
                ( OpenFold
                    FoldArgs
                        { foldStateDir = Just "/srv/reg"
                        , foldAccess = access
                        , foldBlueprint = "/srv/plutus.json"
                        , foldWrite = writes
                        , foldRequest =
                            Just
                                (either error id (parseOutRef (T.pack (replicate 64 'a' <> "#0"))))
                        , foldFund = Just (outRef 'c')
                        , foldMaxOutlay = Just 3_000_000
                        , foldReceipt = Just "/r.json"
                        }
                )
    it "refuses a request that is not a transaction output reference" $
        fold ["--request", "not-a-request"]
            `shouldBe` Left
                ( BadValue
                    "--request"
                    (fromLeft "parsed" (parseOutRef "not-a-request"))
                )
    it
        "refuses a fold with no provider and wallet rather than starting a node"
        $ parseOpenDatumCommand (["open-datum", "fold"] <> reg)
            `shouldSatisfy` isLeftWith (\case UnsafeSettings _ -> True; _ -> False)
    it "refuses, by name, what a fold decides from its request"
        $ forM_
            [ ("--key", ["--key", "6b6579"])
            , ("--deposit", ["--deposit", "2000000"])
            , ("--payload", ["--payload", "/p.json"])
            , ("--preview", ["--preview"])
            , ("--fold", ["--fold"])
            ]
        $ \(flag, extra) -> fold extra `shouldSatisfy` refusesBadValue flag
    it
        "refuses every flag that spells a key, by name, so none is silently ignored"
        $ do
            -- the key reader's own flag set, which must hold both spellings
            map fst keyFlags `shouldBe` ["--key", "--key-hex"]
            forM_ keyFlags $ \(flag, _) ->
                fold [flag, "616c696365"] `shouldSatisfy` refusesBadValue flag
    it "books only unless --fold is given, on insert and on terminate" $ do
        fmap entryFoldOf (insertWith []) `shouldBe` Right False
        fmap entryFoldOf (insertWith ["--fold"]) `shouldBe` Right True
        fmap entryFoldOf (terminateWith []) `shouldBe` Right False
        fmap entryFoldOf (terminateWith ["--fold"]) `shouldBe` Right True
    it "refuses --fold where nothing is booked to be folded, by name" $ do
        parseOpenDatumCommand
            ( [ "open-datum"
              , "update"
              , "--key"
              , "6b6579"
              , "--payload"
              , "/p.json"
              , "--fold"
              ]
                <> reg
                <> provider
                <> wallet
            )
            `shouldSatisfy` refusesNaming "--fold" "insert and terminate"
        parseOpenDatumCommand
            ( [ "open-datum"
              , "insert"
              , "--preview"
              , "--key"
              , "6b6579"
              , "--payload"
              , "/p.json"
              , "--fold"
              ]
                <> reg
                <> provider
                <> ["--wallet-address", "addr_test1"]
            )
            `shouldSatisfy` refusesNaming "--fold" "preview"
    it
        "refuses --request on commands that do not fold, by name"
        $ do
            insertWith ["--request", replicate 64 'a' <> "#0"]
                `shouldSatisfy` refusesNaming "--request" "open-datum fold"
            terminateWith ["--request", replicate 64 'a' <> "#0"]
                `shouldSatisfy` refusesNaming "--request" "open-datum fold"
    it "describes fold, its --request and --fold in the help" $ do
        openDatumUsage `shouldSatisfy` isInfixOf "open-datum fold"
        usageOf "fold" `shouldSatisfy` isInfixOf "[--request TXID#IX]"
        usageOf "insert" `shouldSatisfy` isInfixOf "[--fold]"
  where
    entryFoldOf = \case
        OpenInsert e -> entryFold e
        OpenTerminate e -> entryFold e
        _ -> error "not an entry command"

-- ---------------------------------------------------------
-- Removed registry verbs (reclaim, reject stay in singular)
-- ---------------------------------------------------------

removedVerbsRows :: Spec
removedVerbsRows = describe "removed registry verbs" $ do
    it "refuses open-datum reject as an unknown command" $
        parseOpenDatumCommand
            (["open-datum", "reject"] <> reg <> provider <> wallet)
            `shouldSatisfy` isLeftWith (\case UnknownCommand _ -> True; _ -> False)
    it "refuses open-datum reclaim as an unknown command" $
        parseOpenDatumCommand
            ( ["open-datum", "reclaim", "--request", seedText]
                <> reg
                <> provider
                <> wallet
            )
            `shouldSatisfy` isLeftWith (\case UnknownCommand _ -> True; _ -> False)
    it "names no reclaim or reject verb in its openDatumUsage" $ do
        openDatumUsage `shouldNotSatisfy` isInfixOf "open-datum reclaim"
        openDatumUsage `shouldNotSatisfy` isInfixOf "open-datum reject"

-- ---------------------------------------------------------
-- Reading another address's outputs from the node
-- ---------------------------------------------------------

outputsAtRows :: Spec
outputsAtRows = describe "reading the outputs at an address with inspect" $ do
    let inspect extra =
            parseOpenDatumCommand
                (["open-datum", "inspect", "--key", "key"] <> reg <> provider <> extra)
        outputsAtOf = \case
            Right (OpenInspect i) -> Just (inspectOutputsAt i)
            _ -> Nothing
        others =
            [ ["open-datum", "create", "--seed", seedText]
                <> createReg
                <> provider
                <> wallet
            , ["open-datum", "insert", "--key", "key", "--payload", "/p.json"]
                <> reg
                <> provider
                <> wallet
            , ["open-datum", "update", "--key", "key", "--payload", "/p.json"]
                <> reg
                <> provider
                <> wallet
            , ["open-datum", "terminate", "--key", "key"]
                <> reg
                <> provider
                <> wallet
            , ["open-datum", "fold"] <> reg <> provider <> wallet
            ]
    it "reads the address an inspect names, and none by default" $ do
        outputsAtOf (inspect []) `shouldBe` Just Nothing
        outputsAtOf (inspect ["--outputs-at", "addr_test1xyz"])
            `shouldBe` Just (Just "addr_test1xyz")
    it "refuses it on every other command, by name, never ignoring it" $
        forM_ others $ \line ->
            parseOpenDatumCommand (line <> ["--outputs-at", "addr_test1xyz"])
                `shouldSatisfy` \case
                    Left (BadValue "--outputs-at" why) -> "open-datum inspect" `isInfixOf` why
                    _ -> False
    it "is described on the inspect usage" $
        usageOf "inspect" `shouldSatisfy` isInfixOf "[--outputs-at ADDR]"

-- | The usage lines of one command's help page, on one line.
usageOf :: String -> String
usageOf verb =
    unwords
        . concatMap words
        . takeWhile (not . null)
        . dropWhile (not . isPrefixOf "Usage:")
        . lines
        $ openDatumHelp [verb]

-- ---------------------------------------------------------
-- The payload schema (#719)
-- ---------------------------------------------------------

{- | @--payload-schema@ names the form a payload file is written in. Insert
and update read it; fold refuses it by name as it refuses @--payload@; the
value is one of two lower-case names.
-}
payloadSchemaRows :: Spec
payloadSchemaRows = describe "the payload schema setting (#719)" $ do
    let line verb extra =
            parseOpenDatumCommand
                ( ["open-datum", verb, "--key", "key", "--payload", "/p.json"]
                    <> extra
                    <> reg
                    <> provider
                    <> wallet
                )
    forM_ ["insert", "update"] $ \verb -> do
        forM_ ["plain", "detailed"] $ \name ->
            it ("reads --payload-schema " <> name <> " on " <> verb) $
                line verb ["--payload-schema", name] `shouldSatisfy` isRight
        it ("reads the =value spelling on " <> verb) $
            line verb ["--payload-schema=detailed"] `shouldSatisfy` isRight
        it ("reads " <> verb <> " without the setting, as before") $
            line verb [] `shouldSatisfy` isRight
        it
            ( "refuses a value that is not a schema name on "
                <> verb
                <> ", naming the flag"
            )
            $ forM_
                [ "yaml"
                , "Plain"
                , "DETAILED"
                , ""
                , "plain,detailed"
                , "detailed "
                , "json"
                ]
            $ \value ->
                line verb ["--payload-schema", value]
                    `shouldBe` Left
                        ( BadValue
                            "--payload-schema"
                            "is not a payload schema: give plain or detailed"
                        )
        it ("refuses the setting with no value on " <> verb) $
            line verb ["--payload-schema"]
                `shouldBe` Left (BadValue "--payload-schema" "needs a value")
    it "still needs the payload file on an insert that names the setting" $
        parseOpenDatumCommand
            ( [ "open-datum"
              , "insert"
              , "--key"
              , "key"
              , "--payload-schema"
              , "detailed"
              ]
                <> reg
                <> provider
                <> wallet
            )
            `shouldBe` Left (MissingFlag "--payload")
    it "refuses the setting on fold, by name, as it refuses --payload" $ do
        let fold extra =
                parseOpenDatumCommand
                    (["open-datum", "fold"] <> reg <> provider <> wallet <> extra)
            renamed = \case
                Left (BadValue _ why) -> Left (BadValue "--payload-schema" why)
                other -> other
        fold ["--payload-schema", "plain"]
            `shouldBe` renamed (fold ["--payload", "/p.json"])
        fold ["--payload-schema", "plain"]
            `shouldSatisfy` \case
                Left (BadValue "--payload-schema" why) -> "open-datum fold" `isInfixOf` why
                _ -> False
