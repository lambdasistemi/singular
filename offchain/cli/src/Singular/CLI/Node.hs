{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.CLI.Node
Description : The one place singular names the node it runs against
License     : Apache-2.0

Composition for the @singular@ commands. A command never sees the node:
it is handed capabilities, resolved here once from the settings the
caller names (@--node-socket@, @--network-magic@, @--wallet-skey@ and
@--backend@).

* the read interface — a 'Cage.Provider', whose only entry is one
  acquired view;
* the write — a 'SignedSubmitter', which takes signed transactions only;
* the confirmation — the session's bounded wait for a transaction's
  first output.

A generated development network and an external node are reached the
same way: both are a node-to-client socket and a magic, opened by the
same session code. The CLI never spawns a node of its own.

The backend decides where a view's address reads come from: the node
itself (@node@, the default), or an in-process UTxO index that follows the
node's chain from its origin for as long as the command runs
(@indexer@), answering at each view's chain point. Under the indexer
backend an index refusal ends the command with its one-line diagnostic,
and the command reports on standard error how many address reads the
index answered.
-}
module Singular.CLI.Node
    ( -- * Settings
      writeTarget
    , Backend (..)
    , backendSetting

      -- * Capabilities
    , Capabilities (..)
    , withReads
    , withWrites
    ) where

import Control.Exception (displayException, finally, handle)
import Data.Foldable (traverse_)
import Data.Word (Word32)
import System.Environment (getArgs)
import System.IO (hPutStrLn, stderr)

import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Node
    ( ExternalNode (..)
    , NodeMode (..)
    , NodeReads (..)
    , NodeSession (..)
    , awaitTxWindow
    , nodeAddressReads
    , nodeModeFromArgs
    )
import Singular.Registry.Node.IndexGate (gateServed)
import Singular.Registry.Node.Indexer
    ( Following (..)
    , currentFollower
    )
import Singular.Registry.Node.IndexerView (IndexerViewFailure)
import Singular.Registry.Node.Options
    ( Backend (..)
    , backendFromArgs
    , die
    )
import Singular.Registry.Node.Session
    ( withNodeModeOn
    , withNodeReadsOn
    )
import Singular.Registry.Node.Submit
    ( SignedSubmitter
    , signedSubmitter
    )
import Singular.Registry.Provider qualified as Cage

{- | The socket, magic and signing-key file a write names, read through
the node module's own parser so a partial set and mainnet are refused
with its diagnostics. 'Nothing' when the command line names none of the
three.
-}
writeTarget
    :: [String] -> Either String (Maybe (FilePath, Word32, FilePath))
writeTarget args =
    nodeModeFromArgs args [] >>= \case
        Devnet -> Right Nothing
        External e -> Right (Just (extSocket e, extMagic e, extSkeyFile e))

{- | The read backend a command line names with @--backend@ (@node@, the
default, or @indexer@), read through the node module's own parser so a
value it does not name is refused before anything runs.
-}
backendSetting :: [String] -> Either String Backend
backendSetting = backendFromArgs

-- | What a write command holds: reads, the signed-only write, confirmation.
data Capabilities = Capabilities
    { capReads :: Cage.Provider IO
    -- ^ One acquired view per operation
    , capSubmit :: SignedSubmitter
    -- ^ Sends signed transactions; the node's answer, unchanged
    , capConfirm :: ConwayTx -> String -> IO ()
    {- ^ Wait until a submitted transaction, named by its hex id, is on
    chain, within its validity window
    -}
    }

{- | The read interface over the node at a socket and magic, for a command
that holds no key. Refuses, by name, a node that does not answer or
runs another network; under the indexer backend, an index that cannot
answer at the node's point.
-}
withReads :: Word32 -> FilePath -> (Cage.Provider IO -> IO a) -> IO a
withReads magic sock k = do
    backend <- processBackend
    refusing . withNodeReadsOn backend magic sock $ \r ->
        reporting backend (k (nrProvider r))

{- | Open the node at a socket and magic for a write funded by the key in
the named file: the handshake, the first view, the funding floor and the
announcement are the session's; the body runs with its capabilities and
must not use them after it returns. Under the indexer backend the
funding wallet must be one the index covers.
-}
withWrites
    :: FilePath -> Word32 -> FilePath -> (Capabilities -> IO a) -> IO a
withWrites sock magic skey k = do
    backend <- processBackend
    refusing
        . withNodeModeOn backend (External (ExternalNode sock magic skey))
        $ \sess ->
            reporting backend $
                k
                    Capabilities
                        { capReads = nsProvider sess
                        , capSubmit = signedSubmitter (nsSubmitter sess)
                        , capConfirm = awaitTxWindow
                        }

{- | The backend this process's command line names. The command line was
already checked by the same parser before anything ran, and it does not
change while the process lives.
-}
processBackend :: IO Backend
processBackend =
    getArgs >>= either (die . ("--backend " <>)) pure . backendFromArgs

-- | An indexer refusal ends the command with its one-line diagnostic.
refusing :: IO a -> IO a
refusing = handle $ \(failure :: IndexerViewFailure) ->
    die (displayException failure)

{- | Under the indexer backend, report on standard error, when the body
ends, how many address reads the index answered and how many went to
the node: the index's own count, which a session reading through the
node leaves at zero.
-}
reporting :: Backend -> IO a -> IO a
reporting = \case
    NodeBackend -> id
    IndexerBackend -> (`finally` report)
  where
    report =
        currentFollower
            >>= traverse_
                ( \following -> do
                    served <- gateServed (followingGate following)
                    fromNode <- nodeAddressReads
                    hPutStrLn stderr $
                        "node: indexer backend: "
                            <> show served
                            <> " address reads answered by the index, "
                            <> show fromNode
                            <> " by the node"
                )
