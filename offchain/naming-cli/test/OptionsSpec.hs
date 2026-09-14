module Main (main) where

import Cardano.Ledger.Mary.Value (AssetName (..))
import Data.ByteString.Short (toShort)
import Data.List (isInfixOf)
import Naming.CLI.Options (Command (..), Connection (..), Options (..), parserInfo)
import Naming.CLI.Values (CandidateResult (..), authenticateCandidates, authenticateName)
import Naming.Register (overMarkerFor, representativeName)
import Options.Applicative (
    ParserResult (..),
    defaultPrefs,
    execParserPure,
    renderFailure,
 )
import Singular.Registry.Ledger (TokenId (..))
import Singular.Registry.Trie qualified as Trie
import Singular.Registry.Trie.PureManager (mkPureTrieManager)
import System.Exit (ExitCode (..))
import Test.Hspec (describe, hspec, it, shouldBe, shouldReturn, shouldSatisfy)

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
    describe "authenticated name values" $ do
        it "authenticates the accepted spelling-derived Active and Over values without changing the mirror" $ do
            (manager, token, _) <- fixture
            let rep = representativeName "alice"
            activeRoot <- Trie.withTrie manager token $ \trie -> do
                _ <- Trie.delete trie "alice"
                Trie.insert trie "alice" rep
            authenticateName manager token "alice" activeRoot `shouldReturn` Authenticated rep
            Trie.withTrie manager token Trie.getRoot `shouldReturn` activeRoot
            overRoot <- Trie.withTrie manager token $ \trie -> do
                _ <- Trie.delete trie "alice"
                Trie.insert trie "alice" (overMarkerFor rep)
            authenticateName manager token "alice" overRoot `shouldReturn` Authenticated (overMarkerFor rep)
            Trie.withTrie manager token Trie.getRoot `shouldReturn` overRoot
        it "refuses an occupied spelling containing another name's representative" $ do
            (manager, token, _) <- fixture
            root <- Trie.withTrie manager token $ \trie -> do
                _ <- Trie.delete trie "alice"
                Trie.insert trie "alice" (representativeName "bob")
            authenticateName manager token "alice" root `shouldReturn` ValueUnavailable
            Trie.withTrie manager token Trie.getRoot `shouldReturn` root
        it "accepts the stored value and rejects a wrong preimage without changing the mirror" $ do
            (manager, token, root) <- fixture
            authenticateCandidates manager token "alice" root ["wrong", "representative"] `shouldReturn` Authenticated "representative"
            authenticateCandidates manager token "alice" root ["wrong"] `shouldReturn` ValueUnavailable
            Trie.withTrie manager token Trie.getRoot `shouldReturn` root
        it "refuses duplicate matching candidates rather than selecting an arbitrary output" $ do
            (manager, token, root) <- fixture
            authenticateCandidates manager token "alice" root ["representative", "representative"] `shouldReturn` ValueAmbiguous
            Trie.withTrie manager token Trie.getRoot `shouldReturn` root
        it "does not interpret the existing lookup sentinel as the stored value" $ do
            (manager, token, root) <- fixture
            sentinel <- Trie.withTrie manager token (\trie -> Trie.lookup trie "alice")
            case sentinel of
                Just candidate -> authenticateCandidates manager token "alice" root [candidate] `shouldReturn` ValueUnavailable
                Nothing -> fail "fixture name was not occupied"
            Trie.withTrie manager token Trie.getRoot `shouldReturn` root
  where
    fixture = do
        manager <- mkPureTrieManager
        let token = TokenId (AssetName (toShort "registry"))
        Trie.createTrie manager token
        _ <- Trie.withTrie manager token (\trie -> Trie.insert trie "bob" "another-value")
        root <- Trie.withTrie manager token (\trie -> Trie.insert trie "alice" "representative")
        pure (manager, token, root)
    connection = ["--deployment", "registry.json", "--node-socket", "/run/node.socket", "--network-magic", "42"]
    parse = execParserPure defaultPrefs parserInfo
    refused args = case parse args of
        Failure _ -> True
        _ -> False
