{- |
Module      : Singular.Registry.Node
Description : Node and funding-wallet entry point for every runner
License     : Apache-2.0

The single import every runner keeps: the node's public surface. This
module is a compatibility facade — it owns no state and no definition,
only the exact export list callers have always imported, re-exported
from the focused owners behind it:

* "Singular.Registry.Node.Options" — the mode, resolved once from the
  command line and the environment, and the mode-gated diagnostics.
* "Singular.Registry.Node.Wallet" — the wallet that funds a run, its
  key parsing and address rendering.
* "Singular.Registry.Node.Indexer" — the chain follower state, the
  indexed reads and confirmations it answers, and the node address-read
  guard and counter.
* "Singular.Registry.Node.Session" — opening, holding and closing a
  session, including the devnet bracket and the open-session state.
* "Singular.Registry.Node.Confirmation" — the waits, deadlines and
  chain observations a runner takes after submitting.
* "Singular.Registry.Node.Funding" — the funding floor a run must
  clear before it starts.

Two modes, chosen once per process from the command line and the
environment:

* __devnet__ (the default, unchanged behaviour): spawn a private
  @cardano-node@ over the checked-in genesis, magic 42, and fund every
  actor from the genesis UTxO key.
* __external__ (@--node-socket@, @--network-magic@, @--wallet-skey@, or
  the @SINGULAR_NODE_SOCKET@, @SINGULAR_NETWORK_MAGIC@,
  @SINGULAR_WALLET_SKEY@ environment variables): connect to a node the
  joiner already runs and fund every actor from the joiner's own
  signing key.

Both modes build the same N2C provider and submitter over a socket, so
external mode is not a second implementation of the runners — it is the
same code reached with a different socket and a different wallet.

Every session follows its chain with an in-memory UTxO indexer: the
devnet from its origin, an external node from its tip when the session
opens. Confirmations are the indexer's on both. Address reads are the
indexer's on the devnet and the node's on an external chain, whose
older outputs the indexer never saw.

The network magic is verified by the node-to-client handshake itself:
'runNodeClient' negotiates the requested magic and a node running
another network rejects the connection. 'withNodeMode' turns that
rejection into a named diagnostic instead of a bare protocol error.

Key material is read from the joiner's file and never printed; only the
derived (public) address is reported.
-}
module Singular.Registry.Node
    ( -- * Mode
      NodeMode (..)
    , ExternalNode (..)
    , nodeModeFromArgs
    , nodeModeFromEnvironment
    , runMode

      -- * Wallet
    , Wallet (..)
    , loadWallet
    , walletForMode
    , funderAddr
    , funderSignKey
    , sessionMagic
    , bech32Address

      -- * Session
    , NodeSession (..)
    , awaitChain
    , currentTipSlot
    , scriptStakeRegistered
    , awaitTx
    , awaitTxId
    , awaitTxWindow
    , withDevnetIndexer
    , awaitIndexed
    , adaptProvider
    , followedProvider
    , nodeAddressReads
    , awaitConnection
    , confirmDeadline
    , txUpperBoundSlot
    , nodeIsExternal
    , echoKoios
    , confirmationDelay
    , withNode
    , withNodeForPlannedFunding
    , withNodeMode
    , withNodeSocket
    , devnetGenesis

      -- * Funding
    , FundingFloor (..)
    , defaultFundingFloor
    , checkFunding
    ) where

import Singular.Registry.Node.Confirmation
    ( awaitChain
    , awaitTx
    , awaitTxId
    , awaitTxWindow
    , confirmDeadline
    , confirmationDelay
    , txUpperBoundSlot
    )
import Singular.Registry.Node.Funding
    ( FundingFloor (..)
    , checkFunding
    , defaultFundingFloor
    )
import Singular.Registry.Node.Indexer
    ( adaptProvider
    , awaitIndexed
    , followedProvider
    , nodeAddressReads
    , withDevnetIndexer
    )
import Singular.Registry.Node.Options
    ( ExternalNode (..)
    , NodeMode (..)
    , echoKoios
    , nodeIsExternal
    , nodeModeFromArgs
    , nodeModeFromEnvironment
    , runMode
    )
import Singular.Registry.Node.Session
    ( NodeSession (..)
    , awaitConnection
    , currentTipSlot
    , devnetGenesis
    , scriptStakeRegistered
    , withNode
    , withNodeForPlannedFunding
    , withNodeMode
    , withNodeSocket
    )
import Singular.Registry.Node.Wallet
    ( Wallet (..)
    , bech32Address
    , funderAddr
    , funderSignKey
    , loadWallet
    , sessionMagic
    , walletForMode
    )
