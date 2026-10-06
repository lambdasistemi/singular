{- | A genuine State adapter over real MPF nodes and recorded fixture history.
Fixture identities are application inputs, never observations of a ledger.
-}
module Singular.Registry.TrieState.Fixture
    ( FixtureStore
    , fixtureStore
    , fixtureTrieState
    , fixtureNodes
    , fixtureFolds
    , fixtureSnapshot
    ) where

import Control.Monad.State.Strict (State, gets, modify')
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import MPF.Backend.Pure (MPFInMemoryDB)
import Singular.Registry.TrieState
import Singular.Registry.TrieState.Core
    ( TrieEntry (..)
    , capability
    , checkedCoverage
    , snapshotObserved
    )

{- | A checked immutable fixture snapshot in the consumer's effect. This
carries no provider or ledger admission claim.
-}
fixtureSnapshot
    :: (Monad m)
    => FixtureStore -> TrieSelection -> Either TrieFailure (TrieSnapshot m)
fixtureSnapshot (FixtureStore entries) chosen = do
    entry <-
        maybe
            ( Left
                (WrongRegistry (trieSelectionIdentity chosen) Nothing UnknownRegistry)
            )
            Right
            (Map.lookup (trieSelectionIdentity chosen) entries)
    coverage <- checkedCoverage entry
    if chosen == entrySelection entry
        then
            Right
                (snapshotObserved (const (pure ())) chosen (entryNodes entry) coverage)
        else
            Left
                ( StaleState
                    (trieSelectionIdentity chosen)
                    Nothing
                    (StaleSelection chosen (entrySelection entry))
                )

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
    fetch who = gets $ \(FixtureStore entries) ->
        maybe
            (Left (WrongRegistry who Nothing UnknownRegistry))
            Right
            (Map.lookup who entries)
    persist entry = modify' $ \(FixtureStore entries) ->
        FixtureStore
            ( Map.insert
                (trieSelectionIdentity (entrySelection entry))
                entry
                entries
            )
