{- |
Module      : Singular.CLI.FlagGroupSpec
Description : Both parsers accept exactly the shared flag group
License     : Apache-2.0

The accepted-flag extent of the registry parser and of the sibling
binary's parser, stated against the shared group: every common valued
flag and switch tokenizes through the shared readers, with today's
refusals, and each parser owns its documented extras beyond the group
(the registry parser one valued flag, the sibling binary none).

The sibling parser lives in another package, so its half runs through
the same shared readers with its extras (none): the shared tokenizer
with no extras is exactly what that parser calls, and the hosted
binary checks pin its surface unchanged. A parser variant that drops
or renames one common flag fails the extent rows below; the controls
prove it.
-}
module Singular.CLI.FlagGroupSpec (spec) where

import Cardano.Crypto.Hash.Class (hashFromBytes)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes (ScriptHash (..))
import Control.Monad (forM_)
import Data.ByteString qualified as BS (replicate)
import Data.ByteString.Base16 qualified as B16 (encode)
import Data.ByteString.Char8 qualified as BC (pack)
import Data.Either (isRight)
import Data.List (nub)
import Singular.CLI.Command
    ( CLIError (..)
    , WriteSettings (..)
    , parseCommand
    )
import Singular.CLI.FlagGroup
    ( Signer (..)
    , commonFlagGroup
    , commonSwitches
    , parseFlagGroup
    , readProviderSettings
    , splitTracingFor
    , tokenizeFor
    , tokenizeWith
    )
import Singular.CLI.Trace
    ( TraceFormat (..)
    , TraceLevel (..)
    , TraceRequest (..)
    , TraceSink (..)
    )
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.Wallet
    ( Wallet (..)
    , bech32Address
    , parseSignKey
    , walletFromSignKey
    )
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldNotBe
    , shouldSatisfy
    )

spec :: Spec
spec = describe "common flag group" $ do
    publishedGroup
    applicationPolicySpellingizer
    siblingTokenizer
    tracing
    settings
    registryCommand
    divergenceControls

-- | The accepted common valued flags, pinned in full.
pinnedCommonValued :: [String]
pinnedCommonValued =
    [ "--state-dir"
    , "--blueprint"
    , "--koios-url"
    , "--koios-token-file"
    , "--network-time"
    , "--network-magic"
    , "--wallet-skey"
    , "--seed"
    , "--process-time"
    , "--retract-time"
    , "--key"
    , "--key-hex"
    , "--receipt"
    , "--confirm-timeout"
    , "--wallet-address"
    , "--bundle"
    , "--vault"
    , "--passphrase-fd"
    , "--outputs-at"
    , "--fund-input"
    , "--max-outlay"
    , "--deposit"
    , "--payload"
    , "--payload-schema"
    , "--request"
    , "--state-token"
    , "--registry"
    ]

-- | The accepted common switches, pinned in full.
pinnedSwitches :: [String]
pinnedSwitches = ["--help", "-h", "--preview", "--fold"]

-- | The one valued flag the registry parser owns beyond the group.
registryExtras :: [String]
registryExtras = ["--application-policy"]

-- | The shared tokenizer with the registry parser's extras.
tokenizesRegistry
    :: [String] -> Either CLIError ([String], [(String, Maybe String)])
tokenizesRegistry = tokenizeFor RemovedSetting BadValue registryExtras

-- | The shared tokenizer with the sibling binary's extras: none.
tokenizesSibling
    :: [String] -> Either CLIError ([String], [(String, Maybe String)])
tokenizesSibling = tokenizeFor RemovedSetting BadValue []

publishedGroup :: Spec
publishedGroup = describe "published group" $ do
    it "publishes the accepted common valued flags" $
        commonFlagGroup `shouldBe` pinnedCommonValued
    it "publishes the accepted common switches" $
        commonSwitches `shouldBe` pinnedSwitches
    it "publishes no duplicate spelling" $
        nub commonFlagGroup `shouldBe` commonFlagGroup

applicationPolicySpellingizer :: Spec
applicationPolicySpellingizer = describe "registry tokenizer" $ do
    forM_ pinnedCommonValued $ \flag ->
        it ("takes " <> flag) $
            tokenizesRegistry ["cmd", flag, "value"]
                `shouldBe` Right (["cmd"], [(flag, Just "value")])
    it "takes the =value spelling" $
        tokenizesRegistry ["cmd", "--state-token=policy.name"]
            `shouldBe` Right (["cmd"], [("--state-token", Just "policy.name")])
    it "keeps the first of a repeated flag" $
        tokenizesRegistry
            ["cmd", "--state-token", "one", "--state-token", "two"]
            `shouldBe` Right (["cmd"], [("--state-token", Just "one")])
    it "keeps a value spelled like a flag" $
        tokenizesRegistry ["cmd", "--state-token", "--preview"]
            `shouldBe` Right (["cmd"], [("--state-token", Just "--preview")])
    it "takes the registry-only valued flag" $
        tokenizesRegistry ["cmd", "--application-policy", "aa"]
            `shouldBe` Right (["cmd"], [("--application-policy", Just "aa")])
    it "takes switches without values" $
        tokenizesRegistry ["cmd", "--preview"]
            `shouldBe` Right (["cmd"], [("--preview", Nothing)])
    it "refuses an unknown flag by name" $
        tokenizesRegistry ["cmd", "--frobnicate", "x"]
            `shouldBe` Left (BadValue "--frobnicate" "is not a flag singular reads")
    it
        "takes --registry, which was once a renamed flag, as the registry's address"
        $ tokenizesRegistry ["cmd", "--registry", "x"]
            `shouldBe` Right (["cmd"], [("--registry", Just "x")])
    it "refuses a removed setting by name" $
        tokenizesRegistry ["cmd", "--backend", "koios"]
            `shouldBe` Left (RemovedSetting "--backend")
    it "refuses a value flag without a value" $
        tokenizesRegistry ["cmd", "--state-token"]
            `shouldBe` Left (BadValue "--state-token" "needs a value")

siblingTokenizer :: Spec
siblingTokenizer = describe "sibling tokenizer" $ do
    forM_ pinnedCommonValued $ \flag ->
        it ("takes " <> flag) $
            tokenizesSibling ["cmd", flag, "value"]
                `shouldBe` Right (["cmd"], [(flag, Just "value")])
    it "takes switches without values" $
        tokenizesSibling ["cmd", "--fold"]
            `shouldBe` Right (["cmd"], [("--fold", Nothing)])
    it "refuses the registry-only valued flag" $
        tokenizesSibling ["cmd", "--application-policy", "aa"]
            `shouldBe` Left
                (BadValue "--application-policy" "is not a flag singular reads")
    it "refuses an unknown flag by name" $
        tokenizesSibling ["cmd", "--frobnicate", "x"]
            `shouldBe` Left (BadValue "--frobnicate" "is not a flag singular reads")

tracing :: Spec
tracing = describe "tracing" $ do
    it "takes --trace with a separate value" $
        splitTracingFor BadValue registryExtras ["cmd", "--trace", "what"]
            `shouldBe` Right (["cmd"], TraceRequest (Just TraceWhat) [] Nothing)
    it "takes the =value spelling" $
        splitTracingFor BadValue registryExtras ["cmd", "--trace=how"]
            `shouldBe` Right (["cmd"], TraceRequest (Just TraceHow) [] Nothing)
    it "keeps a value spelled like a tracing flag" $
        splitTracingFor
            BadValue
            registryExtras
            ["cmd", "--koios-url", "--trace"]
            `shouldBe` Right
                (["cmd", "--koios-url", "--trace"], TraceRequest Nothing [] Nothing)
    it "keeps the first level named" $
        splitTracingFor
            BadValue
            registryExtras
            ["cmd", "--trace", "what", "--trace", "how"]
            `shouldBe` Right (["cmd"], TraceRequest (Just TraceWhat) [] Nothing)
    it "collects one sink per --trace-to, in order" $
        splitTracingFor
            BadValue
            registryExtras
            ["cmd", "--trace-to", "stderr", "--trace-to", "file:/tmp/x.log"]
            `shouldBe` Right
                ( ["cmd"]
                , TraceRequest Nothing [ToStderr, ToFile "/tmp/x.log"] Nothing
                )
    it "takes --trace-format" $
        splitTracingFor
            BadValue
            registryExtras
            ["cmd", "--trace-format", "json"]
            `shouldBe` Right (["cmd"], TraceRequest Nothing [] (Just JsonFormat))
    it "refuses a bad level by name" $
        splitTracingFor BadValue registryExtras ["cmd", "--trace", "bogus"]
            `shouldBe` Left (BadValue "--trace" "is off, what or how")
    it "refuses a bad sink by name" $
        splitTracingFor
            BadValue
            registryExtras
            ["cmd", "--trace-to", "nowhere"]
            `shouldBe` Left (BadValue "--trace-to" "is stderr or file:PATH")
    it "refuses a bad format by name" $
        splitTracingFor
            BadValue
            registryExtras
            ["cmd", "--trace-format", "yaml"]
            `shouldBe` Left (BadValue "--trace-format" "is text or json")
    it "refuses a tracing flag without a value" $
        splitTracingFor BadValue registryExtras ["cmd", "--trace"]
            `shouldBe` Left (BadValue "--trace" "needs a value")

-- | Tokenized flags naming a complete node.
validProviderFlags :: [(String, Maybe String)]
validProviderFlags =
    [ ("--koios-url", Just "https://koios.example")
    , ("--network-magic", Just "1")
    ]

-- | Tokenized flags naming a complete write.
validWriteFlags :: [(String, Maybe String)]
validWriteFlags = validProviderFlags <> [("--wallet-skey", Just "key.skey")]

-- | The node the valid flags above name.
validProvider :: ProviderSettings
validProvider = ProviderSettings "https://koios.example" 1 Nothing Nothing

settings :: Spec
settings = describe "settings" $ do
    it "reads the node and network" $
        readProviderSettings MissingFlag BadValue validProviderFlags
            `shouldBe` Right validProvider
    it "refuses a missing url" $
        readProviderSettings MissingFlag BadValue []
            `shouldBe` Left (MissingFlag "--koios-url")
    it "refuses an empty url" $
        readProviderSettings
            MissingFlag
            BadValue
            [("--koios-url", Just ""), ("--network-magic", Just "1")]
            `shouldBe` Left (BadValue "--koios-url" "is empty")
    it "refuses a non-numeric magic" $
        readProviderSettings
            MissingFlag
            BadValue
            [("--koios-url", Just "u"), ("--network-magic", Just "abc")]
            `shouldBe` Left (BadValue "--network-magic" "not a number")
    it "reads a complete write" $
        parseFlagGroup
            MissingFlag
            BadValue
            UnsafeSettings
            WriteSettings
            validWriteFlags
            `shouldBe` Right (WriteSettings validProvider (SignerKeyFile "key.skey") Nothing)
    it "reads an external write from an address and a bundle file" $
        parseFlagGroup
            MissingFlag
            BadValue
            UnsafeSettings
            signerKeeper
            externalWriteFlags
            `shouldSatisfy` isRight
    it "refuses two signer modes together" $
        parseFlagGroup
            MissingFlag
            BadValue
            UnsafeSettings
            signerKeeper
            (externalWriteFlags <> [("--wallet-skey", Just "key.skey")])
            `shouldBe` Left
                ( BadValue
                    "--wallet-address"
                    "cannot be combined with --wallet-skey: a write takes exactly one signer"
                )
    it "refuses an address without a bundle file" $
        parseFlagGroup
            MissingFlag
            BadValue
            UnsafeSettings
            signerKeeper
            (validProviderFlags <> [("--wallet-address", Just signerSpelling)])
            `shouldBe` Left
                ( BadValue
                    "--bundle"
                    ( "is required with --wallet-address: the run's transactions are "
                        <> "written to the bundle for signing elsewhere"
                    )
                )
    it "refuses a bundle file without an address" $
        parseFlagGroup
            MissingFlag
            BadValue
            UnsafeSettings
            signerKeeper
            (validProviderFlags <> [("--bundle", Just "run.bundle")])
            `shouldBe` Left
                ( BadValue
                    "--bundle"
                    "is meaningless without --wallet-address: name the signer too"
                )
    it "refuses a bundle file with a preview" $
        parseFlagGroup
            MissingFlag
            BadValue
            UnsafeSettings
            signerKeeper
            (externalWriteFlags <> [("--preview", Nothing)])
            `shouldBe` Left
                ( BadValue
                    "--bundle"
                    "cannot be used with --preview: a preview signs and writes nothing"
                )
    it "refuses a script-payment address, naming it" $
        parseFlagGroup
            MissingFlag
            BadValue
            UnsafeSettings
            signerKeeper
            ( validProviderFlags
                <> [("--wallet-address", Just scriptSpelling), ("--bundle", Just "b")]
            )
            `shouldBe` Left
                ( BadValue
                    "--wallet-address"
                    ( scriptSpelling
                        <> " pays a script, not a payment key: the bundle's signer must be a payment key"
                    )
                )
    it "refuses a partial write before anything else" $
        parseFlagGroup MissingFlag BadValue UnsafeSettings WriteSettings []
            `shouldBe` Left
                ( UnsafeSettings
                    ( "partially configured write: missing --koios-url"
                        <> "; a write needs --koios-url, --network-magic and a signer: "
                        <> "--vault FILE (recommended), or --wallet-address ADDR with --bundle FILE, "
                        <> "or --wallet-skey FILE (a supported signer)"
                    )
                )
    it
        "names the signer forms, the vault first, for a write with none"
        $ parseFlagGroup
            MissingFlag
            BadValue
            UnsafeSettings
            WriteSettings
            validProviderFlags
            `shouldBe` Left
                ( UnsafeSettings
                    ( "partially configured write: no signer"
                        <> "; a write needs --koios-url, --network-magic and a signer: "
                        <> "--vault FILE (recommended), or --wallet-address ADDR with --bundle FILE, "
                        <> "or --wallet-skey FILE (a supported signer)"
                    )
                )
    it "refuses a non-numeric magic as unsafe" $
        parseFlagGroup
            MissingFlag
            BadValue
            UnsafeSettings
            WriteSettings
            [ ("--koios-url", Just "u")
            , ("--network-magic", Just "abc")
            , ("--wallet-skey", Just "k")
            ]
            `shouldBe` Left (UnsafeSettings "network magic is not a number: abc")
    it "refuses mainnet" $
        parseFlagGroup
            MissingFlag
            BadValue
            UnsafeSettings
            WriteSettings
            [ ("--koios-url", Just "u")
            , ("--network-magic", Just "764824073")
            , ("--wallet-skey", Just "k")
            ]
            `shouldBe` Left (UnsafeSettings "mainnet is not supported")
    it "refuses a bad confirmation timeout" $
        parseFlagGroup
            MissingFlag
            BadValue
            UnsafeSettings
            WriteSettings
            (validWriteFlags <> [("--confirm-timeout", Just "soon")])
            `shouldBe` Left
                (BadValue "--confirm-timeout" "is not a whole number of seconds")
    it "reads a vault write from a vault file and a passphrase descriptor" $
        parseFlagGroup
            MissingFlag
            BadValue
            UnsafeSettings
            WriteSettings
            (vaultWriteFlags <> [("--passphrase-fd", Just "3")])
            `shouldBe` Right
                ( WriteSettings
                    validProvider
                    (SignerVault "alice.vault" (Just 3))
                    Nothing
                )
    it "reads a vault write whose passphrase is asked at the terminal" $
        parseFlagGroup
            MissingFlag
            BadValue
            UnsafeSettings
            WriteSettings
            vaultWriteFlags
            `shouldBe` Right
                ( WriteSettings
                    validProvider
                    (SignerVault "alice.vault" Nothing)
                    Nothing
                )
    it "refuses a vault with a key file, as two signer modes" $
        parseFlagGroup
            MissingFlag
            BadValue
            UnsafeSettings
            signerKeeper
            (vaultWriteFlags <> [("--wallet-skey", Just "key.skey")])
            `shouldBe` Left
                ( BadValue
                    "--vault"
                    "cannot be combined with --wallet-skey: a write takes exactly one signer"
                )
    it "refuses a vault with an external signer, as two signer modes" $
        parseFlagGroup
            MissingFlag
            BadValue
            UnsafeSettings
            signerKeeper
            (externalWriteFlags <> [("--vault", Just "alice.vault")])
            `shouldBe` Left
                ( BadValue
                    "--vault"
                    "cannot be combined with --wallet-address: a write takes exactly one signer"
                )
    it "refuses the passphrase descriptor without a vault" $
        parseFlagGroup
            MissingFlag
            BadValue
            UnsafeSettings
            signerKeeper
            (validWriteFlags <> [("--passphrase-fd", Just "3")])
            `shouldBe` Left
                ( BadValue
                    "--passphrase-fd"
                    "is meaningless without --vault: name the vault too"
                )
    it "refuses a passphrase descriptor that is not a descriptor number" $
        parseFlagGroup
            MissingFlag
            BadValue
            UnsafeSettings
            signerKeeper
            (vaultWriteFlags <> [("--passphrase-fd", Just "stdin")])
            `shouldBe` Left (BadValue "--passphrase-fd" "not a descriptor number")

-- | Tokenized flags naming a complete vault write, the passphrase asked.
vaultWriteFlags :: [(String, Maybe String)]
vaultWriteFlags = validProviderFlags <> [("--vault", Just "alice.vault")]

-- | Tokenized flags naming a complete external write.
externalWriteFlags :: [(String, Maybe String)]
externalWriteFlags =
    validProviderFlags
        <> [ ("--wallet-address", Just signerSpelling)
           , ("--bundle", Just "run.bundle")
           ]

{- | The write reader's own view of what it hands the settings constructor:
whatever it read as the signer, projected to unit so the row pins only
that the line parses. The signer's own value is pinned end to end by the
staged-run rows over the rig.
-}
signerKeeper :: p -> s -> t -> ()
signerKeeper _provider _signer _timeout = ()

{- | The bech32 spelling of a payment-key enterprise address, derived at run
time from a fixed key through the wallet module's own derivation.
-}
signerSpelling :: String
signerSpelling = case parseSignKey (B16.encode (BC.pack (replicate 32 'w'))) of
    Right key -> bech32Address (walletAddr (walletFromSignKey 1 key))
    Left _ -> error "signerSpelling: a fixed 32-byte key always parses"

{- | The bech32 spelling of an address whose payment part is a script,
derived at run time.
-}
scriptSpelling :: String
scriptSpelling =
    bech32Address (Addr Testnet (ScriptHashObj scriptHash) StakeRefNull)
  where
    scriptHash = case hashFromBytes (BS.replicate 28 3) of
        Just h -> ScriptHash h
        Nothing -> error "scriptSpelling: 28 bytes are not a script hash"

-- | A well-formed state token spelling, built at run time.
applicationPolicySpelling :: String
applicationPolicySpelling = replicate 56 'a'

-- | A valid registry create command line; probes append one flag to it.
validStateCreate :: [String]
validStateCreate =
    [ "registry"
    , "create"
    , "--blueprint"
    , "blueprint.json"
    , "--application-policy"
    , applicationPolicySpelling
    , "--koios-url"
    , "https://koios.example"
    , "--network-magic"
    , "1"
    , "--wallet-skey"
    , "key.skey"
    ]

-- | The refusal for a flag no parser reads.
unknownRefusal :: String -> CLIError
unknownRefusal flag = BadValue flag "is not a flag singular reads"

registryCommand :: Spec
registryCommand = describe "registry command" $ do
    it "refuses an unknown flag by name" $
        parseCommand ["registry", "create", "--frobnicate", "x"]
            `shouldBe` Left (unknownRefusal "--frobnicate")
    forM_ (pinnedCommonValued <> registryExtras) $ \flag ->
        it ("owns " <> flag) $
            parseCommand (validStateCreate <> [flag, "value"])
                `shouldNotBe` Left (unknownRefusal flag)
    forM_ pinnedSwitches $ \flag ->
        it ("owns " <> flag) $
            parseCommand (validStateCreate <> [flag])
                `shouldNotBe` Left (unknownRefusal flag)

-- | Whether a full valued list accepts every common flag.
acceptsCommon :: [String] -> Bool
acceptsCommon full =
    all
        ( \flag ->
            isRight
                (tokenizeWith RemovedSetting BadValue full ["cmd", flag, "value"])
        )
        pinnedCommonValued

divergenceControls :: Spec
divergenceControls = describe "planted divergence controls" $ do
    it "the shared group accepts every common flag" $
        acceptsCommon (commonFlagGroup <> registryExtras) `shouldBe` True
    it "a variant dropping --state-token does not" $
        acceptsCommon
            (filter (/= "--state-token") commonFlagGroup <> registryExtras)
            `shouldBe` False
    it "a variant renaming --koios-url does not" $
        acceptsCommon (map rename commonFlagGroup <> registryExtras)
            `shouldBe` False
  where
    rename "--koios-url" = "--koios-URL"
    rename other = other
