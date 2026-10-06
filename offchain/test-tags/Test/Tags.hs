{- |
Module      : Test.Tags
Description : Closed area vocabulary for selecting Hspec paths
License     : Apache-2.0

Shared by all Hspec suites. Module wrappers add selection metadata without
changing examples or their expectations.
-}
module Test.Tags (Area (..), tagged) where

import Data.Char (toLower)

-- | Areas a gate can select. Extend only when a gate needs a new area.
data Area
    = Provider
    | History
    | Time
    | Validity
    | Evaluation
    | Wallet
    | Cli
    | Recovery
    | Trie
    | Builders
    | Naming
    | Application
    | Conformance
    | E2e
    deriving (Eq, Show)

-- | Stable module name followed by bracketed, lowercase area names.
tagged :: String -> [Area] -> String
tagged name areas = name <> " " <> concatMap bracket areas
  where
    bracket area = "[" <> map toLower (show area) <> "]"
