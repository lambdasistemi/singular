-- | One registration program, expressed only as edge requests and comparisons.
module Conformance.Edge.Register (story, insertActiveRow) where

import Conformance.Lean.Registration (insertActiveRow, modelComparison)
import Conformance.Story.Specification (clause, theorem)
import Conformance.Story.Live
    ( Context (Context), Edge (..), EdgeRequest (..), Story, Tamper (..)
    , compareWithModel, observe, submit, tamper
    )

story :: Context reg wal -> Story reg wal step obs cmp ()
story (Context registry recipient) = do
    _ <- theorem insertActiveRow $
        clause "Registration delivers one active token to the requested recipient"
            modelComparison $
                submit registry (EdgeRequest InsertActive "alice" recipient)
    checked (EdgeRequest InsertActive "bob" recipient)
    checked (EdgeRequest InsertActive "alice" recipient)
    let redirected = EdgeRequest InsertActive "redirect" recipient
    tampered <- tamper RedirectDelivery registry redirected
    compared tampered
    checked redirected
    tamper ExtraSigner registry (EdgeRequest InsertActive "cosigned" recipient) >>= compared
  where
    checked request = submit registry request >>= compared
    compared step = do
        observation <- observe step
        _ <- compareWithModel step observation
        pure ()
