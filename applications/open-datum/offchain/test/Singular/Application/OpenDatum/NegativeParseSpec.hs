{- |
Module      : Singular.Application.OpenDatum.NegativeParseSpec
Description : The host keeps caller-supplied option values
License     : Apache-2.0

The host translates only the command-namespace token (@registry@ in
command position) to the open-datum spelling and hands the rest to the
shared parser. These rows run the effect-free parse over the real
modules: an option value spelling @registry@ must reach the parsed
command unchanged, exactly like its inline @--flag=registry@ spelling
and exactly like the shared parser's own open-datum spelling. Every
compared parse is produced at run time; the state token spelling comes
from the boot fixture, never typed.
-}
module Singular.Application.OpenDatum.NegativeParseSpec (spec) where

import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short qualified as SBS
import Data.Either (isRight)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Test.Hspec

import Cardano.Ledger.Mary.Value (PolicyID (..))

import Negative.Parse
    ( NegativeInvocation (..)
    , parseNegativeInvocation
    )
import Singular.Application.OpenDatum.Command
    ( InspectArgs (..)
    , OpenDatumCommand (..)
    , parseOpenDatumCommandWithEnvironment
    )
import Singular.Application.OpenDatum.StateTokenFixture (token)
import Singular.Registry.Ledger (AssetName (..))
import Singular.Registry.TxBuilder.Internal (scriptHashBytes)

spec :: Spec
spec = describe "negative host namespace translation" $ do
    it "keeps --key registry and --state-dir registry as supplied values" $ do
        let separate =
                ["registry", "inspect"]
                    <> ["--blueprint", "/srv/plutus.json"]
                    <> ["--state-token", T.unpack tokenSpelling]
                    <> ["--key", "registry", "--state-dir", "registry"]
                    <> provider
            inline =
                ["registry", "inspect"]
                    <> ["--blueprint", "/srv/plutus.json"]
                    <> ["--state-token", T.unpack tokenSpelling]
                    <> ["--key=registry", "--state-dir=registry"]
                    <> provider
            shared =
                ["open-datum", "inspect"]
                    <> ["--blueprint", "/srv/plutus.json"]
                    <> ["--state-token", T.unpack tokenSpelling]
                    <> ["--key", "registry", "--state-dir", "registry"]
                    <> provider
            parsedSeparate = parseNegativeInvocation [] separate
            parsedInline = parseNegativeInvocation [] inline
        parsedSeparate `shouldSatisfy` isRight
        parsedInline `shouldSatisfy` isRight
        parsedSeparate `shouldBe` parsedInline
        (Ordinary <$> parseOpenDatumCommandWithEnvironment [] shared)
            `shouldBe` parsedSeparate
        case parsedSeparate of
            Right (Ordinary (OpenInspect args)) ->
                inspectStateDir args `shouldBe` Just "registry"
            _ ->
                expectationFailure
                    "registry inspect with registry values did not parse as an ordinary inspect"
    it "keeps --key withdraw as the withdrawn key" $ do
        let separate =
                ["registry", "withdraw"]
                    <> ["--blueprint", "/srv/plutus.json"]
                    <> ["--state-token", T.unpack tokenSpelling]
                    <> ["--key", "withdraw"]
                    <> provider
                    <> ["--wallet-skey", "/keys/payment.skey"]
            inline =
                ["registry", "withdraw"]
                    <> ["--blueprint", "/srv/plutus.json"]
                    <> ["--state-token", T.unpack tokenSpelling]
                    <> ["--key=withdraw"]
                    <> provider
                    <> ["--wallet-skey", "/keys/payment.skey"]
            parsedSeparate = parseNegativeInvocation [] separate
            parsedInline = parseNegativeInvocation [] inline
        parsedSeparate `shouldSatisfy` isRight
        parsedInline `shouldSatisfy` isRight
        parsedSeparate `shouldBe` parsedInline
    it "keeps the command with a leading inline flag" $ do
        let moved =
                ["--state-dir=./reg", "registry", "inspect"]
                    <> ["--blueprint", "/srv/plutus.json"]
                    <> ["--state-token", T.unpack tokenSpelling]
                    <> ["--key", "k"]
                    <> provider
            first =
                ["registry", "inspect", "--state-dir=./reg"]
                    <> ["--blueprint", "/srv/plutus.json"]
                    <> ["--state-token", T.unpack tokenSpelling]
                    <> ["--key", "k"]
                    <> provider
            parsedMoved = parseNegativeInvocation [] moved
            parsedFirst = parseNegativeInvocation [] first
        parsedFirst `shouldSatisfy` isRight
        parsedMoved `shouldBe` parsedFirst
    it "keeps withdraw with an inline flag between registry and withdraw" $ do
        let moved =
                ["registry", "--state-dir=./reg", "withdraw"]
                    <> ["--blueprint", "/srv/plutus.json"]
                    <> ["--state-token", T.unpack tokenSpelling]
                    <> ["--key", "k"]
                    <> provider
                    <> ["--wallet-skey", "/keys/payment.skey"]
            first =
                ["registry", "withdraw", "--state-dir=./reg"]
                    <> ["--blueprint", "/srv/plutus.json"]
                    <> ["--state-token", T.unpack tokenSpelling]
                    <> ["--key", "k"]
                    <> provider
                    <> ["--wallet-skey", "/keys/payment.skey"]
            parsedMoved = parseNegativeInvocation [] moved
            parsedFirst = parseNegativeInvocation [] first
        parsedFirst `shouldSatisfy` isRight
        parsedMoved `shouldBe` parsedFirst

provider :: [String]
provider =
    [ "--koios-url"
    , "http://127.0.0.1:8080/api/v1"
    , "--network-magic"
    , "42"
    ]

-- | The state token as a person copies it from the registry's page.
tokenSpelling :: T.Text
tokenSpelling =
    let (PolicyID policy, AssetName name) = token
    in  hexText (scriptHashBytes policy)
            <> "."
            <> hexText (SBS.fromShort name)
  where
    hexText = TE.decodeUtf8 . B16.encode
