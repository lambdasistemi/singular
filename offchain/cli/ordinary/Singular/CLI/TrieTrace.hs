{- |
Module      : Singular.CLI.TrieTrace
Description : Ordinary capability observations have no hidden test output
License     : Apache-2.0

The ordinary build carries no test observation-file writer or hidden input.
The test-harness flag selects the independent diagnostic implementation.
-}
module Singular.CLI.TrieTrace (observeTrie) where

import Singular.Registry.TrieState (TrieObservation)

-- | Retain the capability observer interface without a test-only output.
observeTrie :: TrieObservation -> IO ()
observeTrie _ = pure ()
