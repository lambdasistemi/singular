-- | A private harness run's explicit wallet and shipping capabilities.
module Conformance.Run.Actor
    ( Actor (..)
    , actorAddress
    , actorSigningKey
    ) where

import Cardano.Crypto.DSIGN (Ed25519DSIGN, SignKeyDSIGN)
import Cardano.Ledger.Address (Addr)
import Singular.Registry.Capabilities (Capabilities)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Wallet (Wallet (..))

data Actor = Actor
    { actorWallet :: Wallet
    , actorCaps :: Capabilities NoWitness IO
    }

actorAddress :: Actor -> Addr
actorAddress = walletAddr . actorWallet

actorSigningKey :: Actor -> SignKeyDSIGN Ed25519DSIGN
actorSigningKey = walletSignKey . actorWallet
