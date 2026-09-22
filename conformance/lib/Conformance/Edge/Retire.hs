-- | Retire a registration, then try an Absent and an unknown key.
module Conformance.Edge.Retire (story) where

import Conformance.Lean.Registration (insertActiveRow, modelComparison)
import Conformance.Lean.Retirement (updateTerminalRow)
import Conformance.Lean.Retirement qualified as Retirement
import Conformance.Story.Specification (clause, theorem)
import Conformance.Story.Live
    ( Context (Context), Edge (..), EdgeRequest (..), Story
    , compareWithModel, observe, submit
    )

story :: Context reg wal -> Context reg wal -> Story reg wal step obs cmp ()
story (Context registry holder) (Context otherRegistry _) = do
    _ <- theorem insertActiveRow $
        clause "The holder receives the token that will be retired" modelComparison $
            submit registry (EdgeRequest InsertActive "alice" holder)
    _ <- theorem updateTerminalRow $
        clause "Retirement burns the holder's token and leaves the key Terminal" Retirement.modelComparison $
            submit registry (EdgeRequest UpdateTerminal "alice" holder)
    checked registry (EdgeRequest InsertAbsent "never-active" holder)
    checked registry (EdgeRequest UpdateTerminal "never-active" holder)

    -- A refused request remains pending. The unknown control uses a fresh
    -- registry so the first refusal cannot account for the second one.
    checked otherRegistry (EdgeRequest InsertActive "control" holder)
    checked otherRegistry (EdgeRequest UpdateTerminal "control" holder)
    checked otherRegistry (EdgeRequest UpdateTerminal "never-registered" holder)
  where
    checked registry' request = do
        step <- submit registry' request
        observation <- observe step
        _ <- compareWithModel step observation
        pure ()
