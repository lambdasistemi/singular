module Main (main) where

import Data.List (isInfixOf)
import Naming.CLI.Options (Command (..), Connection (..), Options (..), parserInfo)
import Options.Applicative (
    ParserResult (..),
    defaultPrefs,
    execParserPure,
    renderFailure,
 )
import System.Exit (ExitCode (..))
import Test.Hspec (describe, hspec, it, shouldBe, shouldSatisfy)

main :: IO ()
main = hspec $ do
    describe "the selected naming registry" $ do
        it "requires explicit connection inputs instead of selecting a devnet" $
            refused ["attach"] `shouldBe` True
        it "preserves an explicit manifest, socket and network" $
            case parse (connection ++ ["attach"]) of
                Success Options{connection = c, command = Attach} ->
                    c `shouldBe` Connection "registry.json" "/run/node.socket" 42
                _ -> fail "explicit attach did not parse"
        it "refuses an invalid or overflowing network magic" $ do
            refused ["--deployment", "m", "--node-socket", "s", "--network-magic", "-1", "attach"] `shouldBe` True
            refused ["--deployment", "m", "--node-socket", "s", "--network-magic", "4294967296", "attach"] `shouldBe` True
        it "does not accept an unsupported implicit deploy" $
            refused (connection ++ ["deploy"]) `shouldBe` True
    describe "offline help" $ do
        it "works before reading any manifest, key or socket" $
            case parse ["--help"] of
                Failure failure -> do
                    let (message, code) = renderFailure failure "singular-naming"
                    code `shouldBe` ExitSuccess
                    message `shouldSatisfy` isInfixOf "attach"
                _ -> fail "help did not return successful usage"
        it "documents the inspect action without requiring connection flags" $
            case parse ["inspect", "--help"] of
                Failure failure -> do
                    let (message, code) = renderFailure failure "singular-naming"
                    code `shouldBe` ExitSuccess
                    message `shouldSatisfy` isInfixOf "--name"
                _ -> fail "inspect help did not return successful usage"
    describe "inspect" $ do
        it "requires a name" $
            refused (connection ++ ["inspect"]) `shouldBe` True
        it "does not normalize user spelling" $
            case parse (connection ++ ["inspect", "--name", "Alice"]) of
                Success Options{command = Inspect name} -> name `shouldBe` "Alice"
                _ -> fail "inspect did not parse"
        it "refuses an empty name" $
            refused (connection ++ ["inspect", "--name", ""]) `shouldBe` True
        it "rejects unused signing keys on read-only actions" $
            refused (connection ++ ["inspect", "--name", "alice", "--wallet-skey", "key.skey"]) `shouldBe` True
    describe "controller changes" $ do
        let maintain = connection ++ ["maintain", "--name", "alice", "--wallet-skey", "fees.skey", "--control-skey", "controller.skey"]
        it "requires an explicit destination change" $
            refused maintain `shouldBe` True
        it "refuses two conflicting destination choices" $
            refused (maintain ++ ["--payment-destination", "address", "--clear-payment-destination"]) `shouldBe` True
        it "requires the authorization key separately from fee funding" $
            refused (connection ++ ["maintain", "--name", "alice", "--wallet-skey", "fees.skey", "--clear-payment-destination"]) `shouldBe` True
  where
    connection = ["--deployment", "registry.json", "--node-socket", "/run/node.socket", "--network-magic", "42"]
    parse = execParserPure defaultPrefs parserInfo
    refused args = case parse args of
        Failure _ -> True
        _ -> False
