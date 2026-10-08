{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.ManagedState
Description : Where a command keeps its own journal and submissions
License     : Apache-2.0

Every existing-registry command resolves a writable state directory before
its lock or journal is used. The directory is keyed by network, the
complete state token and the caller's stable wallet payment identity —
never a key filename or a provider URL — so the same identity reuses its
journal and lock across invocations and key-file relocation, while
different wallets and tokens cannot read each other's pending
submissions. The CLI creates required directories itself, at lock time;
resolution alone creates nothing.

The default root is the platform per-user state location with the
@singular@ namespace. An explicit @--state-dir@ overrides the root with
the same partitioning; it is never a per-registry path. Reads without a
wallet (an address-free inspect, every preview) resolve no wallet
partition: previews pass their address's partition through without
creating it, and a stateless inspect reads the chain through a reserved
non-I/O sentinel that must never reach journal, pending or lock helpers.
-}
module Singular.CLI.ManagedState
    ( managedStateRoot
    , resolveStateRoot
    , resolveWalletDir
    , managedDir
    , statelessDir
    , walletPartition
    , addressPartition
    ) where

import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short qualified as SBS
import Data.Word (Word32)
import System.Directory (XdgDirectory (XdgState), getXdgDirectory)
import System.FilePath ((</>))

import Cardano.Ledger.Mary.Value (PolicyID (..))

import Singular.Registry.Ledger (AssetName (..))
import Singular.Registry.LedgerProvider (Asset)
import Singular.Registry.TxBuilder.Internal
    ( addrKeyHashBytes
    , scriptHashBytes
    )
import Singular.Registry.Wallet (Wallet (..), loadWallet)

import Cardano.Ledger.Address (Addr)

{- | The default state root: the platform per-user state location with
the @singular@ namespace (@XDG_STATE_HOME@, falling back to
@$HOME\/.local\/state@). Reading the environment creates nothing.
-}
managedStateRoot :: IO FilePath
managedStateRoot = getXdgDirectory XdgState "singular"

{- | The effective state root: the caller's @--state-dir@ when one was
given, else the managed default. A configured root keeps the same
identity partitioning; it is never a per-registry directory.
-}
resolveStateRoot :: Maybe FilePath -> IO FilePath
resolveStateRoot = maybe managedStateRoot pure

{- | The managed directory for a wallet command: loads the caller's wallet
from its key file, derives the stable payment identity and resolves the
partition. Runs before any lock or journal use; loads no chain state.
-}
resolveWalletDir
    :: Maybe FilePath -> Word32 -> Asset -> FilePath -> IO FilePath
resolveWalletDir rootOpt magic token keyPath = do
    wallet <- loadWallet magic keyPath
    root <- resolveStateRoot rootOpt
    pure (managedDir root magic token (walletPartition wallet))

{- | The managed directory for one identity: the root, the network, the
complete state token (policy and asset) and the wallet's payment
identity, each in a path-safe canonical spelling. Pure: resolving
creates nothing on disk.
-}
managedDir :: FilePath -> Word32 -> Asset -> ByteString -> FilePath
managedDir root magic token walletHash =
    root </> networkPart </> tokenPart </> "wallets" </> hex walletHash
  where
    networkPart = "net-" <> show magic
    tokenPart = policyHex <> "-" <> nameHex
    (PolicyID policy, AssetName name) = token
    policyHex = BC.unpack (B16.encode (scriptHashBytes policy))
    nameHex = BC.unpack (B16.encode (SBS.fromShort name))

{- | A reserved non-I/O sentinel for stateless reads: beside the wallet
partitions under the network and token namespace, never created on disk
and never passed to journal, pending or lock helpers. It only satisfies
interfaces that name a path while reading nothing from it.
-}
statelessDir :: FilePath -> Word32 -> Asset -> FilePath
statelessDir root magic token =
    root
        </> ("net-" <> show magic)
        </> (policyHex <> "-" <> nameHex)
        </> "read-only"
  where
    (PolicyID policy, AssetName name) = token
    policyHex = BC.unpack (B16.encode (scriptHashBytes policy))
    nameHex = BC.unpack (B16.encode (SBS.fromShort name))

{- | The wallet's stable payment identity: its payment key hash. The same
signing key resolves the same partition from any key-file path; different
wallets resolve different partitions. Secret bytes and filenames never
enter the identity.
-}
walletPartition :: Wallet -> ByteString
walletPartition = addrKeyHashBytes . walletAddr

{- | The same payment identity for a public address: an inspect naming
@--wallet-address@ resolves the same partition as a write signed by that
wallet. Address and network are validated before this is called.
-}
addressPartition :: Addr -> ByteString
addressPartition = addrKeyHashBytes

hex :: ByteString -> FilePath
hex = BC.unpack . B16.encode
