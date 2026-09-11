{- |
Module      : Conformance.Refusal
Description : Phase-2 refusal attribution for refused rows
License     : Apache-2.0

A refusal closes a refuse-row only when it is attributable: the node
must have refused in phase 2 (@PlutusFailure@) naming the script that
refused (@marker@, the applied script hash hex). A phase-1 refusal
proves nothing about the binding, and a reason that does not name the
script proves nothing about which guard held. This is the #41
discipline as @offchain\/journey\/li-refusals\/Main.hs@ applies it.

'wrongReasonMarker' arms the negative control: matched against a
marker no node reason can ever contain, the matcher must fail naming
what came back (@CONFORMANCE_CONTROL=wrong-reason@).
-}
module Conformance.Refusal (
    RefusalMismatch (..),
    matchRefusal,
    wrongReasonMarker,
) where

import Data.List (isInfixOf)

-- | How a refusal failed to attribute.
data RefusalMismatch
    = -- | The node refused outside phase 2: proves nothing about the
      -- script binding.
      NotPhase2
        { refusalReason :: String
        }
    | -- | The reason does not name the expected script.
      MarkerAbsent
        { refusalMarker :: String
        , refusalReason :: String
        }
    deriving stock (Show, Eq)

{- | Require @reason@ to be a phase-2 Plutus failure naming @marker@.
@marker@ is the applied refusing script's hash hex; @reason@ is the
node's refusal text verbatim.
-}
matchRefusal :: String -> String -> Either RefusalMismatch ()
matchRefusal marker reason
    | not ("PlutusFailure" `isInfixOf` reason) =
        Left (NotPhase2 reason)
    | not (marker `isInfixOf` reason) =
        Left (MarkerAbsent marker reason)
    | otherwise = Right ()

{- | The marker the wrong-reason control matches refusals against: by
construction no node reason can contain it, so a matched reason can
never close a row and the control must fail.
-}
wrongReasonMarker :: String
wrongReasonMarker =
    "wrong-reason-control marker that no node reason can ever contain"
