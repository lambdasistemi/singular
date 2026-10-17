{- |
Module      : Singular.Application.OpenDatum.FlagGroupExtentSpec
Description : Both production parsers accept exactly the shared flag group
License     : Apache-2.0

The accepted-flag extent comparison of the two production parsers. This
suite sees both packages, so the comparison lives here: for every flag
of the shared group, a command line using it is parsed by the real
registry parser and by the real open-datum parser, and both must accept
or refuse it the same way the shared reader does (never an unknown-flag
refusal for a flag the group owns); no flag outside the group is
accepted as common by either.

The planted divergence runs through the production code path: each
parser body is a function of the group it reads, and the controls apply
the same body to a group with one flag dropped and to one with one flag
renamed. The extent comparison must fail for each: a parser that kept a
table of its own would still accept the dropped flag and fail the
control.
-}
module Singular.Application.OpenDatum.FlagGroupExtentSpec (spec) where

import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.Either (isRight)
import Data.Text qualified as T
import Test.Hspec

import Cardano.Ledger.BaseTypes (Network (..))

import Singular.Application.OpenDatum.Command
    ( parseOpenDatumCommand
    , parseOpenDatumWithGroup
    )
import Singular.Application.OpenDatum.Command qualified as Sibling
    ( CLIError (..)
    )
import Singular.CLI.Command (parseCommand, parseWithGroup)
import Singular.CLI.Command qualified as Registry (CLIError (..))
import Singular.CLI.FlagGroup
    ( commonFlagGroup
    , commonSwitches
    , tokenizeWith
    )
import Singular.Registry.TxBuilder.Internal (addrFromKeyHashBytes)
import Singular.Registry.Wallet (bech32Address)

spec :: Spec
spec = describe "flag group extent" $ do
    bothOwnCommon
    bothRefuseOutside
    extrasAsymmetry
    anchors
    productionVariants
    createFollowsRegistry

{- | Open-datum's create accepts a signer exactly when the registry's create
does: both parsers answer the same create lines the same way, their
refusal texts differing only in the binary's own name.
-}
createFollowsRegistry :: Spec
createFollowsRegistry = describe "create follows the registry's create" $ do
    it
        "answers the external-signer create lines as the registry's create does"
        $ do
            let node = ["--koios-url", "u", "--network-magic", "1"]
                registryCreate extra =
                    parseCommand
                        (["registry", "create", "--blueprint", "b"] <> node <> extra)
                siblingCreate extra =
                    parseOpenDatumCommand
                        (["open-datum", "create", "--blueprint", "b"] <> node <> extra)
                inRegistryName =
                    T.unpack
                        . T.replace "open-datum inspect" "registry inspect"
                        . T.pack
                normalize (Registry.BadValue flag why) = Just (flag, inRegistryName why)
                normalize Registry.PreviewTakesNoKey = Just ("--wallet-skey", "no key")
                normalize _ = Nothing
                normalizeSibling (Sibling.BadValue flag why) =
                    Just (flag, inRegistryName why)
                normalizeSibling Sibling.PreviewTakesNoKey =
                    Just ("--wallet-skey", "no key")
                normalizeSibling _ = Nothing
                sameAs line = do
                    let registryAnswer = either normalize (const Nothing) (registryCreate line)
                        siblingAnswer =
                            either normalizeSibling (const Nothing) (siblingCreate line)
                    registryAnswer `shouldBe` siblingAnswer
            -- outside a preview, the address with its bundle file is accepted by
            -- both creates
            sameAs ["--wallet-address", anAddress, "--bundle", "b"]
            -- the address alone gets the shared reader's refusal in both
            sameAs ["--wallet-address", anAddress]
            -- the bundle file alone is meaningless in both
            sameAs ["--bundle", "b"]
            -- two signers together are refused by both
            sameAs
                ["--wallet-skey", "k", "--wallet-address", anAddress, "--bundle", "b"]
            -- a preview refuses the bundle file in both binaries
            sameAs ["--preview", "--wallet-address", anAddress, "--bundle", "b"]

-- | A bech32 payment-key address, produced from a key hash, never typed.
anAddress :: String
anAddress = bech32Address (addrFromKeyHashBytes Testnet (BS.replicate 28 0x5a))

-- | The one valued flag the registry parser owns beyond the group.
registryExtras :: [String]
registryExtras = ["--application-policy"]

-- | The full valued group each production parser reads.
registryFull :: [String]
registryFull = commonFlagGroup <> registryExtras

-- | The sibling parser owns no valued flag beyond the group.
siblingFull :: [String]
siblingFull = commonFlagGroup

-- | The refusal for a flag no parser reads.
registryUnknown :: String -> Registry.CLIError
registryUnknown flag = Registry.BadValue flag "is not a flag singular reads"

-- | The refusal for a flag no parser reads.
siblingUnknown :: String -> Sibling.CLIError
siblingUnknown flag = Sibling.BadValue flag "is not a flag singular reads"

-- | A well-formed state token spelling, built at run time.
extentToken :: String
extentToken = replicate 56 'a' <> "." <> replicate 64 'b'

-- | A valid registry fold; probes append one flag to it.
registryFold :: [String]
registryFold =
    [ "registry"
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

-- | A valid sibling fold; probes append one flag to it.
siblingFold :: [String]
siblingFold =
    [ "open-datum"
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

-- | A valid registry fold without its token, for the token variant.
registryFoldBare :: [String]
registryFoldBare =
    [ "registry"
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

-- | A valid registry fold without its url, for the url variant.
registryFoldNoKoios :: [String]
registryFoldNoKoios =
    [ "registry"
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

-- | A valid sibling fold without its token, for the token variant.
siblingFoldBare :: [String]
siblingFoldBare =
    [ "open-datum"
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

-- | A valid sibling fold without its url, for the url variant.
siblingFoldNoKoios :: [String]
siblingFoldNoKoios =
    [ "open-datum"
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

bothOwnCommon :: Spec
bothOwnCommon = describe "both parsers own the group" $ do
    forM_ commonFlagGroup $ \flag ->
        it ("both parsers own " <> flag) $ do
            parseCommand (registryFold <> [flag, "value"])
                `shouldNotBe` Left (registryUnknown flag)
            parseOpenDatumCommand (siblingFold <> [flag, "value"])
                `shouldNotBe` Left (siblingUnknown flag)
            tokenizeWith
                Registry.RemovedSetting
                Registry.BadValue
                registryFull
                ["cmd", flag, "value"]
                `shouldSatisfy` isRight
            tokenizeWith
                Registry.RemovedSetting
                Registry.BadValue
                siblingFull
                ["cmd", flag, "value"]
                `shouldSatisfy` isRight
    forM_ commonSwitches $ \flag ->
        it ("both parsers own " <> flag) $ do
            parseCommand (registryFold <> [flag])
                `shouldNotBe` Left (registryUnknown flag)
            parseOpenDatumCommand (siblingFold <> [flag])
                `shouldNotBe` Left (siblingUnknown flag)

bothRefuseOutside :: Spec
bothRefuseOutside = describe "both parsers refuse outside the group" $ do
    it "both parsers refuse a flag outside the group" $ do
        parseCommand ["registry", "fold", "--frobnicate", "x"]
            `shouldBe` Left (registryUnknown "--frobnicate")
        parseOpenDatumCommand ["open-datum", "fold", "--frobnicate", "x"]
            `shouldBe` Left (siblingUnknown "--frobnicate")

extrasAsymmetry :: Spec
extrasAsymmetry = describe "binary-owned extras" $ do
    it "the registry parser owns its extra valued flag" $
        parseCommand (registryFold <> ["--application-policy", "aa"])
            `shouldNotBe` Left (registryUnknown "--application-policy")
    it "the sibling parser refuses the registry-only valued flag" $
        parseOpenDatumCommand (siblingFold <> ["--application-policy", "aa"])
            `shouldBe` Left (siblingUnknown "--application-policy")

anchors :: Spec
anchors = describe "true groups parse" $ do
    it "the true groups parse a complete fold" $ do
        parseWithGroup
            registryFull
            []
            (registryFoldBare <> ["--state-token", extentToken])
            `shouldSatisfy` isRight
        parseOpenDatumWithGroup
            siblingFull
            []
            (siblingFoldBare <> ["--state-token", extentToken])
            `shouldSatisfy` isRight

-- | A group with one common flag dropped.
droppedRegistry :: [String]
droppedRegistry = filter (/= "--state-token") registryFull

-- | A group with one common flag renamed.
renamedRegistry :: [String]
renamedRegistry = map rename registryFull

-- | A group with one common flag dropped.
droppedSibling :: [String]
droppedSibling = filter (/= "--state-token") siblingFull

-- | A group with one common flag renamed.
renamedSibling :: [String]
renamedSibling = map rename siblingFull

rename :: String -> String
rename "--koios-url" = "--koios-URL"
rename other = other

productionVariants :: Spec
productionVariants = describe "planted divergence through the parsers" $ do
    it
        "a registry group dropping --state-token refuses it through the parser"
        $ parseWithGroup
            droppedRegistry
            []
            (registryFoldBare <> ["--state-token", extentToken])
            `shouldBe` Left (registryUnknown "--state-token")
    it
        "a registry group renaming --koios-url refuses it through the parser"
        $ parseWithGroup
            renamedRegistry
            []
            (registryFoldNoKoios <> ["--koios-url", "1"])
            `shouldBe` Left (registryUnknown "--koios-url")
    it "a dropped registry group still owns the flags it keeps" $
        parseWithGroup
            droppedRegistry
            []
            (registryFoldBare <> ["--koios-url", "1"])
            `shouldNotBe` Left (registryUnknown "--koios-url")
    it
        "a sibling group dropping --state-token refuses it through the parser"
        $ parseOpenDatumWithGroup
            droppedSibling
            []
            (siblingFoldBare <> ["--state-token", extentToken])
            `shouldBe` Left (siblingUnknown "--state-token")
    it
        "a sibling group renaming --koios-url refuses it through the parser"
        $ parseOpenDatumWithGroup
            renamedSibling
            []
            (siblingFoldNoKoios <> ["--koios-url", "1"])
            `shouldBe` Left (siblingUnknown "--koios-url")
    it "a dropped sibling group still owns the flags it keeps" $
        parseOpenDatumWithGroup
            droppedSibling
            []
            (siblingFoldBare <> ["--koios-url", "1"])
            `shouldNotBe` Left (siblingUnknown "--koios-url")
