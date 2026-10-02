-- Must compile: signTx is the way to a SignedTx.
module BySigning (signed) where

import Cardano.Crypto.DSIGN (Ed25519DSIGN, SignKeyDSIGN)

import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.Node.Submit (SignedTx, signTx)

signed :: SignKeyDSIGN Ed25519DSIGN -> ConwayTx -> SignedTx
signed = signTx
