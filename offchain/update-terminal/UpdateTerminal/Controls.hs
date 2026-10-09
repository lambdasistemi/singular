{- |
Module      : UpdateTerminal.Controls
Description : The two refused retirements and the control each one needs
License     : Apache-2.0

Two deliberate refusals: retirement of an already terminal key in the story
registry, and retirement of an unknown key in its own registry. Each has an
active-key accepting control in the same registry. Absent leaves are unreachable
from M1 genesis; synthetic absent refusals remain compiled-context controls.
-}
module UpdateTerminal.Controls
    ( unknownKey
    , controlKey
    , terminalRefusal
    , UnknownLeg (..)
    , unknownRefusal
    , refusalTrace
    ) where

import Control.Exception (displayException)
import Data.Aeson (Value (..))
import Data.ByteString (ByteString)
import Data.List (isInfixOf)
import Data.Text qualified as T

import Singular.Registry.Wait (tryOutcome)
import UpdateTerminal.Narration (die, hex, say)
import UpdateTerminal.Registry
    ( Registry
    , book
    , foldAndMirror
    , foldInadmissible
    , insertOp
    , retireOp
    , txIdOf
    )
import UpdateTerminal.Steps (storyKey)

{- | The Unknown leg's own accepting control, booked and retired in the
second registry before the refusal it controls.
-}
controlKey :: ByteString
controlKey = "update-terminal-demo-control"

-- | A key nothing ever inserted: the trie does not bind it at all.
unknownKey :: ByteString
unknownKey = "update-terminal-demo-unknown"

-- | The story key has already been permanently retired.
terminalRefusal :: Registry -> IO String
terminalRefusal story = do
    book story storyKey retireOp
    outcome <- tryOutcome (foldInadmissible story)
    detail <- case outcome of
        Right _ -> die "the fold ACCEPTED retirement of an already terminal key"
        Left e -> pure (displayException e)
    say "an already terminal key: REFUSED"
    pure detail

-- | The Unknown leg: its accepting control's txid and the refusal text.
data UnknownLeg = UnknownLeg
    { unknownControlTxid :: T.Text
    , unknownDetail :: String
    }

-- | Retire an active control key, then require an unknown key refused.
unknownRefusal :: Registry -> IO UnknownLeg
unknownRefusal reg = do
    book reg controlKey insertOp
    _ <- foldAndMirror reg controlKey insertOp
    book reg controlKey retireOp
    controlOutcome <-
        tryOutcome (foldAndMirror reg controlKey retireOp)
    controlTxid <- case controlOutcome of
        Right tx -> pure (hex (txIdOf tx))
        Left e ->
            die
                ( "control: a key that IS active was refused retirement, so \
                  \the refusal below would prove nothing about the leaf: "
                    <> displayException e
                )
    book reg unknownKey retireOp
    unknownOutcome <- tryOutcome (foldInadmissible reg)
    detail <- case unknownOutcome of
        Right _ ->
            die
                "the fold ACCEPTED updateTerminal on a key the trie does not \
                \bind — reported, not relabelled"
        Left e -> pure (displayException e)
    say "a key the trie does not bind: REFUSED"
    pure (UnknownLeg controlTxid detail)

-- | The named refusal when the ledger text carries it, @null@ otherwise.
refusalTrace :: String -> String -> Value
refusalTrace name detail
    | name `isInfixOf` detail = String (T.pack name)
    | otherwise = Null
