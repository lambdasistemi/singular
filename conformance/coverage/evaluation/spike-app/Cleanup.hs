{- | Pure cleanup-failure predicate for session release.

Factored out of `releaseSession` so the assertion itself is unit-testable
with synthetic inputs: `True` (marker tree remains after removal) or a
non-empty observed pid list fails; `(False, [])` passes. The production
caller observes the pid list *before* reaping, so reaping can never
starve the assertion — a control that cannot observe its witness would
pass while proving nothing.
-}
module Cleanup (cleanupFailure) where

-- | Nothing = clean; Just message = fail the run with this reason.
cleanupFailure :: Bool -> [String] -> Maybe String
cleanupFailure dirExists observed
    | dirExists = Just "marker tree remains after removal"
    | not (null observed) =
        Just ("marker nodes present at release: " <> show observed)
    | otherwise = Nothing
