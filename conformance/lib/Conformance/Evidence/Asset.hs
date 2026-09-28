{- |
Module      : Conformance.Evidence.Asset
Description : One asset movement in edge evidence
License     : Apache-2.0

Edge evidence reports what a keyed mint moved, and a movement is
identified by its policy and asset name — a quantity alone cannot say
which key a token belongs to. This module is the single owner of that
shape and its JSON encoding; @Conformance.Receipt@ re-exports it, so the
public import path a caller already uses is unchanged.
-}
module Conformance.Evidence.Asset (
    AssetEntry (..),
) where

import Data.Aeson (
    FromJSON (..),
    ToJSON (..),
    object,
    withObject,
    (.:),
    (.=),
 )
import Data.Text (Text)

{- | One asset movement, named by its policy and asset name.

The registry's token identity is @(policy, key)@ and nothing else, so a
row about a keyed mint has to report both. A quantity alone cannot
distinguish "one token at this key" from "one token at some other key".
-}
data AssetEntry = AssetEntry
    { aePolicy :: !Text
    , aeName :: !Text
    , aeQuantity :: !Integer
    }
    deriving stock (Show, Eq)

instance FromJSON AssetEntry where
    parseJSON = withObject "AssetEntry" $ \o ->
        AssetEntry <$> o .: "policy" <*> o .: "name" <*> o .: "quantity"

instance ToJSON AssetEntry where
    toJSON a =
        object
            ["policy" .= aePolicy a, "name" .= aeName a, "quantity" .= aeQuantity a]
