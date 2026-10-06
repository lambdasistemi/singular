{- | Production target: no injected transaction or budget changes.
The regression target supplies its own module from test/fold-budget.
-}
module Conformance.FoldFixture (Fixture, newFixture, prepare) where

import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (ExUnits)
import Singular.Registry.LedgerProvider
    ( LedgerProvider
    , Network
    , SubmitResult
    )

data Fixture = Fixture

newFixture :: IO Fixture
newFixture = pure Fixture

prepare
    :: Fixture
    -> (Network, LedgerProvider NoWitness IO)
    -> (ExUnits -> IO ConwayTx)
    -> (ConwayTx -> IO SubmitResult)
    -> ExUnits
    -> IO ExUnits
prepare _ _ _ _ = pure
