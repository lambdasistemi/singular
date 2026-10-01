{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.CLI.Node
Description : The one place singular names the node it runs against
License     : Apache-2.0

Composition for the @singular@ commands. A command never sees the node:
it is handed capabilities, resolved here once from the three settings
the caller names (@--node-socket@, @--network-magic@, @--wallet-skey@).

* the read interface — a 'Cage.Provider', whose only entry is one
  acquired view;
* the write — a 'SignedSubmitter', which takes signed transactions only;
* the confirmation — the session's bounded wait for a transaction's
  first output.

A generated development network and an external node are reached the
same way: both are a node-to-client socket and a magic, opened by the
same session code. The CLI never spawns a node of its own.
-}
module Singular.CLI.Node
    ( -- * Settings
      writeTarget

      -- * Capabilities
    , Capabilities (..)
    , withReads
    , withWrites
    ) where

import Data.Word (Word32)

import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Node
    ( ExternalNode (..)
    , NodeMode (..)
    , NodeReads (..)
    , NodeSession (..)
    , awaitTxWindow
    , nodeModeFromArgs
    , withNodeMode
    , withNodeReads
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
runs another network.
-}
withReads :: Word32 -> FilePath -> (Cage.Provider IO -> IO a) -> IO a
withReads magic sock k = withNodeReads magic sock (k . nrProvider)

{- | Open the node at a socket and magic for a write funded by the key in
the named file: the handshake, the first view, the funding floor and the
announcement are the session's; the body runs with its capabilities and
must not use them after it returns.
-}
withWrites
    :: FilePath -> Word32 -> FilePath -> (Capabilities -> IO a) -> IO a
withWrites sock magic skey k =
    withNodeMode (External (ExternalNode sock magic skey)) $ \sess ->
        k
            Capabilities
                { capReads = nsProvider sess
                , capSubmit = signedSubmitter (nsSubmitter sess)
                , capConfirm = awaitTxWindow
                }
