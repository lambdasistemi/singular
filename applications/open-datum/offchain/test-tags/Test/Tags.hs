{- |
Module      : Test.Tags
Description : Closed area and lane vocabularies for selecting Hspec paths
License     : Apache-2.0

Shared by all Hspec suites. Module wrappers add selection metadata without
changing examples or their expectations.

An area says what a module exercises. A lane says which parallel CI job runs
it: a suite that CI splits into jobs wraps every module in exactly one lane,
and each job selects its examples with @--match "{lane:NAME}"@. CI proves
the selection before running it: every lane selects at least one example,
the lanes add up to the whole suite, and skipping every lane selects nothing.
-}
module Test.Tags (Area (..), tagged, Lane (..), lane) where

import Data.Char (isUpper, toLower)

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

{- | The parallel CI jobs of the devnet E2E suite. Extend only together with
the job list that selects them.
-}
data Lane
    = NodeBoot
    | ForkRecovery
    | UpdateTerminal
    | Criterion3
    | Cage
    | DriverReplay
    deriving (Eq, Show, Enum, Bounded)

-- | The describe label of a lane: @{lane:NAME}@.
lane :: Lane -> String
lane l = "{lane:" <> laneName l <> "}"

-- | Kebab-case of the constructor, e.g. @DriverReplay@ is @driver-replay@.
laneName :: Lane -> String
laneName = drop 1 . concatMap kebab . show
  where
    kebab c
        | isUpper c = ['-', toLower c]
        | otherwise = [c]
