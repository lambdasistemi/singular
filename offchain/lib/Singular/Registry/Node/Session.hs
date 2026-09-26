{- |
Module      : Singular.Registry.Node.Session
Description : The open session state a runner confirms through
License     : Apache-2.0

The owner of the session record every runner reads ('NodeSession') and
of the process's open-session state: 'withOpenSession' installs a
session for the runner body and removes it at bracket exit, normal or
exceptional, so a confirmation that escapes the session's lifetime
names its error instead of guessing a chain.

The session is opened and torn down by 'Singular.Registry.Node'
re-exports ('withNode' and friends, owned by
"Singular.Registry.Node.Session"'s connect half once extraction
completes); readers outside this module reach the open session only
through 'sessionFor', 'scriptStakeRegistered' and 'currentTipSlot'.
-}
module Singular.Registry.Node.Session (
    -- * Session
    NodeSession (..),

    -- * Open-session state
    withOpenSession,
    sessionFor,
    scriptStakeRegistered,
    currentTipSlot,
) where

import Control.Exception (bracket_)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import System.IO.Unsafe (unsafePerformIO)

import Ouroboros.Network.Magic (NetworkMagic)

import Cardano.Ledger.BaseTypes (Network, SlotNo)
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Node.Client.Submitter (Submitter)
import Singular.Registry.Ledger (ConwayEra, PParams)
import Singular.Registry.Node.Options (NodeMode, die)
import Singular.Registry.Provider qualified as Cage

-- | Everything a runner needs from the chain it runs against.
data NodeSession = NodeSession
    { nsProvider :: Cage.Provider IO
    -- ^ Queries, over the connected node
    , nsSubmitter :: Submitter IO
    -- ^ Transaction submission, over the same connection
    , nsMagic :: NetworkMagic
    -- ^ Magic the handshake negotiated
    , nsNetwork :: Network
    -- ^ Network the funding address is built for
    , nsPParams :: PParams ConwayEra
    -- ^ Protocol parameters queried from the running node
    , nsScriptRegistered :: ScriptHash -> IO Bool
    -- ^ Whether this script has a registered reward account, including zero balance
    , nsTipSlot :: IO SlotNo
    -- ^ Current chain tip queried from this session
    , nsMode :: NodeMode
    -- ^ Mode this session was opened in
    }

{- | The session this process currently has open, installed by
'withNodeMode'. 'awaitTx' is the only reader: it needs the chain the
run is against, and threading a provider through every submission site
would say nothing the session does not already know. Outside a
session it names the error rather than guessing.
-}
openSession :: IORef (Maybe NodeSession)
openSession = unsafePerformIO (newIORef Nothing)
{-# NOINLINE openSession #-}

{- | Install a session for the runner body and remove it afterwards, on
normal return and on exception alike. The single writer of the
open-session state.
-}
withOpenSession :: NodeSession -> IO a -> IO a
withOpenSession sess =
    bracket_
        (writeIORef openSession (Just sess))
        (writeIORef openSession Nothing)

-- | Registration is global to a script credential, shared by registries.
scriptStakeRegistered :: ScriptHash -> IO Bool
scriptStakeRegistered h = readIORef openSession >>= maybe (die "scriptStakeRegistered called outside a node session") (`nsScriptRegistered` h)

-- | Read the live tip for a transaction built in the active session.
currentTipSlot :: IO SlotNo
currentTipSlot = readIORef openSession >>= maybe (die "currentTipSlot called outside a node session") nsTipSlot

-- | The open session, or name the confirmation called outside one.
sessionFor :: String -> IO NodeSession
sessionFor what =
    readIORef openSession
        >>= maybe
            ( die
                ( what
                    <> " was called outside a node session; a runner must \
                       \wait for confirmation inside withNode"
                )
            )
            pure
