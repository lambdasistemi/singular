{- |
Module      : Singular.Registry.Node.Wallet
Description : The wallet a run is funded from, and its address
License     : Apache-2.0

The one place a runner's funding identity comes from: the mode's
signing key — the devnet genesis key by default, the joiner's key file
in external mode — loaded once per process and derived into the
address every actor is funded from.

Key material is read from the joiner's file and never printed; only
the derived (public) address is reported ('bech32Address').
-}
module Singular.Registry.Node.Wallet
    ( -- * Wallet
      Wallet (..)
    , loadWallet
    , walletForMode
    , funderAddr
    , funderSignKey

      -- * Identity
    , sessionMagic
    , bech32Address
    ) where

import Cardano.Crypto.DSIGN (Ed25519DSIGN, SignKeyDSIGN)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Node.Client.E2E.Setup
    ( devnetMagic
    , genesisSignKey
    , keyHashFromSignKey
    )
import Ouroboros.Network.Magic (NetworkMagic (..))
import Singular.Registry.Node.Options
    ( ExternalNode (..)
    , NodeMode (..)
    , runMode
    )
import Singular.Registry.Wallet
    ( Wallet (..)
    , bech32Address
    , loadWallet
    )
import System.IO.Unsafe (unsafePerformIO)

{- | The wallet a mode funds from: the devnet genesis key, or the
joiner's key loaded from the file they named.
-}
walletForMode :: NodeMode -> IO Wallet
walletForMode Devnet =
    pure
        Wallet
            { walletAddr =
                Addr
                    Testnet
                    (KeyHashObj (keyHashFromSignKey genesisSignKey))
                    StakeRefNull
            , walletSignKey = genesisSignKey
            , walletNetwork = Testnet
            }
walletForMode (External e) = loadWallet (extMagic e) (extSkeyFile e)

-- | This process's funding wallet, resolved once from 'runMode'.
processWallet :: Wallet
processWallet = unsafePerformIO (walletForMode runMode)
{-# NOINLINE processWallet #-}

{- | The address every actor of this run is funded from: the devnet
genesis address by default, the joiner's address in external mode.
-}
funderAddr :: Addr
funderAddr = walletAddr processWallet

-- | The signing key matching 'funderAddr'.
funderSignKey :: SignKeyDSIGN Ed25519DSIGN
funderSignKey = walletSignKey processWallet

-- | The network magic this run negotiates with its node.
sessionMagic :: NetworkMagic
sessionMagic = case runMode of
    Devnet -> devnetMagic
    External e -> NetworkMagic (extMagic e)
