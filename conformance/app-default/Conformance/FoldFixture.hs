-- | Production target: no injected transaction or budget changes.
-- The regression target supplies its own module from test/fold-budget.
module Conformance.FoldFixture (Fixture, newFixture, prepare) where

import Cardano.Node.Client.Submitter (SubmitResult)
import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.Ledger (ExUnits)
import Singular.Registry.Provider (Provider)

data Fixture = Fixture

newFixture :: IO Fixture
newFixture = pure Fixture

prepare :: Fixture -> Provider IO -> (ExUnits -> IO ConwayTx)
    -> (ConwayTx -> IO SubmitResult) -> ExUnits -> IO ExUnits
prepare _ _ _ _ = pure
