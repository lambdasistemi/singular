{- |
Module      : Conformance.Classification
Description : How every model-facing requirement is run: an edge composition, a tamper, or outside the model
License     : Apache-2.0

Three groups of the inventory make claims a reader could expect the model to
judge: the registry operations, the registry's identity and its wire format.
Each of their requirements is classified exactly once as an edge composition
over the model's operations, a tamper of an edge's transaction, or outside the
model's vocabulary with its reason. The classification is read off what runs
the row — the program of the story language, of the authentication
vocabulary or of the wire round trip — never typed beside it.
-}
module Conformance.Classification
    ( Vocabulary (..)
    , vocabularyReading
    , Class (..)
    , Classified (..)
    , classifiedGroups
    , classifyRow
    , classifyInventory
    , armsRow
    ) where

import Conformance.Rows (Row (..))
import Data.Text (Text)
import Data.Text qualified as T

-- | The description language a requirement is run in.
data Vocabulary
    = -- | programs over the model's exits, compared with the model
      EdgeStories
    | -- | seeds, registries booted from them, outputs and authenticators
      AuthenticationVocabulary
    | -- | encodings checked against the compiled blueprint and read back from the chain
      WireRoundTrip
    deriving stock (Eq, Show, Enum, Bounded)

vocabularyReading :: Vocabulary -> String
vocabularyReading v = case v of
    EdgeStories -> "the story language over the registry's operations"
    AuthenticationVocabulary -> "the authentication vocabulary"
    WireRoundTrip -> "the wire round-trip vocabulary"

-- | The three classes a requirement can fall in.
data Class
    = EdgeComposition
    | TransactionTamper
    | -- | outside the model's vocabulary, for this reason
      OutsideModel Text
    deriving stock (Eq, Show)

-- | One requirement's class and the vocabulary whose program runs it, if any.
data Classified = Classified
    { classifiedRow :: Text
    , classifiedClass :: Class
    , classifiedVocabulary :: Maybe Vocabulary
    }
    deriving stock (Eq, Show)

-- | The inventory groups whose requirements are classified.
classifiedGroups :: [Text]
classifiedGroups = ["registry-operations", "registry-identity", "serialization"]

-- | One requirement's classification, read off what runs it.
classifyRow :: Row -> Either String Classified
classifyRow row = Left (T.unpack (rowId row) <> " is not classified")

{- | Every requirement of the classified groups, classified exactly once. An
empty extent, a requirement listed twice, and a program or reason for a
requirement the inventory does not hold are refused.
-}
classifyInventory :: [Row] -> Either String [Classified]
classifyInventory _ = Left "the inventory is not classified"

{- | Whether a control arms a row: some instruction of the row's program
demands the opposite under it.
-}
armsRow :: String -> String -> Bool
armsRow _ _ = False
