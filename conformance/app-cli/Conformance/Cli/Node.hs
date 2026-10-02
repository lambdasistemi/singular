{- |
Module      : Conformance.Cli.Node
Description : The one place the CLI controls backend opens its node
License     : Apache-2.0

Composition for the CLI controls backend: one external-node session at
the socket, magic and funding key the options name, handed to every
backend action as capabilities — the read interface, the signed-only
write and the confirmation the @singular@ commands themselves use (a
transaction named by its id, awaited within its validity window). No
action sees the session, the mode or the raw submitter.
-}
module Conformance.Cli.Node
    ( NodeCaps (..)
    , withBackendNode
    ) where

import Data.Word (Word32)

import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.Node
    ( ExternalNode (..)
    , NodeMode (..)
    , NodeSession (..)
    , SignedSubmitter
    , awaitTxWindow
    , signedSubmitter
    , withNodeMode
    )
import Singular.Registry.Provider qualified as Cage

-- | What a backend action holds.
data NodeCaps = NodeCaps
    { ncReads :: Cage.Provider IO
    -- ^ One acquired view per operation
    , ncSubmit :: SignedSubmitter
    -- ^ Sends signed transactions; the node's answer, unchanged
    , ncConfirm :: ConwayTx -> String -> IO ()
    {- ^ Wait until a submitted transaction, named by its hex id, is on
    chain, within its validity window
    -}
    }

{- | Open the external node at a socket and magic, funded by the key in
the named file, and run the body with its capabilities.
-}
withBackendNode
    :: FilePath -> Word32 -> FilePath -> (NodeCaps -> IO a) -> IO a
withBackendNode sock magic skey body =
    withNodeMode (External (ExternalNode sock magic skey)) $ \sess ->
        body
            NodeCaps
                { ncReads = nsProvider sess
                , ncSubmit = signedSubmitter (nsSubmitter sess)
                , ncConfirm = awaitTxWindow
                }
