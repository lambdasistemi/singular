-- | The retirement effect computed by the model after a real registration.
module Conformance.Lean.Retirement
    ( UpdateTerminal
    , modelComparison
    , updateTerminalRow
    ) where

import Conformance.Story.Binding (mkBoundObligation)
import Conformance.Story.Live (LiveI (Observe, Compare))
import Conformance.Story.Specification (LeanCheck, Theorem, action, bindCheck, bindTheorem)

-- | The accepted retirement declaration.
data UpdateTerminal

-- | Check burn, witness consumption, remaining holdings and the committed leaf.
modelComparison :: LeanCheck (LiveI reg wal step obs cmp) UpdateTerminal step
modelComparison = bindCheck updateTerminalRow $ \step -> do
    observation <- action (Observe step)
    _ <- action (Compare step observation)
    pure ()

-- | The revision and statement digest resolved before the live clause runs.
updateTerminalRow :: Theorem UpdateTerminal
updateTerminalRow = bindTheorem $ mkBoundObligation
    "Singular.Statements.update_terminal_transaction_row"
    "c85a4eb0a61907d71a0861658097e7ab839655023e39bfc4e11a8209553e31c2"
    "88957e41876911a993c5d9a338f8ab006c9f6843"
