-- Must not compile: a SignedTx built by its constructor, not by signTx.
module ByConstructor (forged) where

import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.Node.Submit (SignedTx (..))

forged :: ConwayTx -> SignedTx
forged = SignedTx
