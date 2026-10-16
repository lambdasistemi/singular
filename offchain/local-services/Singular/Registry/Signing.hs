{-# LANGUAGE DataKinds #-}

{- |
Module      : Singular.Registry.Signing
Description : Payment-key witnesses and signed transaction capability
License     : Apache-2.0

Signing changes only the witness set. The body and its transaction identity
are preserved. The constructor stays private: submission capabilities accept
only a transaction passed through this payment-key signing boundary.
-}
module Singular.Registry.Signing
    ( SignedTx
    , detachedWitness
    , signTx
    , signedTx
    ) where

import Cardano.Crypto.DSIGN
    ( Ed25519DSIGN
    , SignKeyDSIGN
    , deriveVerKeyDSIGN
    )
import Cardano.Ledger.Api.Tx (addrTxWitsL, txIdTx, witsTxL)
import Cardano.Ledger.Core (extractHash)
import Cardano.Ledger.Keys
    ( KeyRole (..)
    , VKey (..)
    , WitVKey (..)
    , asWitness
    , signedDSIGN
    )
import Cardano.Ledger.TxIn (TxId (..))
import Cardano.Tx.Ledger (ConwayTx)
import Data.Set qualified as Set
import Lens.Micro ((%~), (&))

-- | A transaction carrying a witness from the key that signed its body.
newtype SignedTx = SignedTx ConwayTx

{- | The verification-key witness of a transaction's body hash, signed
by the key: the same witness 'signTx' adds to a transaction's witness
set, detached, so the offline bundle-signing path can write it to its
own file. Pure.
-}
detachedWitness
    :: SignKeyDSIGN Ed25519DSIGN
    -> ConwayTx
    -> WitVKey Witness
detachedWitness key tx =
    let TxId bodyHash = txIdTx tx
    in  WitVKey
            (asWitness (VKey (deriveVerKeyDSIGN key)))
            (signedDSIGN key (extractHash bodyHash))

-- | Add a payment-key witness, preserving the body and other witnesses.
signTx :: SignKeyDSIGN Ed25519DSIGN -> ConwayTx -> SignedTx
signTx key tx =
    SignedTx
        (tx & witsTxL . addrTxWitsL %~ Set.insert (detachedWitness key tx))

-- | The signed ledger transaction, for identity and durable journalling.
signedTx :: SignedTx -> ConwayTx
signedTx (SignedTx tx) = tx
