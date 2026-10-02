{- |
Module      : Singular.CLI.RequestWindow
Description : The instants a pending request's processing and retract windows end
License     : Apache-2.0

A booked request has a processing window, in which the registry's fold may
take it, and a retract window after it, in which its owner may take it
back. Past both it can only be rejected. The reading is the one place
those boundaries are stated for the commands that act on a request.

The bounds are sums of what the chain holds, the request's submission time
and the registry's processing and retract times, as @onchain/validators/shared.ak@
adds them. They are times, not a judgement of whether a window is over: that
is the ledger's, read from a view's tip slot and its conversion of the bound
to a slot, and no clock of the host's enters it.
-}
module Singular.CLI.RequestWindow
    ( Bounds (..)
    , windowOf
    ) where

-- | The two instants a request's windows end, in POSIX milliseconds.
data Bounds = Bounds
    { processingEnds :: Integer
    -- ^ The registry's fold may take the request before this instant
    , retractEnds :: Integer
    -- ^ The request's owner may take it back before this instant
    }
    deriving stock (Eq, Show)

{- | The bounds of a request's windows, from its submission time, the
registry's processing time and its retract time.
-}
windowOf :: Integer -> Integer -> Integer -> Bounds
windowOf submittedAt processTime retractTime =
    Bounds
        { processingEnds = submittedAt + processTime
        , retractEnds = submittedAt + processTime + retractTime
        }
