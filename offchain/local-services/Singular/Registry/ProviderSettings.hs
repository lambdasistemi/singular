{- | Explicit configuration of the sole shipping ledger provider. The parser
carries paths; token and time files are read by terminal composition.
-}
module Singular.Registry.ProviderSettings (ProviderSettings (..)) where

import Data.Word (Word32)

data ProviderSettings = ProviderSettings
    { providerUrl :: String
    , providerMagic :: Word32
    , providerTokenFile :: Maybe FilePath
    , providerTimeDirectory :: Maybe FilePath
    }
    deriving stock (Eq, Show)
