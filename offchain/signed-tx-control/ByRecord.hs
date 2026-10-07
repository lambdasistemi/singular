-- Must not compile: a SignedTx built by record syntax, not by signTx.
module ByRecord (forged) where

import Singular.Registry.Signing (SignedTx (..))

forged :: SignedTx
forged = SignedTx{}
