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
    ( VKey (..)
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

-- | Add a payment-key witness, preserving the body and other witnesses.
signTx :: SignKeyDSIGN Ed25519DSIGN -> ConwayTx -> SignedTx
signTx key tx =
    let TxId bodyHash = txIdTx tx
        witness =
            WitVKey
                (asWitness (VKey (deriveVerKeyDSIGN key)))
                (signedDSIGN key (extractHash bodyHash))
    in  SignedTx (tx & witsTxL . addrTxWitsL %~ Set.insert witness)

-- | The signed ledger transaction, for identity and durable journalling.
signedTx :: SignedTx -> ConwayTx
signedTx (SignedTx tx) = tx
