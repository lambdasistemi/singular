-- Must not compile: a SignedTx built by record syntax, not by signTx.
module ByRecord (forged) where

import Singular.Registry.Node.Submit (SignedTx (..))

forged :: SignedTx
forged = SignedTx{}
