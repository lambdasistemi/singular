-- | The retirement effect computed by the model after a real registration.
module Conformance.Lean.Retirement
    ( UpdateTerminal
    , retirementEffect
    , updateTerminalRow
    ) where

import Conformance.Story.Binding (mkBoundObligation)
import Conformance.Story.Live (LiveI (CheckRetirementEffect))
import Conformance.Story.Specification (LeanCheck, Theorem, action, bindCheck, bindTheorem)

-- | The accepted retirement declaration.
data UpdateTerminal

-- | Check burn, witness consumption, remaining holdings and the committed leaf.
retirementEffect :: LeanCheck (LiveI reg wal step obs cmp ins ret bat ref) UpdateTerminal ret
retirementEffect = bindCheck updateTerminalRow (action . CheckRetirementEffect)

-- | The revision and statement digest resolved before the live clause runs.
updateTerminalRow :: Theorem UpdateTerminal
updateTerminalRow = bindTheorem $ mkBoundObligation
    "Singular.Statements.update_terminal_transaction_row"
    "3448ca20f33bba9c3b5092136124f4cb0bf196132f485cae8b1a44343523963b"
    "871c5df529d30357e4da7f6f9f141dc02c103bf6"
