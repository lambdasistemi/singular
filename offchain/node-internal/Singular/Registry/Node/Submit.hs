{- |
Module      : Singular.Registry.Node.Submit
Description : The write capability: it takes signed transactions only
License     : Apache-2.0

Submission is separate from reading ("Singular.Registry.Provider"
carries none). The write capability accepts a 'SignedTx', and a
'SignedTx' exists only as the result of 'signTx': its constructor is
not exported, so an unsigned body cannot be handed to the node by type.
The node's answer — acceptance or rejection with its reason — is
returned unchanged.
-}
module Singular.Registry.Node.Submit
    ( -- * Signed transactions
      SignedTx
    , signTx
    , signedTx

      -- * Write capability
    , SignedSubmitter
    , signedSubmitter
    , submitSigned
    , SubmitResult (..)
    ) where

import Cardano.Crypto.DSIGN (Ed25519DSIGN, SignKeyDSIGN)
import Cardano.Node.Client.E2E.Setup (addKeyWitness)
import Cardano.Node.Client.Submitter
    ( SubmitResult (..)
    , Submitter (..)
    )
import Cardano.Tx.Ledger (ConwayTx)

-- | A transaction carrying the witness of the key that signed it.
newtype SignedTx = SignedTx ConwayTx

-- | Sign a transaction body with a payment key.
signTx :: SignKeyDSIGN Ed25519DSIGN -> ConwayTx -> SignedTx
signTx key = SignedTx . addKeyWitness key

-- | The signed transaction, for journalling and identity.
signedTx :: SignedTx -> ConwayTx
signedTx (SignedTx tx) = tx

-- | Sends signed transactions to the chain.
newtype SignedSubmitter = SignedSubmitter (Submitter IO)

-- | The write capability over a node submitter.
signedSubmitter :: Submitter IO -> SignedSubmitter
signedSubmitter = SignedSubmitter

-- | Send a signed transaction; the node's answer, unchanged.
submitSigned :: SignedSubmitter -> SignedTx -> IO SubmitResult
submitSigned (SignedSubmitter s) (SignedTx tx) = submitTx s tx
