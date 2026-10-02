{- |
Module      : Conformance.Run.Node
Description : The one place the conformance harness opens its node
License     : Apache-2.0

Composition for the harness's devnet sessions. The node is the devnet
this process spawns and follows with the in-memory indexer, or the
external node the joiner names; either way it is reached over
node-to-client, and every row is handed capabilities only — the read
interface (address reads answered by the indexer), the signed-only
write and the confirmation. No row sees the node, the mode or the raw
submitter.

Confirmation follows the mode: on the devnet the indexer reports the
block that carries the transaction, and how long that took is logged;
against an external node the historical fixed five-second wait stands.

A row session's node also replays every refused submission with traced
validators before the next one goes out ('withReplayingNode', #287): the
replay reads the refused transaction's inputs, the protocol parameters and
the era history over the same node-to-client connection.
-}
module Conformance.Run.Node
    ( checkHarnessGenesis
    , withHarnessNode
    , withReplayingNode
    ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel)
import Data.Text (Text)
import GHC.Clock (getMonotonicTime)

import Cardano.Node.Client.N2C.Connection
    ( newLSQChannel
    , newLTxSChannel
    , runNodeClient
    )
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.N2C.Submitter (mkN2CSubmitter)
import Cardano.Node.Client.N2C.Types (LSQChannel)
import Cardano.Node.Client.Provider qualified as N2C
import Cardano.Node.Client.Submitter (Submitter)
import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.Node
    ( Capabilities (..)
    , NodeMode (..)
    , adaptProvider
    , awaitConnection
    , awaitIndexed
    , boundedSubmitter
    , devnetGenesis
    , followedProvider
    , runMode
    , sessionMagic
    , signedSubmitter
    , submissionBound
    , withNodeSocket
    )

import Conformance.Mirror (emit, txIdHex)
import Conformance.Run.Environment (checkGenesis)
import Conformance.Run.Replay
    ( ReplayEnv (..)
    , ReplayIndex
    , capturingSubmitter
    , newReplayEnv
    )
import Conformance.Run.Submit (millis)

{- | Before a devnet spawns, its genesis directory must carry the devnet
files; nothing to check against an external node.
-}
checkHarnessGenesis :: IO ()
checkHarnessGenesis = devnetGenesis >>= mapM_ checkGenesis

{- | Open the harness's node and run the body with its capabilities; the
connection is closed when the body returns.
-}
withHarnessNode :: (Capabilities -> IO a) -> IO a
withHarnessNode body =
    openHarnessNode
        (\_ _ submit -> pure (submit, ()))
        (\caps () -> body caps)

{- | Open the harness's node as 'withHarnessNode' does, with every refused
submission captured and replayed before the next one: the blueprint the
traced build is made from, the receipts directory the replay evidence goes
beside, and the node's identity. The body also receives the replay index,
to name the row each rejection belongs to.
-}
withReplayingNode
    :: FilePath
    -> FilePath
    -> Text
    -> (Capabilities -> ReplayIndex -> IO a)
    -> IO a
withReplayingNode blueprintPath receiptsDir nodeId =
    openHarnessNode $ \n2c lsqCh submit -> do
        replay <- newReplayEnv n2c lsqCh blueprintPath receiptsDir nodeId
        pure (capturingSubmitter replay submit, reIndex replay)

{- | The node connection, its submitter shaped by the first argument before
anything submits through it.
-}
openHarnessNode
    :: ( N2C.Provider IO
         -> LSQChannel
         -> Submitter IO
         -> IO (Submitter IO, r)
       )
    -> (Capabilities -> r -> IO a)
    -> IO a
openHarnessNode wrap body = withNodeSocket $ \sock -> do
    lsqCh <- newLSQChannel 16
    ltxsCh <- newLTxSChannel 16
    nodeThread <-
        async $
            runNodeClient
                sessionMagic
                sock
                lsqCh
                ltxsCh
    let n2c = mkN2CProvider lsqCh
        nodeProv = adaptProvider sessionMagic n2c
    awaitConnection sessionMagic sock nodeThread nodeProv
    (submit, extra) <-
        wrap
            n2c
            lsqCh
            (boundedSubmitter submissionBound (mkN2CSubmitter ltxsCh))
    prov <- followedProvider nodeProv submit
    result <-
        body
            Capabilities
                { capReads = prov
                , capSubmit = signedSubmitter submit
                , capConfirm = confirm
                }
            extra
    cancel nodeThread
    pure result

-- | Wait until a submitted transaction is on chain, as the mode allows.
confirm :: ConwayTx -> IO ()
confirm tx = case runMode of
    Devnet -> do
        start <- getMonotonicTime
        awaitIndexed tx
        end <- getMonotonicTime
        emit
            "confirm"
            (txIdHex tx <> " indexed after " <> millis (end - start))
    External _ -> threadDelay 5_000_000
