{- |
Module      : Singular.Registry.FoldAdmission
Description : Pure fold admission and within-batch checks (#519)
License     : Apache-2.0

Pull request 3 of #519 promotes the fold's window rule out of the command
line into the registry library, beside the within-batch rule the model
states. Both functions are pure over POSIX milliseconds: no clock, no
provider, no command line, no open datum. They mirror the model's names —
'foldAdmission' and 'batchConsumesCreated' of @Singular.Model_ — so the
builder, the selection and the command line call one predicate each, and
the conformance unit suite checks the library against the model at the
boundary and one past it.

A request's deadline is its submission time plus the registry's processing
time, never the clock. A fold is admitted when its finite validity upper
bound, excluded as the ledger hands it to a script, is at or before the
deadline of every request it includes; equality admits. A batch that
terminates a key an earlier insertion of the same batch created is refused
@token-missing@: the termination must burn the active token from an input,
and the insertion delivers it to an output of the same transaction.
-}
module Singular.Registry.FoldAdmission
    ( BatchEdge (..)
    , AdmissionRefusal (..)
    , BatchConsumption (..)
    , foldAdmission
    , batchConsumesCreated
    , admissionReason
    , admissionSource
    , consumptionReason
    , consumptionSource
    , mintReason
    , mintSource
    ) where

{- | The edge a batched request takes, as far as the within-batch check
reads it: an insertion creates the key's active holding, a termination
burns one, any other edge is neither.
-}
data BatchEdge
    = BatchInsert
    | BatchTerminate
    | BatchOther
    deriving stock (Eq, Show)

{- | Why a fold is not admitted: the first included request, in input
order, whose deadline the upper bound passes, with its submission time,
its deadline and the bound. The reason is 'admissionReason' with source
'admissionSource'.
-}
data AdmissionRefusal ref = AdmissionRefusal
    { refusalRef :: ref
    , refusalSubmittedAt :: Integer
    , refusalDeadline :: Integer
    , refusalBound :: Integer
    }
    deriving stock (Eq, Show)

{- | Why a batch consumes what it creates: the terminating request and the
key. The reason is 'consumptionReason' with source 'consumptionSource'.
-}
data BatchConsumption ref key = BatchConsumption
    { consumptionRef :: ref
    , consumptionKey :: key
    }
    deriving stock (Eq, Show)

{- | The model's refusal word for a fold outside its window, reported
verbatim.
-}
admissionReason :: String
admissionReason = "not-phase1"

{- | Where the window refusal comes from: the model, never processor
policy.
-}
admissionSource :: String
admissionSource = "model-refusal"

{- | The model's refusal word for a batch that terminates a key it just
inserted, reported verbatim.
-}
consumptionReason :: String
consumptionReason = "token-missing"

{- | The model's refusal word for a batch whose claimed mint differs from
what its edges mint at any key, reported verbatim.
-}
mintReason :: String
mintReason = "net-mint-mismatch"

{- | Where the keyed-mint refusal comes from: the model, never processor
policy.
-}
mintSource :: String
mintSource = "model-refusal"

{- | Where the within-batch refusal comes from: the model, never processor
policy.
-}
consumptionSource :: String
consumptionSource = "model-refusal"

{- | The fold admission over POSIX milliseconds: the registry's processing
time, the fold's finite excluded upper bound, and the included requests as
output reference with submission time, in input order. Admits when the
bound is at or before every request's deadline; otherwise refuses with the
first request in input order whose deadline the bound passes.
-}
foldAdmission
    :: Integer -> Integer -> [(ref, Integer)] -> Maybe (AdmissionRefusal ref)
foldAdmission processTime upperBound = go
  where
    go [] = Nothing
    go ((ref, submittedAt) : rest)
        | upperBound <= submittedAt + processTime = go rest
        | otherwise =
            Just
                ( AdmissionRefusal
                    ref
                    submittedAt
                    (submittedAt + processTime)
                    upperBound
                )

{- | The within-batch check over the included requests in order, each as
output reference with key and edge. Refuses with the terminating request
and the key when a termination names a key an earlier insertion of the
same batch created; anything else is the law's business, not this check's.
-}
batchConsumesCreated
    :: (Eq key)
    => [(ref, key, BatchEdge)] -> Maybe (BatchConsumption ref key)
batchConsumesCreated = go []
  where
    go _ [] = Nothing
    go created ((ref, key, edge) : rest) = case edge of
        BatchTerminate
            | key `elem` created -> Just (BatchConsumption ref key)
            | otherwise -> go created rest
        BatchInsert -> go (key : created) rest
        BatchOther -> go created rest
