{- |
Module      : Singular.Application.KeriStub.FlagGroupExtentSpec
Description : The stub's parser accepts exactly the shared flag group
License     : Apache-2.0

The accepted-flag extent comparison of the keri-stub parser. For every
flag of the shared group, a command line using it is parsed by the real
keri-stub parser and must never be refused as a flag the reader does not
know; no flag outside the group and the stub's own commands is accepted.

The planted divergence runs through the production code path: the parser
body is a function of the group it reads, and the controls apply the same
body to a group with one flag dropped and to one with one flag renamed.
The extent comparison must fail for each: a parser that kept a table of
its own would still accept the dropped flag and fail the control.
-}
module Singular.Application.KeriStub.FlagGroupExtentSpec (spec) where

import Control.Monad (forM_)
import Data.Either (isRight)
import Test.Hspec

import Singular.Application.KeriStub.Command
    ( CLIError (..)
    , parseKeriStubCommand
    , parseKeriStubWithGroup
    )
import Singular.CLI.FlagGroup
    ( commonFlagGroup
    , commonSwitches
    , tokenizeWith
    )

spec :: Spec
spec = describe "flag group extent" $ do
    ownsTheGroup
    refusesOutside
    anchors
    productionVariants

{- | The full valued group the stub's parser reads: the shared group plus
the stub's own valued flags. The stub owns @--evidence@, the hash a
convict carries; @register@ takes no valued flag beyond the group.
-}
stubFull :: [String]
stubFull = commonFlagGroup <> ["--evidence"]

-- | The refusal for a flag no parser reads.
stubUnknown :: String -> CLIError
stubUnknown flag = BadValue flag "is not a flag singular reads"

-- | A well-formed state token spelling, built at run time.
extentToken :: String
extentToken = replicate 56 'a' <> "." <> replicate 64 'b'

-- | A valid stub fold; probes append one flag to it.
stubFold :: [String]
stubFold =
    [ "keri-stub"
    , "fold"
    , "--blueprint"
    , "blueprint.json"
    , "--state-token"
    , extentToken
    , "--koios-url"
    , "u"
    , "--network-magic"
    , "1"
    , "--wallet-skey"
    , "k"
    ]

-- | A valid stub fold without its token, for the token variant.
stubFoldBare :: [String]
stubFoldBare =
    [ "keri-stub"
    , "fold"
    , "--blueprint"
    , "b"
    , "--koios-url"
    , "u"
    , "--network-magic"
    , "1"
    , "--wallet-skey"
    , "k"
    ]

-- | A valid stub fold without its url, for the url variant.
stubFoldNoKoios :: [String]
stubFoldNoKoios =
    [ "keri-stub"
    , "fold"
    , "--blueprint"
    , "b"
    , "--state-token"
    , extentToken
    , "--network-magic"
    , "1"
    , "--wallet-skey"
    , "k"
    ]

ownsTheGroup :: Spec
ownsTheGroup = describe "the stub's parser owns the shared group" $ do
    forM_ commonFlagGroup $ \flag ->
        it ("the stub's parser owns " <> flag) $ do
            parseKeriStubCommand (stubFold <> [flag, "value"])
                `shouldNotBe` Left (stubUnknown flag)
            tokenizeWith
                RemovedSetting
                BadValue
                stubFull
                ["cmd", flag, "value"]
                `shouldSatisfy` isRight
    it "the stub's parser owns --evidence on convict" $
        parseKeriStubCommand
            [ "keri-stub"
            , "convict"
            , "--key"
            , "hello"
            , "--evidence"
            , "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
            , "--blueprint"
            , "blueprint.json"
            , "--state-token"
            , extentToken
            , "--koios-url"
            , "u"
            , "--network-magic"
            , "1"
            , "--wallet-skey"
            , "k"
            ]
            `shouldSatisfy` isRight
    forM_ commonSwitches $ \flag ->
        it ("the stub's parser owns " <> flag) $
            parseKeriStubCommand (stubFold <> [flag])
                `shouldNotBe` Left (stubUnknown flag)

refusesOutside :: Spec
refusesOutside = describe "the stub's parser refuses outside the group" $ do
    it "refuses a flag outside the group" $
        parseKeriStubCommand ["keri-stub", "fold", "--frobnicate", "x"]
            `shouldBe` Left (stubUnknown "--frobnicate")
    it "refuses the registry parser's own valued flag" $
        parseKeriStubCommand (stubFold <> ["--application-policy", "aa"])
            `shouldBe` Left (stubUnknown "--application-policy")

anchors :: Spec
anchors =
    describe "true groups parse" $
        it "the true group parses a complete fold" $
            parseKeriStubWithGroup
                stubFull
                []
                (stubFoldBare <> ["--state-token", extentToken])
                `shouldSatisfy` isRight

-- | A group with one common flag dropped.
droppedStub :: [String]
droppedStub = filter (/= "--state-token") stubFull

-- | A group with one common flag renamed.
renamedStub :: [String]
renamedStub = map rename stubFull

rename :: String -> String
rename "--koios-url" = "--koios-URL"
rename other = other

productionVariants :: Spec
productionVariants = describe "planted divergence through the parser" $ do
    it
        "a stub group dropping --state-token refuses it through the parser"
        $ parseKeriStubWithGroup
            droppedStub
            []
            (stubFoldBare <> ["--state-token", extentToken])
            `shouldBe` Left (stubUnknown "--state-token")
    it
        "a stub group renaming --koios-url refuses it through the parser"
        $ parseKeriStubWithGroup
            renamedStub
            []
            (stubFoldNoKoios <> ["--koios-url", "1"])
            `shouldBe` Left (stubUnknown "--koios-url")
    it "a dropped stub group still owns the flags it keeps" $
        parseKeriStubWithGroup
            droppedStub
            []
            (stubFoldBare <> ["--koios-url", "1"])
            `shouldNotBe` Left (stubUnknown "--koios-url")
