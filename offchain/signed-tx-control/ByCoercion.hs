-- Must not compile: a SignedTx coerced from an unsigned body. The body's
-- own constructor is imported, so the SignedTx newtype is the only barrier.
module ByCoercion (forged) where

import Data.Coerce (coerce)

import Cardano.Ledger.Conway.Tx (Tx (..))
import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.Node.Submit (SignedTx (..))

forged :: ConwayTx -> SignedTx
forged = coerce
