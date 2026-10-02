-- | One registration program, expressed only as edge requests and comparisons.
module Conformance.Edge.Register (story, insertActiveRow) where

import Conformance.Lean.Registration
    ( insertActiveRow
    , modelComparison
    )
import Conformance.Story.Live
    ( BatchTamper (..)
    , Context (Context)
    , Edge (..)
    , EdgeRequest (..)
    , Story
    , Tamper (..)
    , compareWithModel
    , observe
    , submit
    , tamper
    , tamperFoldBatch
    )
import Conformance.Story.Specification (clause, theorem)

story :: Context reg wal -> Story reg wal step obs cmp ()
story (Context registry recipient) = do
    _ <-
        theorem insertActiveRow
            $ clause
                "Registration delivers one active token to the requested recipient"
                modelComparison
            $ submit registry (EdgeRequest InsertActive "alice" recipient)
    checked (EdgeRequest InsertActive "bob" recipient)
    checked (EdgeRequest InsertActive "alice" recipient)
    let redirected = EdgeRequest InsertActive "redirect" recipient
    tamper OtherAddress registry redirected >>= compared
    tamper ShortByOne registry redirected >>= compared
    checked redirected
    tamper
        ExtraSigner
        registry
        (EdgeRequest InsertActive "cosigned" recipient)
        >>= compared
    -- Two registrations folded in one transaction that mints both tokens at the
    -- first key: the same quantity of the kind, at the wrong keys.
    _ <-
        tamperFoldBatch
            MintOnFirstKey
            registry
            [ EdgeRequest InsertActive "minted-a" recipient
            , EdgeRequest InsertActive "minted-b" recipient
            ]
    pure ()
  where
    checked request = submit registry request >>= compared
    compared step = do
        observation <- observe step
        _ <- compareWithModel step observation
        pure ()
