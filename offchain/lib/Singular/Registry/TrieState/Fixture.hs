{- | A genuine State adapter over real MPF nodes and recorded fixture history.
Fixture identities are application inputs, never observations of a ledger.
-}
module Singular.Registry.TrieState.Fixture
    ( FixtureStore
    , fixtureStore
    , fixtureTrieState
    , fixtureNodes
    , fixtureFolds
    ) where

import Control.Monad.State.Strict (State, gets, modify')
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import MPF.Backend.Pure (MPFInMemoryDB)
import Singular.Registry.TrieState
import Singular.Registry.TrieState.Core (TrieEntry (..), capability)

newtype FixtureStore = FixtureStore (Map RegistryIdentity TrieEntry)
fixtureStore
    :: [(TrieSelection, Maybe CreateRecord, [ObservedFold], MPFInMemoryDB)]
    -> FixtureStore
fixtureStore entries =
    FixtureStore $
        Map.fromList
            [ (trieSelectionIdentity chosen, TrieEntry chosen create events nodes)
            | (chosen, create, events, nodes) <- entries
            ]
fixtureNodes :: FixtureStore -> Map RegistryIdentity MPFInMemoryDB
fixtureNodes (FixtureStore entries) = entryNodes <$> entries
fixtureFolds :: FixtureStore -> Map RegistryIdentity [ObservedFold]
fixtureFolds (FixtureStore entries) = entryFolds <$> entries
fixtureTrieState :: TrieState (State FixtureStore)
fixtureTrieState = capability fetch persist
  where
    fetch who = gets $ \(FixtureStore entries) -> maybe (Left WrongRegistry) Right (Map.lookup who entries)
    persist entry = modify' $ \(FixtureStore entries) ->
        FixtureStore
            ( Map.insert
                (trieSelectionIdentity (entrySelection entry))
                entry
                entries
            )
