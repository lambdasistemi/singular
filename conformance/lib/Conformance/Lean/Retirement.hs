-- | The retirement effect computed by the model after a real registration.
module Conformance.Lean.Retirement
    ( UpdateTerminal
    , modelComparison
    , updateTerminalRow
    ) where

import Conformance.Story.Binding (mkBoundObligation)
import Conformance.Story.Live (LiveI (Compare, Observe))
import Conformance.Story.Specification
    ( LeanCheck
    , Theorem
    , action
    , bindCheck
    , bindTheorem
    )

-- | The accepted retirement declaration.
data UpdateTerminal

-- | Check burn, witness consumption, remaining holdings and the committed leaf.
modelComparison
    :: LeanCheck (LiveI reg wal step obs cmp) UpdateTerminal step
modelComparison = bindCheck updateTerminalRow $ \step -> do
    observation <- action (Observe step)
    _ <- action (Compare step observation)
    pure ()

-- | The revision and statement digest resolved before the live clause runs.
updateTerminalRow :: Theorem UpdateTerminal
updateTerminalRow =
    bindTheorem $
        mkBoundObligation
            "Singular.Statements.update_terminal_transaction_row"
            "d2402d0c08b3df1258ddf354ef7e4855ceec1dae5f1fe763e0f0189aacb0b560"
            "88957e41876911a993c5d9a338f8ab006c9f6843"
