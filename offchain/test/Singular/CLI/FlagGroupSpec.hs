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

import Control.Monad (forM_)
import Data.Either (isRight)
import Data.List (nub)
import Test.Hspec

import Singular.CLI.Command
    ( CLIError (..)
    , WriteSettings (..)
    , parseCommand
    )
import Singular.CLI.FlagGroup
    ( commonFlagGroup
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

spec :: Spec
spec = describe "common flag group" $ do
    publishedGroup
    registryTokenizer
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
    , "--outputs-at"
    , "--fund-input"
    , "--max-outlay"
    , "--deposit"
    , "--payload"
    , "--request"
    , "--state-token"
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

registryTokenizer :: Spec
registryTokenizer = describe "registry tokenizer" $ do
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
    it "refuses a renamed flag by name" $
        tokenizesRegistry ["cmd", "--registry", "x"]
            `shouldBe` Left (BadValue "--registry" "was renamed to --state-dir")
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
            `shouldBe` Right (WriteSettings validProvider "key.skey" Nothing)
    it "refuses a partial write before anything else" $
        parseFlagGroup MissingFlag BadValue UnsafeSettings WriteSettings []
            `shouldBe` Left
                ( UnsafeSettings
                    ( "partially configured write: missing --koios-url"
                        <> "; a write needs --koios-url, --network-magic and --wallet-skey"
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

-- | A well-formed state token spelling, built at run time.
registryToken :: String
registryToken = replicate 56 'a' <> "." <> replicate 64 'b'

-- | A valid fold command line; probes append one flag to it.
validFold :: [String]
validFold =
    [ "registry"
    , "fold"
    , "--blueprint"
    , "blueprint.json"
    , "--state-token"
    , registryToken
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
        parseCommand ["registry", "fold", "--frobnicate", "x"]
            `shouldBe` Left (unknownRefusal "--frobnicate")
    forM_ (pinnedCommonValued <> registryExtras) $ \flag ->
        it ("owns " <> flag) $
            parseCommand (validFold <> [flag, "value"])
                `shouldNotBe` Left (unknownRefusal flag)
    forM_ pinnedSwitches $ \flag ->
        it ("owns " <> flag) $
            parseCommand (validFold <> [flag])
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
