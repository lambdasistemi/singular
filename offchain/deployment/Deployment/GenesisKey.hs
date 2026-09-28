{- |
Module      : Deployment.GenesisKey
Description : @deployment genesis-skey@ — the devnet key, in a joiner's file form
License     : Apache-2.0

Write the factory devnet's genesis signing key in the file form a
joiner supplies, so the devnet attach check can reach its own devnet
through the external path rather than through the devnet path it is
meant to be testing an alternative to.

Devnet only. The key is a constant of the checked-in genesis, public by
construction, and worth nothing on any network anyone uses. No node is
contacted.
-}
module Deployment.GenesisKey
    ( genesisSkey
    ) where

import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC

import Cardano.Node.Client.E2E.Setup
    ( genesisSignKey
    , rawSerialiseSignKeyDSIGN
    )
import Deployment.Narration (emit)
import Deployment.Options (genesisKeyPath)

-- | Write the devnet genesis key to the path @--out@ names.
genesisSkey :: [String] -> IO ()
genesisSkey args = do
    out <- genesisKeyPath args
    writeFile
        out
        ( "{\"type\":\"PaymentSigningKeyShelley_ed25519\","
            <> "\"description\":\"Payment Signing Key\",\"cborHex\":\"5820"
            <> BC.unpack (B16.encode (rawSerialiseSignKeyDSIGN genesisSignKey))
            <> "\"}"
        )
    emit "genesis-skey" ("wrote the devnet genesis key to " <> out)
