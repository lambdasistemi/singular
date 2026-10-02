{- |
Module      : Main
Description : #326 — the backend contract suite, every adapter
License     : Apache-2.0

With no arguments: the in-memory adapter, the indexer adapter over the
in-memory node, and the node and indexer adapters on development nodes
the suite generates, plus the session's connection guard on a generated
node.

With @--node-socket PATH --network-magic N --wallet-skey FILE@: the node
and indexer adapters on the node at that socket, started outside the
suite, built from those settings by the same constructor a @singular@
write uses. A partial set is refused; the external leg never falls back
to a generated node.
-}
module Main (main) where

import Data.Word (Word32)
import System.Environment (getArgs, withArgs)
import System.Exit (die)
import Test.Hspec (hspec)
import Text.Read (readMaybe)

import Singular.Registry.ContractMemory
    ( indexerMemoryHarness
    , memoryHarness
    )
import Singular.Registry.ContractNode
    ( Leg (..)
    , guardOnDevnet
    , nodeHarness
    , phaseLogOnDevnet
    )
import Singular.Registry.ContractSuite (contractSuite)
import Singular.Registry.Node.Options (Backend (..))

main :: IO ()
main = do
    args <- getArgs
    case external args of
        Left problem -> die ("contract-tests: " <> problem)
        Right (Just (sock, magic, skey)) ->
            withArgs [] . hspec $ do
                contractSuite (nodeHarness (Outside sock magic skey) NodeBackend)
                contractSuite (nodeHarness (Outside sock magic skey) IndexerBackend)
        Right Nothing ->
            withArgs args . hspec $ do
                contractSuite memoryHarness
                contractSuite indexerMemoryHarness
                contractSuite (nodeHarness Generated NodeBackend)
                contractSuite (nodeHarness Generated IndexerBackend)
                guardOnDevnet
                phaseLogOnDevnet

{- | The external node the command line names: all three settings, none,
or a refusal naming what is missing.
-}
external
    :: [String] -> Either String (Maybe (FilePath, Word32, FilePath))
external args = case (flag "--node-socket", flag "--network-magic", flag "--wallet-skey") of
    (Nothing, Nothing, Nothing) -> Right Nothing
    (Just sock, Just m, Just skey) ->
        maybe
            (Left ("--network-magic is not a number: " <> m))
            (\magic -> Right (Just (sock, magic, skey)))
            (readMaybe m)
    _ ->
        Left
            "the external leg needs --node-socket, --network-magic and \
            \--wallet-skey together"
  where
    flag name = case dropWhile (/= name) args of
        (_ : v : _) -> Just v
        _ -> Nothing
